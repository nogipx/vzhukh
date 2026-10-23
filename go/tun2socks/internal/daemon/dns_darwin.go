package daemon

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// dnsOverride points every network service's DNS at the tunnel while the
// daemon runs, and puts the old servers back afterwards.
//
// Routing the system's DNS servers into the tunnel instead would miss the
// IPv6 ones routers announce, which are link-local and cannot be routed
// anywhere but their own link. Changing the setting covers every family.
//
// It is a persistent setting, so the previous one is written to a file
// before anything changes. If the daemon dies without restoring it, the next
// start finds the file and restores it before doing anything else.
type dnsOverride struct {
	backupPath string
	logf       func(string, ...any)
}

type dnsBackup struct {
	// Services maps a network service name to its manual DNS servers. An
	// empty list means none were set and DHCP's were in use.
	Services map[string][]string `json:"services"`
}

const networksetup = "/usr/sbin/networksetup"

func (o *dnsOverride) services() ([]string, error) {
	out, err := exec.Command(networksetup, "-listallnetworkservices").Output()
	if err != nil {
		return nil, fmt.Errorf("list network services: %w", err)
	}
	var services []string
	scanner := bufio.NewScanner(strings.NewReader(string(out)))
	first := true
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if first {
			// "An asterisk (*) denotes that a network service is disabled."
			first = false
			continue
		}
		if line == "" || strings.HasPrefix(line, "*") {
			continue
		}
		services = append(services, line)
	}
	return services, nil
}

func (o *dnsOverride) get(service string) ([]string, error) {
	out, err := exec.Command(networksetup, "-getdnsservers", service).Output()
	if err != nil {
		return nil, fmt.Errorf("get DNS of %s: %w", service, err)
	}
	var servers []string
	for _, line := range strings.Split(string(out), "\n") {
		line = strings.TrimSpace(line)
		if _, err := netip.ParseAddr(line); err == nil {
			servers = append(servers, line)
		}
	}
	return servers, nil
}

// errServiceGone is a service networksetup does not know: one a VPN app
// listed while it was configured and has since removed. Its DNS is nothing
// to set or put back, and failing over it would leave the tunnel unable to
// start until the saved settings were deleted by hand.
var errServiceGone = errors.New("network service is gone")

func (o *dnsOverride) set(service string, servers []string) error {
	args := []string{"-setdnsservers", service}
	if len(servers) == 0 {
		args = append(args, "Empty")
	} else {
		args = append(args, servers...)
	}
	if out, err := exec.Command(networksetup, args...).CombinedOutput(); err != nil {
		if strings.Contains(string(out), "is not a recognized network service") {
			return fmt.Errorf("set DNS of %s: %w", service, errServiceGone)
		}
		return fmt.Errorf("set DNS of %s: %v: %s", service, err, strings.TrimSpace(string(out)))
	}
	return nil
}

func (o *dnsOverride) readBackup() (*dnsBackup, error) {
	raw, err := os.ReadFile(o.backupPath)
	if err != nil {
		return nil, err
	}
	var b dnsBackup
	if err := json.Unmarshal(raw, &b); err != nil {
		return nil, err
	}
	return &b, nil
}

// Apply sets every service's DNS to server. It returns the manual servers
// that were set before, which are what the user chose and the first thing to
// forward to.
func (o *dnsOverride) Apply(server netip.Addr) ([]string, error) {
	if err := o.RestoreIfLeftOver(); err != nil {
		return nil, err
	}
	services, err := o.services()
	if err != nil {
		return nil, err
	}
	backup := dnsBackup{Services: map[string][]string{}}
	var manual []string
	for _, service := range services {
		servers, err := o.get(service)
		if err != nil {
			return nil, err
		}
		backup.Services[service] = servers
		manual = append(manual, servers...)
	}

	raw, err := json.Marshal(backup)
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(o.backupPath), 0o700); err != nil {
		return nil, err
	}
	if err := os.WriteFile(o.backupPath, raw, 0o600); err != nil {
		return nil, err
	}

	for _, service := range services {
		err := o.set(service, []string{server.String()})
		if errors.Is(err, errServiceGone) {
			o.logf("dns: %v; skipped", err)
			continue
		}
		if err != nil {
			o.Restore()
			return nil, err
		}
	}
	flushDNS()
	return manual, nil
}

// Restore puts back what Apply saved. Without a backup there is nothing to
// do.
func (o *dnsOverride) Restore() error {
	backup, err := o.readBackup()
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("read DNS backup: %w", err)
	}
	var firstErr error
	for service, servers := range backup.Services {
		err := o.set(service, servers)
		if errors.Is(err, errServiceGone) {
			o.logf("dns: %v; nothing to restore", err)
			continue
		}
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}
	if firstErr != nil {
		return firstErr
	}
	flushDNS()
	return os.Remove(o.backupPath)
}

// RestoreIfLeftOver restores a backup a previous run did not get to.
func (o *dnsOverride) RestoreIfLeftOver() error {
	if _, err := os.Stat(o.backupPath); err != nil {
		return nil
	}
	o.logf("dns: restoring settings left over from a previous run")
	return o.Restore()
}

func flushDNS() {
	exec.Command("/usr/bin/dscacheutil", "-flushcache").Run()
	exec.Command("/usr/bin/killall", "-HUP", "mDNSResponder").Run()
}

// dhcpDNS asks the DHCP client which DNS server the network handed out.
func dhcpDNS(iface string) []string {
	if iface == "" {
		return nil
	}
	out, err := exec.Command("/usr/sbin/ipconfig", "getoption", iface, "domain_name_server").Output()
	if err != nil {
		return nil
	}
	s := strings.TrimSpace(string(out))
	if _, err := netip.ParseAddr(s); err != nil {
		return nil
	}
	return []string{s}
}

// resolvConf reads the resolvers macOS currently uses.
func resolvConf() []string {
	raw, err := os.ReadFile("/etc/resolv.conf")
	if err != nil {
		return nil
	}
	var servers []string
	for _, line := range strings.Split(string(raw), "\n") {
		fields := strings.Fields(line)
		if len(fields) == 2 && fields[0] == "nameserver" {
			servers = append(servers, fields[1])
		}
	}
	return servers
}

// RestoreDNS puts back DNS settings a daemon left changed, if any. The
// uninstaller runs it after stopping the daemon, in case it died before it
// could do so itself.
func RestoreDNS(stateDir string, logf func(string, ...any)) error {
	o := &dnsOverride{backupPath: filepath.Join(stateDir, "dns-backup.json"), logf: logf}
	return o.RestoreIfLeftOver()
}

// Reassert points every service back at server if something rewrote it
// since: a corporate VPN client setting its own servers on connecting.
// What it found replaces the saved originals for that service, so those
// servers answer the names left to the system and come back when the
// tunnel goes down. It reports whether anything was rewritten.
func (o *dnsOverride) Reassert(server netip.Addr) (bool, error) {
	backup, err := o.readBackup()
	if err != nil {
		return false, err
	}
	services, err := o.services()
	if err != nil {
		return false, err
	}
	want := server.String()
	changed := false
	for _, service := range services {
		current, err := o.get(service)
		if err != nil {
			continue
		}
		if len(current) == 1 && current[0] == want {
			continue
		}
		err = o.set(service, []string{want})
		if errors.Is(err, errServiceGone) {
			continue
		}
		if err != nil {
			return changed, err
		}
		backup.Services[service] = current
		o.logf("dns: %s was set to %v; pointed back at the tunnel", service, current)
		changed = true
	}
	if changed {
		raw, err := json.Marshal(backup)
		if err == nil {
			os.WriteFile(o.backupPath, raw, 0o600)
		}
		flushDNS()
	}
	return changed, nil
}

// Originals are the servers saved for every service, the tunnel's left out.
func (o *dnsOverride) Originals() []netip.Addr {
	backup, err := o.readBackup()
	if err != nil {
		return nil
	}
	seen := map[netip.Addr]bool{}
	var out []netip.Addr
	for _, servers := range backup.Services {
		for _, raw := range servers {
			addr, err := netip.ParseAddr(raw)
			if err == nil && addr != tunDNS && !seen[addr] {
				seen[addr] = true
				out = append(out, addr)
			}
		}
	}
	return out
}
