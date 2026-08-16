// Exposes the kernel control socket API to Swift.
//
// Finding the utun descriptor means asking each open descriptor whether it is
// a socket in the AF_SYSTEM family whose control ID belongs to
// com.apple.net.utun_control. The types for that live in <sys/kern_control.h>,
// which the macOS SDK ships and the iOS SDK does not — the interface exists on
// the device, but Apple does not publish a header for it. So the two structs
// are declared here, byte for byte as the macOS SDK has them, which is what
// every Go-based tunnel on iOS ends up doing.
//
// AF_SYSTEM itself is in <sys/socket.h> on iOS, so only these are missing.

#ifndef VZHUKH_TUNNEL_BRIDGING_HEADER_H
#define VZHUKH_TUNNEL_BRIDGING_HEADER_H

#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/types.h>

#define MAX_KCTL_NAME 96

struct ctl_info {
    u_int32_t ctl_id;                    /* Kernel Controller ID */
    char ctl_name[MAX_KCTL_NAME];        /* Kernel Controller Name (a C string) */
};

struct sockaddr_ctl {
    u_char sc_len;                       /* depends on size of bundle ID string */
    u_char sc_family;                    /* AF_SYSTEM */
    u_int16_t ss_sysaddr;                /* AF_SYS_KERNCONTROL */
    u_int32_t sc_id;                     /* Controller unique identifier */
    u_int32_t sc_unit;                   /* Developer private unit number */
    u_int32_t sc_reserved[5];
};

// PacketTunnelProvider carries CTLIOCGINFO as a literal, because Swift's
// importer will not evaluate _IOWR. This checks that the literal still matches
// what the macro computes — the value encodes sizeof(struct ctl_info), so
// getting the struct above wrong would otherwise show up as a tunnel that
// silently never finds its device.
_Static_assert(
    _IOWR('N', 3, struct ctl_info) == 0xC0644E03UL,
    "CTLIOCGINFO no longer matches the literal in PacketTunnelProvider.swift"
);

#endif // VZHUKH_TUNNEL_BRIDGING_HEADER_H
