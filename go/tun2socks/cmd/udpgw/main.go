// Command udpgw relays UDP for vzhukh clients, so UDP can cross an SSH
// chain, which forwards only TCP. It speaks badvpn-udpgw's protocol.
//
// Run it on the server, listening on loopback only: clients reach it
// through their SSH session, as any other forwarded TCP connection.
//
//	udpgw -listen 127.0.0.1:7300
//
// `just udpgw-install user@host` installs it as a systemd service.
package main

import (
	"flag"
	"log"
	"net"
	"time"

	"github.com/nogipx/vzhukh/tun2socks/internal/udpgw"
)

func main() {
	listen := flag.String("listen", udpgw.DefaultAddr, "address to listen on; keep it on loopback")
	idle := flag.Duration("idle", 2*time.Minute, "how long a UDP session lives without traffic")
	flag.Parse()

	ln, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("listen %s: %v", *listen, err)
	}
	log.Printf("udpgw: listening on %s", *listen)
	log.Fatal(udpgw.Serve(ln, *idle, log.Printf))
}
