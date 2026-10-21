package daemon

import (
	"testing"

	tun "github.com/sagernet/sing-tun"
)

// Without the with_gvisor tag sing-tun compiles fine and then refuses to
// start a stack, which surfaces only when someone presses Connect.
func TestBuiltWithGVisor(t *testing.T) {
	if !tun.WithGVisor {
		t.Fatal("build and test with -tags with_gvisor (just go-test, just daemon)")
	}
}
