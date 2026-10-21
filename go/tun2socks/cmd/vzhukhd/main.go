// Command vzhukhd is the root helper behind vzhukh on macOS.
//
// launchd starts it at boot and keeps it running. It sits idle until the
// app connects over its Unix socket and sends a config; then it creates a
// utun, routes all traffic into it, and sends each connection through an
// SSH route, straight out, or nowhere, by the app's rules. See
// docs/macos-daemon.md.
//
//	vzhukhd -uid 501
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"

	tun "github.com/sagernet/sing-tun"

	"github.com/nogipx/vzhukh/tun2socks/internal/daemon"
)

func main() {
	socket := flag.String("socket", "/var/run/vzhukhd.sock", "control socket")
	uid := flag.Int("uid", -1, "the one user besides root allowed to control the daemon")
	stateDir := flag.String("state", "/Library/Application Support/vzhukhd", "where the DNS backup is kept")
	version := flag.Bool("version", false, "print the version and exit")
	restoreDNS := flag.Bool("restore-dns", false, "put back DNS settings a previous run left changed, and exit")
	flag.Parse()

	if *version {
		fmt.Println(daemon.Version)
		return
	}
	if !tun.WithGVisor {
		log.Fatal("vzhukhd was built without -tags with_gvisor and has no packet stack")
	}
	if os.Geteuid() != 0 {
		log.Fatal("vzhukhd must run as root: it creates a network interface and changes routes")
	}
	if *uid < 0 && !*restoreDNS {
		log.Fatal("-uid is required: without it nobody but root could connect")
	}

	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	logf := log.Printf

	if *restoreDNS {
		if err := daemon.RestoreDNS(*stateDir, logf); err != nil {
			log.Fatalf("restore DNS: %v", err)
		}
		return
	}

	if err := os.MkdirAll(*stateDir, 0o700); err != nil {
		log.Fatalf("state dir: %v", err)
	}
	platform, err := daemon.NewDarwinPlatform(*stateDir, logf)
	if err != nil {
		log.Fatalf("platform: %v", err)
	}
	d, err := daemon.New(platform, logf)
	if err != nil {
		log.Fatalf("daemon: %v", err)
	}

	if err := os.MkdirAll(filepath.Dir(*socket), 0o755); err != nil {
		log.Fatalf("socket dir: %v", err)
	}
	ln, err := daemon.ListenUnix(*socket, *uid)
	if err != nil {
		log.Fatalf("listen %s: %v", *socket, err)
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		sig := <-signals
		logf("vzhukhd: %s, shutting down", sig)
		ln.Close()
		d.Stop()
		platform.Shutdown()
		os.Remove(*socket)
		os.Exit(0)
	}()

	logf("vzhukhd %s: listening on %s for uid %d", daemon.Version, *socket, *uid)
	server := &daemon.IPCServer{Daemon: d, AllowedUID: *uid, PeerUID: daemon.PeerUID, Logf: logf}
	if err := server.Serve(ln); err != nil {
		log.Fatalf("serve: %v", err)
	}
	select {}
}
