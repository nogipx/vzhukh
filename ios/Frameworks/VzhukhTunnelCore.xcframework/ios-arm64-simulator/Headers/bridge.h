// C helpers for the iOS bridge.
//
// These live apart from main.go because cgo forbids a file containing //export
// from defining anything in its preamble — only declarations are allowed
// there, since the preamble is copied into more than one generated file.

#ifndef VZHUKH_BRIDGE_H
#define VZHUKH_BRIDGE_H

// vzhukh_drop_handler is called when the tunnel goes down on its own, as
// opposed to being stopped. The reason string is owned by the caller and is
// not valid after the handler returns.
typedef void (*vzhukh_drop_handler)(const char *reason);

void vzhukh_log_info(const char *message);
void vzhukh_log_error(const char *message);

// vzhukh_invoke_drop exists because Go cannot call a C function pointer
// directly; it needs a real C function to do it through.
void vzhukh_invoke_drop(vzhukh_drop_handler handler, const char *reason);

#endif // VZHUKH_BRIDGE_H
