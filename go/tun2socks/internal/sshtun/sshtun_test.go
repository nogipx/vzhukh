package sshtun

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/pem"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/ssh"
)

// The tests run a real SSH server in-process rather than mocking one out.
// What is worth checking here is the parts that are easy to get subtly wrong —
// hop chaining, key parsing, auth negotiation — and those only misbehave
// against something that speaks the actual protocol.

func TestDialRejectsEmptyHops(t *testing.T) {
	t.Parallel()

	_, err := Dial(context.Background(), Config{})
	if !errors.Is(err, errNoHops) {
		t.Fatalf("got %v, want errNoHops", err)
	}
}

func TestHopAddrDefaultsToPort22(t *testing.T) {
	t.Parallel()

	if got := (Hop{Host: "example.com"}).addr(); got != "example.com:22" {
		t.Errorf("got %q, want example.com:22", got)
	}
	if got := (Hop{Host: "example.com", Port: 2222}).addr(); got != "example.com:2222" {
		t.Errorf("got %q, want example.com:2222", got)
	}
}

func TestSingleHopReachesTheOtherSide(t *testing.T) {
	t.Parallel()

	echo := startEcho(t)
	server := startSSHServer(t, withPassword("hunter2"))

	chain := dialChain(t, Config{Hops: []Hop{server.hop("root", "hunter2")}})

	if got := roundTrip(t, chain, echo.addr, "ping"); got != "ping" {
		t.Errorf("got %q, want ping", got)
	}
}

func TestMultiHopTraversesEveryServer(t *testing.T) {
	t.Parallel()

	echo := startEcho(t)
	first := startSSHServer(t, withPassword("one"))
	second := startSSHServer(t, withPassword("two"))

	chain := dialChain(t, Config{Hops: []Hop{
		first.hop("root", "one"),
		second.hop("root", "two"),
	}})

	if got := roundTrip(t, chain, echo.addr, "through both"); got != "through both" {
		t.Errorf("got %q, want %q", got, "through both")
	}

	// The first hop should have been asked to reach the second, and the
	// second to reach the echo server. That ordering is the whole point of a
	// chain, and an end-to-end read alone would not prove it.
	if forwarded := first.forwards(); !contains(forwarded, second.addr) {
		t.Errorf("first hop forwarded to %v, want it to include %s", forwarded, second.addr)
	}
	if forwarded := second.forwards(); !contains(forwarded, echo.addr) {
		t.Errorf("second hop forwarded to %v, want it to include %s", forwarded, echo.addr)
	}
	if forwarded := first.forwards(); contains(forwarded, echo.addr) {
		t.Errorf("first hop reached the echo server directly: %v", forwarded)
	}
}

func TestKeyboardInteractiveGetsTheSamePassword(t *testing.T) {
	t.Parallel()

	// Ubuntu's sshd answers a password attempt with a keyboard-interactive
	// challenge, so a client offering only ssh.Password never gets in. The
	// Dart side works around this in lib/ssh/ssh_client_factory.dart and this
	// package has to match.
	echo := startEcho(t)
	server := startSSHServer(t, withKeyboardInteractiveOnly("hunter2"))

	chain := dialChain(t, Config{Hops: []Hop{server.hop("root", "hunter2")}})

	if got := roundTrip(t, chain, echo.addr, "kbd"); got != "kbd" {
		t.Errorf("got %q, want kbd", got)
	}
}

func TestPrivateKeyAuth(t *testing.T) {
	t.Parallel()

	key := generateKey(t)
	echo := startEcho(t)
	server := startSSHServer(t, withPublicKey(key.public))

	chain := dialChain(t, Config{Hops: []Hop{{
		Host:          server.host,
		Port:          server.port,
		Username:      "root",
		PrivateKeyPEM: key.pem,
	}}})

	if got := roundTrip(t, chain, echo.addr, "by key"); got != "by key" {
		t.Errorf("got %q, want %q", got, "by key")
	}
}

func TestEncryptedKeyAuth(t *testing.T) {
	t.Parallel()

	key := generateEncryptedKey(t, "s3cret")
	echo := startEcho(t)
	server := startSSHServer(t, withPublicKey(key.public))

	chain := dialChain(t, Config{Hops: []Hop{{
		Host:          server.host,
		Port:          server.port,
		Username:      "root",
		PrivateKeyPEM: key.pem,
		Passphrase:    "s3cret",
	}}})

	if got := roundTrip(t, chain, echo.addr, "encrypted"); got != "encrypted" {
		t.Errorf("got %q, want %q", got, "encrypted")
	}
}

func TestEncryptedKeyWithoutPassphraseSaysSo(t *testing.T) {
	t.Parallel()

	key := generateEncryptedKey(t, "s3cret")

	_, err := clientConfig(Hop{Username: "root", PrivateKeyPEM: key.pem}, time.Second)
	if err == nil {
		t.Fatal("expected an error")
	}
	// x/crypto's own wording is "ssh: cannot decode encrypted private keys",
	// which does not tell the user what to do about it.
	if !strings.Contains(err.Error(), "no passphrase") {
		t.Errorf("got %q, want it to mention the missing passphrase", err)
	}
}

func TestBadPasswordFails(t *testing.T) {
	t.Parallel()

	server := startSSHServer(t, withPassword("hunter2"))

	_, err := Dial(context.Background(), Config{
		Hops:           []Hop{server.hop("root", "wrong")},
		ConnectTimeout: 5 * time.Second,
	})
	if err == nil {
		t.Fatal("expected authentication to fail")
	}
	if !strings.Contains(err.Error(), "hop 0") {
		t.Errorf("got %q, want it to name the hop that failed", err)
	}
}

func TestFailedHopClosesEarlierOnes(t *testing.T) {
	t.Parallel()

	first := startSSHServer(t, withPassword("one"))
	second := startSSHServer(t, withPassword("two"))

	_, err := Dial(context.Background(), Config{
		Hops: []Hop{
			first.hop("root", "one"),
			second.hop("root", "wrong"),
		},
		ConnectTimeout: 5 * time.Second,
	})
	if err == nil {
		t.Fatal("expected the second hop to fail")
	}

	// The first hop authenticated before the second refused. Leaving its
	// connection open would leak a socket per reconnect attempt, and a phone
	// retries a lot.
	waitFor(t, "first hop to be closed", func() bool { return first.liveConns() == 0 })
}

func TestClientConfigRequiresCredentials(t *testing.T) {
	t.Parallel()

	if _, err := clientConfig(Hop{Username: "root"}, time.Second); err == nil {
		t.Error("expected an error when neither password nor key is given")
	}
	if _, err := clientConfig(Hop{Password: "x"}, time.Second); err == nil {
		t.Error("expected an error when the username is empty")
	}
}

func TestCloseIsIdempotentAndReportsNoError(t *testing.T) {
	t.Parallel()

	server := startSSHServer(t, withPassword("hunter2"))
	chain := dialChain(t, Config{Hops: []Hop{server.hop("root", "hunter2")}})

	if err := chain.Close(); err != nil {
		t.Errorf("first close: %v", err)
	}
	if err := chain.Close(); err != nil {
		t.Errorf("second close: %v", err)
	}

	select {
	case <-chain.Done():
	case <-time.After(2 * time.Second):
		t.Fatal("Done did not close")
	}

	// A chain the caller shut down deliberately has no failure to report;
	// VpnController uses that to tell a drop apart from a disconnect.
	if err := chain.Err(); err != nil {
		t.Errorf("Err after Close = %v, want nil", err)
	}

	if _, err := chain.DialContext(context.Background(), "tcp", "example.com:80"); err == nil {
		t.Error("expected dialling a closed chain to fail")
	}
}

func TestServerHangingUpSignalsDone(t *testing.T) {
	t.Parallel()

	server := startSSHServer(t, withPassword("hunter2"))
	chain := dialChain(t, Config{Hops: []Hop{server.hop("root", "hunter2")}})

	server.dropConnections()

	select {
	case <-chain.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("Done did not close after the server hung up")
	}
	if chain.Err() == nil {
		t.Error("Err = nil, want the reason the chain dropped")
	}
}

// --- helpers ---------------------------------------------------------------

func dialChain(t *testing.T, cfg Config) *Chain {
	t.Helper()

	if cfg.ConnectTimeout == 0 {
		cfg.ConnectTimeout = 10 * time.Second
	}
	chain, err := Dial(context.Background(), cfg)
	if err != nil {
		t.Fatalf("Dial: %v", err)
	}
	t.Cleanup(func() { chain.Close() })
	return chain
}

// roundTrip sends a line through the chain to an echo server and returns what
// came back.
func roundTrip(t *testing.T, chain *Chain, addr, message string) string {
	t.Helper()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	conn, err := chain.DialContext(ctx, "tcp", addr)
	if err != nil {
		t.Fatalf("DialContext: %v", err)
	}
	defer conn.Close()

	if _, err := conn.Write([]byte(message)); err != nil {
		t.Fatalf("write: %v", err)
	}

	buf := make([]byte, len(message))
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatalf("read: %v", err)
	}
	return string(buf)
}

// echoServer sends back whatever it is given.
type echoServer struct{ addr string }

func startEcho(t *testing.T) *echoServer {
	t.Helper()

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer conn.Close()
				io.Copy(conn, conn)
			}()
		}
	}()

	return &echoServer{addr: ln.Addr().String()}
}

// sshServer is enough of an SSH server to authenticate a client and honour
// direct-tcpip, which is the only channel type this package opens.
type sshServer struct {
	t    *testing.T
	addr string
	host string
	port int

	mu        sync.Mutex
	forwarded []string
	conns     []net.Conn
}

type serverOption func(*ssh.ServerConfig)

func withPassword(password string) serverOption {
	return func(cfg *ssh.ServerConfig) {
		cfg.PasswordCallback = func(_ ssh.ConnMetadata, given []byte) (*ssh.Permissions, error) {
			if string(given) == password {
				return nil, nil
			}
			return nil, errors.New("wrong password")
		}
	}
}

// withKeyboardInteractiveOnly refuses plain password auth, the way a stock
// Ubuntu sshd effectively does.
func withKeyboardInteractiveOnly(password string) serverOption {
	return func(cfg *ssh.ServerConfig) {
		cfg.KeyboardInteractiveCallback = func(
			_ ssh.ConnMetadata,
			challenge ssh.KeyboardInteractiveChallenge,
		) (*ssh.Permissions, error) {
			answers, err := challenge("", "", []string{"Password: "}, []bool{false})
			if err != nil {
				return nil, err
			}
			if len(answers) == 1 && answers[0] == password {
				return nil, nil
			}
			return nil, errors.New("wrong password")
		}
	}
}

func withPublicKey(authorized ssh.PublicKey) serverOption {
	return func(cfg *ssh.ServerConfig) {
		cfg.PublicKeyCallback = func(_ ssh.ConnMetadata, offered ssh.PublicKey) (*ssh.Permissions, error) {
			if bytes.Equal(offered.Marshal(), authorized.Marshal()) {
				return nil, nil
			}
			return nil, errors.New("unknown key")
		}
	}
}

func startSSHServer(t *testing.T, opts ...serverOption) *sshServer {
	t.Helper()

	cfg := &ssh.ServerConfig{}
	for _, opt := range opts {
		opt(cfg)
	}
	cfg.AddHostKey(generateKey(t).signer)

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	host, portStr, err := net.SplitHostPort(ln.Addr().String())
	if err != nil {
		t.Fatalf("split %s: %v", ln.Addr(), err)
	}
	port, err := strconv.Atoi(portStr)
	if err != nil {
		t.Fatalf("port %s: %v", portStr, err)
	}

	s := &sshServer{t: t, addr: ln.Addr().String(), host: host, port: port}

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			s.mu.Lock()
			s.conns = append(s.conns, conn)
			s.mu.Unlock()
			go s.serve(conn, cfg)
		}
	}()

	return s
}

func (s *sshServer) hop(username, password string) Hop {
	return Hop{Host: s.host, Port: s.port, Username: username, Password: password}
}

func (s *sshServer) serve(conn net.Conn, cfg *ssh.ServerConfig) {
	sshConn, chans, reqs, err := ssh.NewServerConn(conn, cfg)
	if err != nil {
		conn.Close()
		return
	}
	defer sshConn.Close()

	// Replies false to everything, keepalives included, which is all the
	// client needs to know the far end is still answering.
	go ssh.DiscardRequests(reqs)

	for newChannel := range chans {
		if newChannel.ChannelType() != "direct-tcpip" {
			newChannel.Reject(ssh.UnknownChannelType, newChannel.ChannelType())
			continue
		}
		go s.forward(newChannel)
	}
}

// directTCPIP is the payload of a direct-tcpip channel open, per RFC 4254 7.2.
type directTCPIP struct {
	DestHost string
	DestPort uint32
	SrcHost  string
	SrcPort  uint32
}

func (s *sshServer) forward(newChannel ssh.NewChannel) {
	var payload directTCPIP
	if err := ssh.Unmarshal(newChannel.ExtraData(), &payload); err != nil {
		newChannel.Reject(ssh.ConnectionFailed, "bad payload")
		return
	}

	target := net.JoinHostPort(payload.DestHost, strconv.Itoa(int(payload.DestPort)))

	s.mu.Lock()
	s.forwarded = append(s.forwarded, target)
	s.mu.Unlock()

	remote, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		newChannel.Reject(ssh.ConnectionFailed, err.Error())
		return
	}
	defer remote.Close()

	channel, reqs, err := newChannel.Accept()
	if err != nil {
		return
	}
	defer channel.Close()
	go ssh.DiscardRequests(reqs)

	done := make(chan struct{}, 2)
	go func() { io.Copy(channel, remote); done <- struct{}{} }()
	go func() { io.Copy(remote, channel); done <- struct{}{} }()
	<-done
}

func (s *sshServer) forwards() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.forwarded...)
}

// dropConnections hangs up on every client without a graceful close, the way
// a carrier dropping a phone's connection would.
func (s *sshServer) dropConnections() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, conn := range s.conns {
		conn.Close()
	}
	s.conns = nil
}

func (s *sshServer) liveConns() int {
	s.mu.Lock()
	defer s.mu.Unlock()

	live := 0
	for _, conn := range s.conns {
		// A one-byte read with an expired deadline distinguishes a closed
		// connection from an idle one: closed gives io.EOF or a use-of-
		// closed error, idle gives a timeout.
		conn.SetReadDeadline(time.Now().Add(10 * time.Millisecond))
		_, err := conn.Read(make([]byte, 1))
		var netErr net.Error
		if err == nil || (errors.As(err, &netErr) && netErr.Timeout()) {
			live++
		}
		conn.SetReadDeadline(time.Time{})
	}
	return live
}

type testKey struct {
	pem    string
	public ssh.PublicKey
	signer ssh.Signer
}

func generateKey(t *testing.T) testKey {
	t.Helper()

	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	block, err := ssh.MarshalPrivateKey(private, "")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	return testKey{
		pem:    string(pem.EncodeToMemory(block)),
		public: signer.PublicKey(),
		signer: signer,
	}
}

func generateEncryptedKey(t *testing.T, passphrase string) testKey {
	t.Helper()

	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate: %v", err)
	}
	block, err := ssh.MarshalPrivateKeyWithPassphrase(private, "", []byte(passphrase))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatalf("signer: %v", err)
	}
	return testKey{
		pem:    string(pem.EncodeToMemory(block)),
		public: signer.PublicKey(),
		signer: signer,
	}
}

func waitFor(t *testing.T, what string, done func() bool) {
	t.Helper()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if done() {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", what)
}

func contains(haystack []string, needle string) bool {
	for _, item := range haystack {
		if item == needle {
			return true
		}
	}
	return false
}
