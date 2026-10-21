// The Android tunnel, built as libtun2socks.so and called over JNI from
// dev.nogipx.vzhukh.GoTunnel inside the VpnService.
//
// The whole tunnel lives here, in the service's process: the TUN descriptor
// VpnService.Builder hands over, the packet engine and the SSH route
// (internal/mobile). Nothing depends on the app's window being open, and
// there is no proxy on loopback for other apps to find.
//
//	GOOS=android GOARCH=arm64 CGO_ENABLED=1 go build -buildmode=c-shared -tags with_gvisor -o libtun2socks.so .
package main

/*
#include <stdlib.h>
#include <jni.h>
#include <android/log.h>

static void logError(const char* msg) {
    __android_log_print(ANDROID_LOG_ERROR, "vzhukh", "%s", msg);
}
static void logDebug(const char* msg) {
    __android_log_print(ANDROID_LOG_DEBUG, "vzhukh", "%s", msg);
}
static const char* jstrGet(JNIEnv* env, jstring s) {
    return (*env)->GetStringUTFChars(env, s, NULL);
}
static void jstrRelease(JNIEnv* env, jstring s, const char* c) {
    (*env)->ReleaseStringUTFChars(env, s, c);
}
static jstring jstrNew(JNIEnv* env, const char* c) {
    return (*env)->NewStringUTF(env, c);
}
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"sync"
	"unsafe"

	"github.com/nogipx/vzhukh/tun2socks/internal/mobile"
)

type androidLog struct{}

func (androidLog) Debugf(format string, args ...any) {
	cs := C.CString(fmt.Sprintf(format, args...))
	C.logDebug(cs)
	C.free(unsafe.Pointer(cs))
}

func (androidLog) Errorf(format string, args ...any) {
	cs := C.CString(fmt.Sprintf(format, args...))
	C.logError(cs)
	C.free(unsafe.Pointer(cs))
}

var (
	mu      sync.Mutex
	current *mobile.Tunnel
)

func goString(env *C.JNIEnv, s C.jstring) string {
	c := C.jstrGet(env, s)
	defer C.jstrRelease(env, s, c)
	return C.GoString(c)
}

func javaString(env *C.JNIEnv, s string) C.jstring {
	cs := C.CString(s)
	defer C.free(unsafe.Pointer(cs))
	return C.jstrNew(env, cs)
}

// start brings the tunnel up on fd with config JSON (mobile.Config). It
// returns null on success and the error text otherwise. A tunnel already
// running is replaced.
//
//export Java_dev_nogipx_vzhukh_GoTunnel_start
func Java_dev_nogipx_vzhukh_GoTunnel_start(env *C.JNIEnv, cls C.jclass, fd C.jint, config C.jstring) C.jstring {
	cfg, err := mobile.ParseConfig([]byte(goString(env, config)))
	if err != nil {
		return javaString(env, err.Error())
	}
	mu.Lock()
	defer mu.Unlock()
	if current != nil {
		current.Close()
		current = nil
	}
	t, err := mobile.Start(int(fd), cfg, androidLog{})
	if err != nil {
		androidLog{}.Errorf("tunnel: start: %v", err)
		return javaString(env, err.Error())
	}
	current = t
	androidLog{}.Debugf("tunnel: started on fd %d", int(fd))
	return C.jstring(0) // null: no error
}

//export Java_dev_nogipx_vzhukh_GoTunnel_stop
func Java_dev_nogipx_vzhukh_GoTunnel_stop(env *C.JNIEnv, cls C.jclass) {
	mu.Lock()
	defer mu.Unlock()
	if current != nil {
		current.Close()
		current = nil
	}
}

// status returns the route's state as JSON, {"state":"stopped"} when no
// tunnel runs.
//
//export Java_dev_nogipx_vzhukh_GoTunnel_status
func Java_dev_nogipx_vzhukh_GoTunnel_status(env *C.JNIEnv, cls C.jclass) C.jstring {
	mu.Lock()
	t := current
	mu.Unlock()
	if t == nil {
		return javaString(env, `{"state":"stopped"}`)
	}
	raw, _ := json.Marshal(t.Status())
	return javaString(env, string(raw))
}

// nudge says the network changed: the route is probed or redialed now.
//
//export Java_dev_nogipx_vzhukh_GoTunnel_nudge
func Java_dev_nogipx_vzhukh_GoTunnel_nudge(env *C.JNIEnv, cls C.jclass, reason C.jstring) {
	mu.Lock()
	t := current
	mu.Unlock()
	if t != nil {
		t.Nudge(goString(env, reason))
	}
}

func main() {}
