// Command vzhukhtunnel is the static library the iOS NetworkExtension links
// against. It is built as a C archive, not a shared library:
//
//	GOOS=ios GOARCH=arm64 CGO_ENABLED=1 go build -buildmode=c-archive
//
// See scripts/build_ios.sh, which wraps the results for both the device and
// the simulator into an XCFramework.
//
// Everything here is glue. The tunnel itself is in internal/tunnel, where it
// can be tested without an Apple toolchain anywhere near it.
package main

/*
#include <stdlib.h>
#include "bridge.h"
*/
import "C"

import (
	"context"
	"fmt"
	"runtime/debug"
	"sync"
	"unsafe"

	"github.com/nogipx/vzhukh/tun2socks/internal/tunnel"
)

// Result codes returned by vzhukh_tunnel_start. The detail behind any of them
// is in vzhukh_last_error.
const (
	resultOK            = 0
	resultAlreadyUp     = 1
	resultBadConfig     = 2
	resultStartFailed   = 3
	resultBadDescriptor = 4
)

var (
	mu       sync.Mutex
	active   *tunnel.Tunnel
	lastErr  string
	onDropFn C.vzhukh_drop_handler
)

// vzhukh_tunnel_start brings the tunnel up on an already-open TUN descriptor.
//
// The descriptor stays the caller's: it is duplicated internally, and stopping
// the tunnel does not close the original. On iOS that matters, because the
// descriptor belongs to the extension's utun and losing it would take the
// whole session down.
//
//export vzhukh_tunnel_start
func vzhukh_tunnel_start(tunFD C.int, configJSON *C.char) C.int {
	mu.Lock()
	defer mu.Unlock()

	if active != nil {
		setError("tunnel is already running")
		return resultAlreadyUp
	}
	if tunFD <= 0 {
		setError("bad tun descriptor %d", int(tunFD))
		return resultBadDescriptor
	}
	if configJSON == nil {
		setError("no configuration given")
		return resultBadConfig
	}

	cfg, err := tunnel.ParseConfig([]byte(C.GoString(configJSON)))
	if err != nil {
		setError("%v", err)
		return resultBadConfig
	}

	log := osLogger{}
	started, err := tunnel.Start(context.Background(), int(tunFD), cfg, log, reportDrop)
	if err != nil {
		setError("%v", err)
		return resultStartFailed
	}

	active = started
	lastErr = ""
	return resultOK
}

// vzhukh_tunnel_stop takes the tunnel down. Calling it when nothing is running
// is not an error — the extension stops for reasons it does not always get to
// find out about first.
//
//export vzhukh_tunnel_stop
func vzhukh_tunnel_stop() {
	mu.Lock()
	running := active
	active = nil
	mu.Unlock()

	if running != nil {
		running.Close()
	}
}

// vzhukh_tunnel_is_running reports whether a tunnel is up.
//
//export vzhukh_tunnel_is_running
func vzhukh_tunnel_is_running() C.int {
	mu.Lock()
	defer mu.Unlock()

	if active != nil {
		return 1
	}
	return 0
}

// vzhukh_last_error returns the reason the last call failed, or an empty
// string. The result is a copy the caller must release with vzhukh_free.
//
//export vzhukh_last_error
func vzhukh_last_error() *C.char {
	mu.Lock()
	defer mu.Unlock()

	return C.CString(lastErr)
}

// vzhukh_free releases a string handed out by this library.
//
//export vzhukh_free
func vzhukh_free(p *C.char) {
	if p != nil {
		C.free(unsafe.Pointer(p))
	}
}

// vzhukh_set_drop_handler registers what to call when the tunnel dies by
// itself. Pass NULL to unregister. Reconnecting is the caller's decision;
// nothing here retries.
//
//export vzhukh_set_drop_handler
func vzhukh_set_drop_handler(handler C.vzhukh_drop_handler) {
	mu.Lock()
	defer mu.Unlock()

	onDropFn = handler
}

// vzhukh_tune_runtime caps the Go heap and how hard the collector works.
//
// A packet tunnel provider is killed outright for going over roughly 50 MB,
// with no warning and nothing in the log to say why — so the limit is set
// below that and the collector told to run more eagerly than its default,
// trading throughput for staying alive.
//
//export vzhukh_tune_runtime
func vzhukh_tune_runtime(memoryLimitMB C.int, gcPercent C.int) {
	if memoryLimitMB > 0 {
		debug.SetMemoryLimit(int64(memoryLimitMB) * 1024 * 1024)
	}
	if gcPercent > 0 {
		debug.SetGCPercent(int(gcPercent))
	}
}

// reportDrop hands a self-inflicted disconnection back to Swift.
func reportDrop(err error) {
	mu.Lock()
	handler := onDropFn
	// The tunnel is finished either way; forget it so a reconnect can start
	// cleanly rather than being turned away as already running.
	active = nil
	mu.Unlock()

	if handler == nil {
		return
	}

	reason := C.CString(err.Error())
	defer C.free(unsafe.Pointer(reason))
	C.vzhukh_invoke_drop(handler, reason)
}

// setError records why something failed. The caller must already hold mu.
func setError(format string, args ...any) {
	lastErr = fmt.Sprintf(format, args...)
	emit(true, lastErr)
}

// osLogger sends both this package's messages and sing-tun's to os_log.
type osLogger struct{}

func (osLogger) Debugf(format string, args ...any) {
	emit(false, fmt.Sprintf(format, args...))
}

func (osLogger) Errorf(format string, args ...any) {
	emit(true, fmt.Sprintf(format, args...))
}

func emit(isError bool, message string) {
	text := C.CString(message)
	defer C.free(unsafe.Pointer(text))

	if isError {
		C.vzhukh_log_error(text)
	} else {
		C.vzhukh_log_info(text)
	}
}

func main() {}
