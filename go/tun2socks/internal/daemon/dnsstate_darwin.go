package daemon

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// dnsState points the system's resolvers at the tunnel by rewriting the
// server addresses in the dynamic store's per-service DNS entries
// (State:/Network/Service/*/DNS), which is where DHCP and VPN clients
// publish theirs.
//
// Routing the resolvers' addresses into the tunnel does not work:
// mDNSResponder sends every query from a socket bound to the interface the
// resolver came with, and a bound socket ignores the tunnel's routes. Only
// the address it is told to use moves it. The persistent network settings
// are left alone, so nothing here survives a reboot, and a VPN client that
// rewrites its own entry is simply rewritten again on the next refresh.
//
// The original addresses are kept, in memory and in a backup file: they
// answer the names rules leave to the system, and they are put back when
// the tunnel goes down, or on the next start if the daemon died first.
type dnsState struct {
	backupPath string
	logf       func(string, ...any)

	// originals maps a store key to the server addresses it had.
	originals map[string][]string
	// details keeps what each entry says besides its servers.
	details map[string]dnsEntry
}

type dnsEntry struct {
	Servers      []string `json:"servers"`
	Search       []string `json:"search,omitempty"`
	Supplemental []string `json:"supplemental,omitempty"`
	DomainName   string   `json:"domainName,omitempty"`
}

var serviceDNSKey = regexp.MustCompile(`State:/Network/Service/[^/\s]+/DNS`)

func scutil(script string) (string, error) {
	cmd := exec.Command("/usr/sbin/scutil")
	cmd.Stdin = strings.NewReader(script)
	out, err := cmd.CombinedOutput()
	return string(out), err
}

func (s *dnsState) keys() ([]string, error) {
	out, err := scutil("list State:/Network/Service/[^/]+/DNS\n")
	if err != nil {
		return nil, fmt.Errorf("scutil list: %v: %s", err, out)
	}
	return serviceDNSKey.FindAllString(out, -1), nil
}

// read parses `show KEY` for the arrays and strings that matter here.
func (s *dnsState) read(key string) (dnsEntry, bool) {
	out, err := scutil("show " + key + "\n")
	if err != nil || strings.Contains(out, "No such key") {
		return dnsEntry{}, false
	}
	return parseDNSEntry(out), true
}

// parseDNSEntry reads the output of `scutil show` for one DNS entry.
func parseDNSEntry(out string) dnsEntry {
	var e dnsEntry
	var cur *[]string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(line, "ServerAddresses"):
			cur = &e.Servers
		case strings.HasPrefix(line, "SearchDomains"):
			cur = &e.Search
		case strings.HasPrefix(line, "SupplementalMatchDomains") && strings.Contains(line, "<array>"):
			cur = &e.Supplemental
		case strings.HasPrefix(line, "DomainName :"):
			e.DomainName = strings.TrimSpace(strings.TrimPrefix(line, "DomainName :"))
			cur = nil
		case line == "}":
			cur = nil
		case cur != nil:
			if _, value, ok := strings.Cut(line, " : "); ok {
				*cur = append(*cur, strings.TrimSpace(value))
			}
		}
	}
	return e
}

func (s *dnsState) setServers(key string, servers []string) error {
	script := fmt.Sprintf("get %s\nd.add ServerAddresses * %s\nset %s\n", key, strings.Join(servers, " "), key)
	if out, err := scutil(script); err != nil {
		return fmt.Errorf("scutil set %s: %v: %s", key, err, out)
	}
	return nil
}

// Capture points every entry at server. Entries already pointing there are
// left alone; new or rewritten ones have their addresses saved first.
// It reports whether anything changed.
func (s *dnsState) Capture(server netip.Addr) (bool, error) {
	if s.originals == nil {
		s.originals = map[string][]string{}
		s.details = map[string]dnsEntry{}
	}
	keys, err := s.keys()
	if err != nil {
		return false, err
	}
	want := server.String()
	changed := false
	present := map[string]bool{}
	for _, key := range keys {
		present[key] = true
		e, ok := s.read(key)
		if !ok || len(e.Servers) == 0 {
			continue
		}
		if len(e.Servers) == 1 && e.Servers[0] == want {
			continue
		}
		s.originals[key] = e.Servers
		s.details[key] = e
		if err := s.setServers(key, []string{want}); err != nil {
			return changed, err
		}
		changed = true
		s.logf("dns: %s now resolves through the tunnel (was %v)", shortKey(key), e.Servers)
	}
	for key := range s.originals {
		if !present[key] {
			delete(s.originals, key)
			delete(s.details, key)
		}
	}
	if err := s.save(); err != nil {
		s.logf("dns: backup: %v", err)
	}
	if changed {
		flushDNS()
	}
	return changed, nil
}

// Release puts every captured entry's addresses back.
func (s *dnsState) Release() {
	for key, servers := range s.originals {
		e, ok := s.read(key)
		if !ok {
			continue
		}
		if len(e.Servers) == 1 && e.Servers[0] == tunDNS.String() {
			if err := s.setServers(key, servers); err != nil {
				s.logf("dns: restore %s: %v", shortKey(key), err)
			}
		}
	}
	s.originals, s.details = nil, nil
	os.Remove(s.backupPath)
	flushDNS()
}

// Resolvers describes the captured entries with their original servers,
// for picking who answers names left to the system.
func (s *dnsState) Resolvers() []sysResolver {
	var out []sysResolver
	for _, e := range s.details {
		var servers []netip.Addr
		for _, raw := range e.Servers {
			if addr, err := netip.ParseAddr(raw); err == nil {
				servers = append(servers, addr)
			}
		}
		search := e.Search
		if e.DomainName != "" {
			search = append(search, strings.ToLower(e.DomainName))
		}
		if len(e.Supplemental) > 0 {
			for _, d := range e.Supplemental {
				if d = strings.TrimSuffix(strings.ToLower(d), "."); d != "" {
					out = append(out, sysResolver{Domain: d, Servers: servers})
				}
			}
			continue
		}
		out = append(out, sysResolver{Search: search, Servers: servers})
	}
	return out
}

func (s *dnsState) save() error {
	if len(s.originals) == 0 {
		return nil
	}
	raw, err := json.Marshal(s.originals)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(s.backupPath), 0o700); err != nil {
		return err
	}
	return os.WriteFile(s.backupPath, raw, 0o600)
}

// RestoreLeftOver puts back entries a previous run left pointing at the
// tunnel, from the backup it wrote.
func (s *dnsState) RestoreLeftOver() {
	raw, err := os.ReadFile(s.backupPath)
	if errors.Is(err, os.ErrNotExist) {
		return
	}
	if err == nil {
		var originals map[string][]string
		if json.Unmarshal(raw, &originals) == nil {
			s.originals = originals
			s.logf("dns: restoring entries left pointing at the tunnel")
		}
	}
	s.Release()
}

func shortKey(key string) string {
	key = strings.TrimPrefix(key, "State:/Network/Service/")
	return strings.TrimSuffix(key, "/DNS")
}
