#include "bridge.h"

#include <dispatch/dispatch.h>
#include <os/log.h>
#include <stddef.h>

// A named subsystem is what makes the tunnel's output findable at all: a
// NetworkExtension has no console of its own, so everything is read after the
// fact with `log stream --predicate 'subsystem == "dev.nogipx.vzhukh"'`.
static os_log_t vzhukh_log(void) {
    static os_log_t handle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        handle = os_log_create("dev.nogipx.vzhukh", "tunnel");
    });
    return handle;
}

// Info rather than debug: debug-level messages are dropped unless logging has
// been turned up for the subsystem first, which is not much use when the
// interesting run already happened.
void vzhukh_log_info(const char *message) {
    os_log_info(vzhukh_log(), "%{public}s", message);
}

void vzhukh_log_error(const char *message) {
    os_log_error(vzhukh_log(), "%{public}s", message);
}

void vzhukh_invoke_drop(vzhukh_drop_handler handler, const char *reason) {
    if (handler != NULL) {
        handler(reason);
    }
}
