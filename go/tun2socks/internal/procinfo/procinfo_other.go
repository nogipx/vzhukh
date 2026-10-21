//go:build !darwin

package procinfo

import (
	"errors"
	"net/netip"
)

// ErrNotFound means no socket in the table has that local address.
var ErrNotFound = errors.New("procinfo: no such socket")

// Lookup is only implemented for macOS.
func Lookup(network string, local netip.AddrPort) (Process, error) {
	return Process{}, errors.New("procinfo: unsupported platform")
}
