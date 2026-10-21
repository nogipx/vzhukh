// Package procinfo finds the process behind a connection.
//
// A packet in the tunnel carries no process. What it does carry is its source
// port, and the kernel keeps a table of every socket with its local port and
// the process that last used it. Looking a connection up there, while it is
// still open, names the app.
package procinfo

import (
	"path/filepath"
	"strings"
)

// Process is what is known about the owner of a socket.
type Process struct {
	PID int `json:"pid"`

	// Path is the executable, e.g.
	// /Applications/Telegram.app/Contents/MacOS/Telegram.
	Path string `json:"path"`

	// AppPath is the outermost .app bundle the executable lives in, empty
	// for a bare executable like /usr/bin/curl.
	AppPath string `json:"appPath,omitempty"`

	// Name is what a person would call it: the bundle's name without .app,
	// or the executable's name.
	Name string `json:"name"`
}

// FromPath fills in AppPath and Name from an executable path.
//
// The outermost bundle wins, so the helpers browsers run their network code
// in (Google Chrome.app/.../Google Chrome Helper.app/...) count as the
// browser.
func FromPath(pid int, path string) Process {
	p := Process{PID: pid, Path: path, Name: filepath.Base(path)}
	if i := strings.Index(path, ".app/"); i >= 0 {
		p.AppPath = path[:i+len(".app")]
	} else if strings.HasSuffix(path, ".app") {
		p.AppPath = path
	}
	if p.AppPath != "" {
		p.Name = strings.TrimSuffix(filepath.Base(p.AppPath), ".app")
	}
	return p
}

// ExeName is the executable's own name, which for an app's helper differs
// from Name.
func (p Process) ExeName() string { return filepath.Base(p.Path) }
