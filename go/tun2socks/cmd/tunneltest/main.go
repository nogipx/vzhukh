// Command tunneltest exercises the SSH chain on its own, away from any TUN
// device, so the half of the iOS port that has nothing to do with Apple can be
// checked before a single line of Swift exists.
//
// It builds the chain, fetches a URL through it, and prints the address the
// far end came from. If that address is the last hop's, traffic is going where
// it should.
//
//	go run ./cmd/tunneltest -host 1.2.3.4 -user root -password hunter2
//	go run ./cmd/tunneltest -config chain.json
//
// The config file is the same shape the iOS extension will be handed:
//
//	{"hops":[{"host":"1.2.3.4","port":22,"username":"root","password":"..."}]}
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/nogipx/vzhukh/tun2socks/internal/sshtun"
)

func main() {
	var (
		configPath = flag.String("config", "", "JSON file describing the whole chain")
		host       = flag.String("host", "", "single-hop shorthand: server address")
		port       = flag.Int("port", 22, "single-hop shorthand: server port")
		user       = flag.String("user", "", "single-hop shorthand: username")
		password   = flag.String("password", "", "single-hop shorthand: password")
		keyPath    = flag.String("key", "", "single-hop shorthand: private key file")
		passphrase = flag.String("passphrase", "", "single-hop shorthand: key passphrase")
		probeURL   = flag.String("url", "https://api.ipify.org", "URL to fetch through the tunnel")
		listen     = flag.String("socks", "", "also serve SOCKS5 here, e.g. 127.0.0.1:2080")
		timeout    = flag.Duration("timeout", 20*time.Second, "per-hop connect timeout")
	)
	flag.Parse()

	cfg, err := loadConfig(*configPath, sshtun.Hop{
		Host:          *host,
		Port:          *port,
		Username:      *user,
		Password:      *password,
		PrivateKeyPEM: readKey(*keyPath),
		Passphrase:    *passphrase,
	})
	if err != nil {
		fail("config: %v", err)
	}
	cfg.ConnectTimeout = *timeout

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	for i, hop := range cfg.Hops {
		fmt.Printf("hop %d: %s@%s:%d\n", i, hop.Username, hop.Host, hop.Port)
	}

	started := time.Now()
	chain, err := sshtun.Dial(ctx, cfg)
	if err != nil {
		fail("%v", err)
	}
	defer chain.Close()
	fmt.Printf("chain up in %s\n", time.Since(started).Round(time.Millisecond))

	if err := probe(ctx, chain, *probeURL); err != nil {
		fail("probe: %v", err)
	}

	if *listen == "" {
		return
	}

	fmt.Printf("\nserving SOCKS5 on %s — try: curl -x socks5h://%s https://api.ipify.org\n",
		*listen, *listen)
	if err := serveSocks(ctx, chain, *listen); err != nil {
		fail("socks: %v", err)
	}
}

// probe fetches a URL over the chain and reports what came back.
func probe(ctx context.Context, chain *sshtun.Chain, url string) error {
	client := &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				return chain.DialContext(ctx, network, addr)
			},
			// A phone reconnects often enough that a stale pooled connection
			// would be the common case, not the rare one.
			DisableKeepAlives: true,
		},
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}

	started := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if err != nil {
		return err
	}

	fmt.Printf("%s -> %s in %s\n", url, resp.Status, time.Since(started).Round(time.Millisecond))
	fmt.Printf("egress: %s\n", strings.TrimSpace(string(body)))
	return nil
}

// serveSocks runs a SOCKS5 listener so a browser or curl can be pointed at the
// chain by hand. It handles CONNECT only, which is all SSH forwarding offers.
func serveSocks(ctx context.Context, chain *sshtun.Chain, addr string) error {
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	defer ln.Close()

	go func() {
		<-ctx.Done()
		ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		go handleSocks(ctx, chain, conn)
	}
}

func handleSocks(ctx context.Context, chain *sshtun.Chain, client net.Conn) {
	defer client.Close()

	dest, err := socksHandshake(client)
	if err != nil {
		return
	}

	remote, err := chain.DialContext(ctx, "tcp", dest)
	if err != nil {
		client.Write([]byte{5, 5, 0, 1, 0, 0, 0, 0, 0, 0}) // connection refused
		fmt.Fprintf(os.Stderr, "socks: dial %s: %v\n", dest, err)
		return
	}
	defer remote.Close()

	if _, err := client.Write([]byte{5, 0, 0, 1, 0, 0, 0, 0, 0, 0}); err != nil {
		return
	}

	done := make(chan struct{}, 2)
	go func() { io.Copy(remote, client); done <- struct{}{} }()
	go func() { io.Copy(client, remote); done <- struct{}{} }()
	<-done
}

// socksHandshake reads the greeting and the CONNECT request, returning the
// destination as host:port.
func socksHandshake(client net.Conn) (string, error) {
	header := make([]byte, 2)
	if _, err := io.ReadFull(client, header); err != nil {
		return "", err
	}
	if header[0] != 5 {
		return "", fmt.Errorf("not socks5")
	}
	if _, err := io.ReadFull(client, make([]byte, header[1])); err != nil {
		return "", err
	}
	if _, err := client.Write([]byte{5, 0}); err != nil { // no auth
		return "", err
	}

	req := make([]byte, 4)
	if _, err := io.ReadFull(client, req); err != nil {
		return "", err
	}
	if req[1] != 1 {
		client.Write([]byte{5, 7, 0, 1, 0, 0, 0, 0, 0, 0}) // command unsupported
		return "", fmt.Errorf("only CONNECT is supported")
	}

	var host string
	switch req[3] {
	case 1:
		addr := make([]byte, 4)
		if _, err := io.ReadFull(client, addr); err != nil {
			return "", err
		}
		host = net.IP(addr).String()
	case 3:
		length := make([]byte, 1)
		if _, err := io.ReadFull(client, length); err != nil {
			return "", err
		}
		name := make([]byte, length[0])
		if _, err := io.ReadFull(client, name); err != nil {
			return "", err
		}
		host = string(name)
	case 4:
		addr := make([]byte, 16)
		if _, err := io.ReadFull(client, addr); err != nil {
			return "", err
		}
		host = net.IP(addr).String()
	default:
		client.Write([]byte{5, 8, 0, 1, 0, 0, 0, 0, 0, 0}) // bad address type
		return "", fmt.Errorf("unsupported address type %d", req[3])
	}

	portBytes := make([]byte, 2)
	if _, err := io.ReadFull(client, portBytes); err != nil {
		return "", err
	}
	port := int(portBytes[0])<<8 | int(portBytes[1])

	return net.JoinHostPort(host, fmt.Sprint(port)), nil
}

// loadConfig prefers the file when one is named, and otherwise builds a
// one-hop chain out of the shorthand flags.
func loadConfig(path string, single sshtun.Hop) (sshtun.Config, error) {
	if path != "" {
		raw, err := os.ReadFile(path)
		if err != nil {
			return sshtun.Config{}, err
		}
		var cfg sshtun.Config
		if err := json.Unmarshal(raw, &cfg); err != nil {
			return sshtun.Config{}, err
		}
		if len(cfg.Hops) == 0 {
			return sshtun.Config{}, fmt.Errorf("%s lists no hops", path)
		}
		return cfg, nil
	}

	if single.Host == "" || single.Username == "" {
		return sshtun.Config{}, fmt.Errorf("need -config, or both -host and -user")
	}
	return sshtun.Config{Hops: []sshtun.Hop{single}}, nil
}

func readKey(path string) string {
	if path == "" {
		return ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		fail("read key %s: %v", path, err)
	}
	return string(raw)
}

func fail(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "tunneltest: "+format+"\n", args...)
	os.Exit(1)
}
