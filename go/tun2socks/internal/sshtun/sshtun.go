// Package sshtun opens a chain of SSH connections and hands out a dialer that
// reaches the internet from the far end of it.
//
// This is the Go counterpart of lib/vpn/ssh_tunnel.dart. The Dart version
// exists because on Android the tunnel lives inside the Flutter process. On
// iOS the tunnel has to live inside a NetworkExtension, where no Flutter
// engine runs, so the same job is done here.
//
// One difference is deliberate: the Dart version publishes a SOCKS5 proxy on
// localhost and lets the packet engine dial into it. Nothing here needs that
// detour — the packet engine takes a Dialer, and a Chain is one.
package sshtun

import (
	"context"
	"errors"
	"fmt"
	"net"
	"strconv"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

// Hop is one SSH server in the chain, along with the credentials for it.
type Hop struct {
	Host          string `json:"host"`
	Port          int    `json:"port"`
	Username      string `json:"username"`
	Password      string `json:"password,omitempty"`
	PrivateKeyPEM string `json:"privateKeyPem,omitempty"`
	Passphrase    string `json:"passphrase,omitempty"`
}

func (h Hop) addr() string {
	port := h.Port
	if port == 0 {
		port = 22
	}
	return net.JoinHostPort(h.Host, strconv.Itoa(port))
}

// Config describes a whole chain. Hops are traversed in order: the first is
// reached directly, every later one through the connection before it.
type Config struct {
	Hops []Hop `json:"hops"`

	// ConnectTimeout bounds the TCP dial and the SSH handshake of each hop
	// separately, not the chain as a whole. Zero means 15s.
	ConnectTimeout time.Duration `json:"-"`

	// KeepAliveInterval controls how often a keepalive request goes to the
	// last hop. A tunnel on a phone dies quietly — the carrier drops the
	// connection without a FIN — and without these the chain looks healthy
	// until the first packet is written into it. Zero means 30s.
	KeepAliveInterval time.Duration `json:"-"`

	// BaseDialer opens the connection to the first hop. Zero uses a plain
	// net.Dialer. The iOS extension may need to bind that socket to a
	// specific interface to keep it out of the tunnel it is establishing.
	BaseDialer ContextDialer `json:"-"`
}

// ContextDialer is the subset of net.Dialer that this package needs, and the
// interface a Chain itself satisfies.
type ContextDialer interface {
	DialContext(ctx context.Context, network, address string) (net.Conn, error)
}

const (
	defaultConnectTimeout = 15 * time.Second
	defaultKeepAlive      = 30 * time.Second
)

var errNoHops = errors.New("sshtun: at least one hop is required")

// Chain is a live chain of SSH connections. Dial it to reach the internet as
// the last hop sees it.
type Chain struct {
	clients []*ssh.Client

	mu     sync.Mutex
	closed bool

	// done closes once the chain has dropped for any reason: a hop hung up,
	// a keepalive went unanswered, or Close was called.
	done     chan struct{}
	doneOnce sync.Once
	dropErr  error
}

// Dial walks the hop list and returns once the last one has authenticated.
//
// Failure at any hop tears down the ones already established — a half-built
// chain is not useful to anybody, and its sockets would otherwise linger.
func Dial(ctx context.Context, cfg Config) (*Chain, error) {
	if len(cfg.Hops) == 0 {
		return nil, errNoHops
	}

	timeout := cfg.ConnectTimeout
	if timeout <= 0 {
		timeout = defaultConnectTimeout
	}
	base := cfg.BaseDialer
	if base == nil {
		base = &net.Dialer{}
	}

	c := &Chain{done: make(chan struct{})}

	for i, hop := range cfg.Hops {
		clientCfg, err := clientConfig(hop, timeout)
		if err != nil {
			c.closeClients()
			return nil, fmt.Errorf("sshtun: hop %d (%s): %w", i, hop.Host, err)
		}

		conn, err := c.dialHop(ctx, base, i, hop, timeout)
		if err != nil {
			c.closeClients()
			return nil, fmt.Errorf("sshtun: hop %d (%s): dial: %w", i, hop.Host, err)
		}

		sshConn, chans, reqs, err := handshake(conn, hop.addr(), clientCfg, timeout)
		if err != nil {
			conn.Close()
			c.closeClients()
			return nil, fmt.Errorf("sshtun: hop %d (%s): handshake: %w", i, hop.Host, err)
		}

		c.clients = append(c.clients, ssh.NewClient(sshConn, chans, reqs))
	}

	last := c.clients[len(c.clients)-1]
	go c.watch(last)

	interval := cfg.KeepAliveInterval
	if interval <= 0 {
		interval = defaultKeepAlive
	}
	go c.keepAlive(last, interval)

	return c, nil
}

// dialHop reaches hop i: the first directly, the rest through the hop before.
func (c *Chain) dialHop(
	ctx context.Context,
	base ContextDialer,
	i int,
	hop Hop,
	timeout time.Duration,
) (net.Conn, error) {
	if i == 0 {
		dialCtx, cancel := context.WithTimeout(ctx, timeout)
		defer cancel()
		return base.DialContext(dialCtx, "tcp", hop.addr())
	}
	// ssh.Client.DialContext opens a direct-tcpip channel on the previous
	// hop, which is what puts this one behind it.
	dialCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	return c.clients[i-1].DialContext(dialCtx, "tcp", hop.addr())
}

// handshake runs the SSH handshake under a time limit the connection itself
// may not be able to enforce.
//
// Only the first hop sits on a real socket. Every later one is carried by an
// SSH channel, and x/crypto's channel-backed net.Conn refuses SetDeadline
// outright, so a watchdog that closes the connection is the only bound that
// works for both. Something is needed: a server that accepts the connection
// and then says nothing would otherwise hang the chain forever, which on a
// phone reads as a spinner that never resolves.
func handshake(
	conn net.Conn,
	addr string,
	cfg *ssh.ClientConfig,
	timeout time.Duration,
) (ssh.Conn, <-chan ssh.NewChannel, <-chan *ssh.Request, error) {
	timer := time.AfterFunc(timeout, func() { conn.Close() })

	sshConn, chans, reqs, err := ssh.NewClientConn(conn, addr, cfg)

	// Stop reports false once the watchdog has already run, which turns the
	// resulting "use of closed connection" into the timeout it really was.
	timedOut := !timer.Stop()

	switch {
	case timedOut && err == nil:
		// Finished just as the watchdog fired. The connection is closed
		// underneath us, so the handshake result is worthless.
		sshConn.Close()
		return nil, nil, nil, fmt.Errorf("timed out after %s", timeout)
	case timedOut:
		return nil, nil, nil, fmt.Errorf("timed out after %s", timeout)
	case err != nil:
		return nil, nil, nil, err
	}

	return sshConn, chans, reqs, nil
}

// clientConfig assembles the auth methods for one hop.
//
// Order matters: a key is tried before a password so that a server offering
// both does not consume a password attempt first. Password and
// keyboard-interactive are both supplied with the same secret, because plenty
// of servers — Ubuntu's default sshd among them — answer a password request
// with a keyboard-interactive challenge. lib/ssh/ssh_client_factory.dart does
// the same thing for the Dart side.
func clientConfig(hop Hop, timeout time.Duration) (*ssh.ClientConfig, error) {
	if hop.Username == "" {
		return nil, errors.New("username is empty")
	}

	var methods []ssh.AuthMethod

	if hop.PrivateKeyPEM != "" {
		signer, err := parseKey(hop.PrivateKeyPEM, hop.Passphrase)
		if err != nil {
			return nil, err
		}
		methods = append(methods, ssh.PublicKeys(signer))
	}

	if hop.Password != "" {
		password := hop.Password
		methods = append(methods, ssh.Password(password))
		methods = append(methods, ssh.KeyboardInteractive(
			func(name, instruction string, questions []string, echos []bool) ([]string, error) {
				answers := make([]string, len(questions))
				for i := range answers {
					answers[i] = password
				}
				return answers, nil
			},
		))
	}

	if len(methods) == 0 {
		return nil, errors.New("no password and no private key")
	}

	return &ssh.ClientConfig{
		User: hop.Username,
		Auth: methods,
		// Host keys are not verified, which matches what dartssh2 does here
		// today: lib/ssh/ssh_client_factory.dart passes no onVerifyHostKey,
		// so the Dart client accepts whatever it is given. Changing that is
		// a product decision — it needs somewhere to pin keys and a way to
		// tell the user when one changes — and doing it here alone would
		// only make the two platforms disagree.
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout:         timeout,
	}, nil
}

func parseKey(pem, passphrase string) (ssh.Signer, error) {
	if passphrase != "" {
		signer, err := ssh.ParsePrivateKeyWithPassphrase([]byte(pem), []byte(passphrase))
		if err != nil {
			return nil, fmt.Errorf("private key with passphrase: %w", err)
		}
		return signer, nil
	}

	signer, err := ssh.ParsePrivateKey([]byte(pem))
	if err != nil {
		// A passphrase-protected key reaching this branch means the caller
		// stored the key but not its passphrase. Say so plainly rather than
		// letting "ssh: cannot decode encrypted private keys" surface.
		var missing *ssh.PassphraseMissingError
		if errors.As(err, &missing) {
			return nil, errors.New("private key is encrypted but no passphrase was given")
		}
		return nil, fmt.Errorf("private key: %w", err)
	}
	return signer, nil
}

// DialContext opens a connection from the far end of the chain. It is the
// method that makes a Chain usable as the packet engine's dialer.
func (c *Chain) DialContext(ctx context.Context, network, address string) (net.Conn, error) {
	c.mu.Lock()
	closed := c.closed
	c.mu.Unlock()
	if closed {
		return nil, errors.New("sshtun: chain is closed")
	}
	return c.clients[len(c.clients)-1].DialContext(ctx, network, address)
}

// Dial is DialContext without a context, for callers holding a proxy.Dialer.
func (c *Chain) Dial(network, address string) (net.Conn, error) {
	return c.DialContext(context.Background(), network, address)
}

// Done closes when the chain drops. The caller reconnects; this package does
// not, because the retry policy already lives in VpnController.
func (c *Chain) Done() <-chan struct{} { return c.done }

// Err reports why the chain dropped, once Done has closed. Close gives nil.
func (c *Chain) Err() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.dropErr
}

// watch turns the last hop hanging up into a Done signal.
func (c *Chain) watch(last *ssh.Client) {
	err := last.Wait()
	c.drop(err)
}

// keepAlive pokes the last hop on an interval. A phone that loses its carrier
// mid-tunnel leaves the socket open but dead; the unanswered request is what
// turns that into a drop the caller can act on.
func (c *Chain) keepAlive(last *ssh.Client, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	for {
		select {
		case <-c.done:
			return
		case <-ticker.C:
			// A false reply is still a reply: it proves the far end is
			// answering, which is all this is asking.
			if _, _, err := last.SendRequest("keepalive@openssh.com", true, nil); err != nil {
				c.drop(fmt.Errorf("sshtun: keepalive: %w", err))
				return
			}
		}
	}
}

func (c *Chain) drop(err error) {
	c.doneOnce.Do(func() {
		c.mu.Lock()
		if !c.closed {
			c.dropErr = err
		}
		c.mu.Unlock()
		close(c.done)
	})
}

// Close tears the chain down, last hop first, so that no hop is asked to
// carry a channel whose other end has already gone away.
func (c *Chain) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	c.mu.Unlock()

	c.drop(nil)
	return c.closeClients()
}

func (c *Chain) closeClients() error {
	var firstErr error
	for i := len(c.clients) - 1; i >= 0; i-- {
		if err := c.clients[i].Close(); err != nil && firstErr == nil {
			firstErr = err
		}
	}
	c.clients = nil
	return firstErr
}
