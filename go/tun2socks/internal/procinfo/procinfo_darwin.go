package procinfo

import (
	"encoding/binary"
	"errors"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
	"syscall"
	"unsafe"

	"golang.org/x/sys/unix"
)

// ErrNotFound means no socket in the table has that local address. The
// connection may already be closed.
var ErrNotFound = errors.New("procinfo: no such socket")

// Lookup finds the process owning the socket bound to local, for network
// "tcp" or "udp".
//
// The table is read with sysctl net.inet.{tcp,udp}.pcblist_n, the same one
// netstat reads, which needs no privileges. Its records are a run of
// structures from xnu's bsd/netinet/in_pcb.h, each padded to 8 bytes; the
// offsets below are from there and match what sing-box and Clash use.
func Lookup(network string, local netip.AddrPort) (Process, error) {
	var name string
	itemSize := pcbItemSize
	switch network {
	case "tcp":
		name = "net.inet.tcp.pcblist_n"
		itemSize += xtcpcbSize
	case "udp":
		name = "net.inet.udp.pcblist_n"
	default:
		return Process{}, fmt.Errorf("procinfo: unknown network %q", network)
	}

	buf, err := unix.SysctlRaw(name)
	if err != nil {
		return Process{}, fmt.Errorf("procinfo: %s: %w", name, err)
	}

	pid, ok := findPID(buf, itemSize, network == "udp", local)
	if !ok {
		return Process{}, ErrNotFound
	}
	path, err := pidPath(pid)
	if err != nil {
		return Process{PID: pid}, err
	}
	return FromPath(pid, path), nil
}

const (
	xinpgenSize = 24 // header before the first record

	// Offsets inside xinpcb_n.
	inpLPortOffset  = 18
	inpVFlagOffset  = 44
	inpLAddr6Offset = 64 // in6_addr, 16 bytes
	inpLAddr4Offset = 76 // in_addr in the last 4 bytes of the same union

	// xsocket_n follows xinpcb_n at this offset.
	xsocketOffset = 104

	// Offsets inside xsocket_n.
	soLastPIDOffset = 68
	soEPIDOffset    = 72

	inpIPv4 = 0x1
	inpIPv6 = 0x2

	xtcpcbSize = 208 // rup8(sizeof(xtcpcb_n)), tcp records only
)

// pcbItemSize is rup8 of xinpcb_n + xsocket_n + 2 * xsockbuf_n + xsockstat_n.
// xsocket_n grew in Darwin 22 (macOS 13).
var pcbItemSize = func() int {
	release, _ := unix.Sysctl("kern.osrelease")
	major, _, _ := strings.Cut(release, ".")
	if n, _ := strconv.Atoi(major); n >= 22 {
		return 408
	}
	return 384
}()

// findPID scans the records for local. A UDP socket bound to the unspecified
// address matches any local address on its port, but only if nothing bound
// to the exact address does.
func findPID(buf []byte, itemSize int, udp bool, local netip.AddrPort) (int, bool) {
	want := local.Addr().Unmap()
	fallback := 0
	for i := xinpgenSize; i+itemSize <= len(buf); i += itemSize {
		inp, so := i, i+xsocketOffset
		if binary.BigEndian.Uint16(buf[inp+inpLPortOffset:]) != local.Port() {
			continue
		}

		flag := buf[inp+inpVFlagOffset]
		var addr netip.Addr
		switch {
		case flag&inpIPv4 != 0 && want.Is4():
			addr = netip.AddrFrom4([4]byte(buf[inp+inpLAddr4Offset : inp+inpLAddr4Offset+4]))
		case flag&inpIPv6 != 0 && want.Is6():
			addr = netip.AddrFrom16([16]byte(buf[inp+inpLAddr6Offset : inp+inpLAddr6Offset+16]))
		default:
			continue
		}

		pid := ownerPID(buf, so)
		if addr == want {
			return pid, pid > 0
		}
		if udp && addr.IsUnspecified() && fallback == 0 {
			fallback = pid
		}
	}
	return fallback, fallback > 0
}

// ownerPID prefers the effective pid. When a system service opens a socket
// on behalf of an app (Safari's networking runs in a WebKit process), the
// kernel records the app there.
func ownerPID(buf []byte, so int) int {
	ePID := int(int32(binary.LittleEndian.Uint32(buf[so+soEPIDOffset:])))
	if ePID > 0 {
		return ePID
	}
	return int(int32(binary.LittleEndian.Uint32(buf[so+soLastPIDOffset:])))
}

// pidPath asks proc_info(PROC_PIDPATHINFO) for the executable of pid.
func pidPath(pid int) (string, error) {
	const (
		procCallNumPIDInfo  = 2
		procPIDPathInfo     = 11
		procPIDPathInfoSize = 4 * 1024
	)
	buf := make([]byte, procPIDPathInfoSize)
	_, _, errno := syscall.Syscall6(
		syscall.SYS_PROC_INFO,
		procCallNumPIDInfo,
		uintptr(pid),
		procPIDPathInfo,
		0,
		uintptr(unsafe.Pointer(&buf[0])),
		procPIDPathInfoSize,
	)
	if errno != 0 {
		return "", fmt.Errorf("procinfo: path of pid %d: %w", pid, errno)
	}
	return unix.ByteSliceToString(buf), nil
}
