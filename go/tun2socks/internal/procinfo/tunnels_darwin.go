package procinfo

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"syscall"
	"unsafe"
)

// TunnelOwners names the process behind each utun interface, keyed by its
// number: 7 for utun7.
//
// A utun exists for as long as some process holds the kernel control socket
// it was created with, so the owner is found by walking every process's
// sockets for one connected to com.apple.net.utun_control. Its unit is the
// interface number plus one. Other users' processes are only visible to
// root, which the daemon is.
func TunnelOwners() (map[int]Process, error) {
	pids, err := allPIDs()
	if err != nil {
		return nil, err
	}
	out := map[int]Process{}
	buf := make([]byte, socketInfoSize)
	for _, pid := range pids {
		if pid <= 0 {
			continue
		}
		fds, err := socketFDs(pid)
		if err != nil {
			continue
		}
		for _, fd := range fds {
			unit, ok := utunUnit(pid, fd, buf)
			if !ok {
				continue
			}
			if _, seen := out[unit]; seen {
				continue
			}
			path, err := pidPath(int(pid))
			if err != nil {
				out[unit] = Process{PID: int(pid)}
				continue
			}
			out[unit] = FromPath(int(pid), path)
		}
	}
	return out, nil
}

// proc_info(2), as libproc calls it.
const (
	procCallListPIDs  = 1
	procCallPIDInfo   = 2
	procCallPIDFDInfo = 3

	procAllPIDs         = 1
	procPIDListFDs      = 1
	procPIDFDSocketInfo = 3
	proxFDTypeSocket    = 2
	procFDInfoSize      = 8 // struct proc_fdinfo
	socketInfoSize      = 1024
	utunControlName     = "com.apple.net.utun_control"
	kernCtlUnitFromName = 4 // kcsi_unit sits just before kcsi_name
)

func procInfo(call, pid, flavor int, arg uint64, buf []byte) (int, error) {
	var ptr uintptr
	if len(buf) > 0 {
		ptr = uintptr(unsafe.Pointer(&buf[0]))
	}
	n, _, errno := syscall.Syscall6(syscall.SYS_PROC_INFO, uintptr(call), uintptr(pid), uintptr(flavor),
		uintptr(arg), ptr, uintptr(len(buf)))
	if errno != 0 {
		return 0, errno
	}
	return int(n), nil
}

func allPIDs() ([]int32, error) {
	size := 4096 * 4
	for {
		buf := make([]byte, size)
		n, err := procInfo(procCallListPIDs, procAllPIDs, 0, 0, buf)
		if err != nil {
			return nil, fmt.Errorf("procinfo: list processes: %w", err)
		}
		if n < size {
			pids := make([]int32, n/4)
			for i := range pids {
				pids[i] = int32(binary.LittleEndian.Uint32(buf[i*4:]))
			}
			return pids, nil
		}
		size *= 2
	}
}

func socketFDs(pid int32) ([]int32, error) {
	size := 256 * procFDInfoSize
	for {
		buf := make([]byte, size)
		n, err := procInfo(procCallPIDInfo, int(pid), procPIDListFDs, 0, buf)
		if err != nil {
			return nil, err
		}
		if n < size {
			var fds []int32
			for i := 0; i+procFDInfoSize <= n; i += procFDInfoSize {
				if binary.LittleEndian.Uint32(buf[i+4:]) == proxFDTypeSocket {
					fds = append(fds, int32(binary.LittleEndian.Uint32(buf[i:])))
				}
			}
			return fds, nil
		}
		size *= 2
	}
}

// utunUnit reads one socket's struct socket_fdinfo. A kernel control
// socket carries the control's name; for a utun's, the unit comes right
// before it.
func utunUnit(pid, fd int32, buf []byte) (int, bool) {
	n, err := procInfo(procCallPIDFDInfo, int(pid), procPIDFDSocketInfo, uint64(fd), buf)
	if err != nil || n <= 0 {
		return 0, false
	}
	i := bytes.Index(buf[:n], []byte(utunControlName+"\x00"))
	if i < kernCtlUnitFromName {
		return 0, false
	}
	unit := int(binary.LittleEndian.Uint32(buf[i-kernCtlUnitFromName:]))
	if unit <= 0 {
		return 0, false
	}
	return unit - 1, true
}
