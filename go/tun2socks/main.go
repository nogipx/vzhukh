// Flume tun2socks — reads IP packets from TUN fd and routes them through SOCKS5.
// Compiled as a shared library (.so) for Android via:
//   GOOS=android GOARCH=arm64 CGO_ENABLED=1 go build -buildmode=c-shared -o libtun2socks.so .
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"context"
	"fmt"
	"os"
	"sync"

	"github.com/xjasonlyu/tun2socks/v2/engine"
)

var (
	mu      sync.Mutex
	cancel  context.CancelFunc
	running bool
)

// tun2socks_start opens the TUN fd and starts routing traffic through socksAddr.
// Returns 0 on success, non-zero on error.
//
//export tun2socks_start
func tun2socks_start(tunFd C.int, socksAddr *C.char) C.int {
	mu.Lock()
	defer mu.Unlock()

	if running {
		return 1 // already running
	}

	addr := C.GoString(socksAddr)
	if addr == "" {
		fmt.Fprintln(os.Stderr, "tun2socks: empty socks address")
		return 2
	}

	// Duplicate the fd so Go owns its own copy (the Dart side keeps the original).
	fd := int(tunFd)

	ctx, cancelFn := context.WithCancel(context.Background())
	cancel = cancelFn

	key := &engine.Key{
		Proxy:   "socks5://" + addr,
		Device:  fmt.Sprintf("fd://%d", fd),
		LogLevel: "warning",
	}

	engine.Insert(key)
	if err := engine.Start(); err != nil {
		cancelFn()
		fmt.Fprintf(os.Stderr, "tun2socks: engine.Start: %v\n", err)
		return 3
	}

	running = true

	// Stop when context is cancelled.
	go func() {
		<-ctx.Done()
		engine.Stop()
	}()

	return 0
}

// tun2socks_stop stops the routing engine.
//
//export tun2socks_stop
func tun2socks_stop() {
	mu.Lock()
	defer mu.Unlock()

	if !running {
		return
	}
	if cancel != nil {
		cancel()
		cancel = nil
	}
	running = false
}

func main() {}
