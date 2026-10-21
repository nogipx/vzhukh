//go:build !darwin

package routetable

import "errors"

// Load is only implemented for macOS.
func Load() (Table, error) { return Table{}, errors.New("routetable: unsupported platform") }

// Entries is only implemented for macOS.
func Entries() ([]Entry, error) { return nil, errors.New("routetable: unsupported platform") }
