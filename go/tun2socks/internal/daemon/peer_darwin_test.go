package daemon

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

func TestPeerUIDIsOurs(t *testing.T) {
	path := filepath.Join(t.TempDir(), "p.sock")
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	go func() {
		c, err := net.Dial("unix", path)
		if err == nil {
			defer c.Close()
			c.Read(make([]byte, 1))
		}
	}()
	conn, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	uid, err := PeerUID(conn)
	if err != nil || uid != os.Getuid() {
		t.Fatalf("uid %d err %v, want %d", uid, err, os.Getuid())
	}
}
