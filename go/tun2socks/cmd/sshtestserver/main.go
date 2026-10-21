// Command sshtestserver is a throwaway SSH server for the Dart tunnel tests.
//
// It accepts one username and password, serves direct-tcpip and nothing else
// (refusing the host refused.test), and prints the port it listens on as
// "LISTEN <port>" on stdout. The tests freeze it with SIGSTOP to get what a
// laptop sees after sleeping: a socket that still looks open and a peer that
// never answers.
//
//	go run ./cmd/sshtestserver -user u -password p
package main

import (
	"flag"
	"fmt"
	"log"
	"time"

	"github.com/nogipx/vzhukh/tun2socks/internal/sshtest"
)

func main() {
	user := flag.String("user", "test", "username to accept")
	password := flag.String("password", "test", "password to accept")
	listen := flag.String("listen", "127.0.0.1:0", "address to listen on")
	verbose := flag.Bool("v", false, "print every forwarded destination")
	flag.Parse()

	server, err := sshtest.StartOn(*listen, *user, *password)
	if err != nil {
		log.Fatalf("start: %v", err)
	}
	fmt.Printf("LISTEN %d\n", server.Port)
	if !*verbose {
		select {}
	}
	seen := 0
	for range time.Tick(500 * time.Millisecond) {
		targets := server.Targets()
		for _, t := range targets[seen:] {
			fmt.Printf("FORWARD %s\n", t)
		}
		seen = len(targets)
	}
}
