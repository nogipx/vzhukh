package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/nogipx/vzhukh/tun2socks/internal/router"
	"net"
	"os"
	"sync"
)

// The app talks to the daemon over a Unix socket, one JSON object per line:
//
//	→ {"id": 1, "method": "start", "params": {...}}
//	← {"id": 1, "result": {...}}  or  {"id": 1, "error": "..."}
//
// Methods: hello, status, start (params Config), rules (params
// router.Config), stop, flows (params {"since": n}), nudge.
//
// Only root and the one user the daemon was installed for may connect. The
// socket file is theirs with mode 0600, and every connection's peer uid is
// checked as well. Nothing a client sends names a file or a command: the
// worst a hostile process of that user can do is reroute that user's
// traffic and read the connection list.

type request struct {
	ID     int64           `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params,omitempty"`
}

type response struct {
	ID     int64  `json:"id"`
	Result any    `json:"result,omitempty"`
	Error  string `json:"error,omitempty"`
}

// maxMessage bounds one line. A config with a handful of keys is a few KB.
const maxMessage = 4 << 20

// IPCServer serves one daemon.
type IPCServer struct {
	Daemon *Daemon

	// AllowedUID may connect besides root. Negative allows anyone, which
	// only tests want.
	AllowedUID int

	// PeerUID reads the uid of the process at the other end. Tests on
	// platforms without one may leave it nil together with AllowedUID < 0.
	PeerUID func(net.Conn) (int, error)

	Logf func(string, ...any)

	mu    sync.Mutex
	conns map[net.Conn]bool
}

// ListenUnix creates the socket at path for uid. An old socket from a
// previous run is removed first.
func ListenUnix(path string, uid int) (net.Listener, error) {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		return nil, err
	}
	if uid >= 0 {
		if err := os.Chown(path, uid, 0); err != nil {
			ln.Close()
			return nil, err
		}
	}
	return ln, nil
}

// Serve accepts until ln closes.
func (s *IPCServer) Serve(ln net.Listener) error {
	if s.Logf == nil {
		s.Logf = func(string, ...any) {}
	}
	for {
		conn, err := ln.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go s.serveConn(conn)
	}
}

func (s *IPCServer) allowed(conn net.Conn) error {
	if s.AllowedUID < 0 {
		return nil
	}
	if s.PeerUID == nil {
		return errors.New("no way to check the peer")
	}
	uid, err := s.PeerUID(conn)
	if err != nil {
		return err
	}
	if uid != 0 && uid != s.AllowedUID {
		return fmt.Errorf("uid %d may not connect", uid)
	}
	return nil
}

func (s *IPCServer) serveConn(conn net.Conn) {
	defer conn.Close()
	if err := s.allowed(conn); err != nil {
		s.Logf("ipc: refused: %v", err)
		return
	}

	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 64*1024), maxMessage)
	encoder := json.NewEncoder(conn)
	for scanner.Scan() {
		var req request
		if err := json.Unmarshal(scanner.Bytes(), &req); err != nil {
			encoder.Encode(response{Error: "bad request: " + err.Error()})
			continue
		}
		result, err := s.call(req)
		resp := response{ID: req.ID, Result: result}
		if err != nil {
			resp.Error = err.Error()
		}
		if err := encoder.Encode(resp); err != nil {
			return
		}
	}
}

func (s *IPCServer) call(req request) (any, error) {
	d := s.Daemon
	switch req.Method {
	case "hello":
		return map[string]any{"version": Version, "pid": os.Getpid()}, nil
	case "status":
		return d.Status(), nil
	case "start":
		var cfg Config
		if err := json.Unmarshal(req.Params, &cfg); err != nil {
			return nil, fmt.Errorf("bad config: %w", err)
		}
		s.Logf("ipc: start: %s", summarize(cfg))
		if err := d.Start(cfg); err != nil {
			return nil, err
		}
		return d.Status(), nil
	case "rules":
		var rules router.Config
		if err := json.Unmarshal(req.Params, &rules); err != nil {
			return nil, fmt.Errorf("bad rules: %w", err)
		}
		if err := d.SetRules(rules); err != nil {
			return nil, err
		}
		return d.Status(), nil
	case "stop":
		if err := d.Stop(); err != nil {
			return nil, err
		}
		return d.Status(), nil
	case "flows":
		var p struct {
			Since uint64 `json:"since"`
		}
		if len(req.Params) > 0 {
			if err := json.Unmarshal(req.Params, &p); err != nil {
				return nil, err
			}
		}
		return d.Flows(p.Since), nil
	case "stats":
		var p struct {
			Window int `json:"window"`
		}
		if len(req.Params) > 0 {
			if err := json.Unmarshal(req.Params, &p); err != nil {
				return nil, err
			}
		}
		return d.FlowStats(p.Window), nil
	case "record":
		var p struct {
			On bool `json:"on"`
		}
		if len(req.Params) > 0 {
			if err := json.Unmarshal(req.Params, &p); err != nil {
				return nil, err
			}
		}
		d.RecordFlows(p.On)
		return d.Flows(0), nil
	case "clearFlows":
		d.ClearFlows()
		return d.Flows(0), nil
	case "vpns":
		return d.VPNs(), nil
	case "nudge":
		d.Nudge("asked by the app")
		return d.Status(), nil
	default:
		return nil, fmt.Errorf("unknown method %q", req.Method)
	}
}
