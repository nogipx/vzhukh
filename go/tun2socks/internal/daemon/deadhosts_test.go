package daemon

import (
	"net/netip"
	"testing"
	"time"
)

func TestDeadHostsAreRememberedForAWhile(t *testing.T) {
	h := deadHosts{ttl: 10 * time.Minute}
	adb := netip.MustParseAddr("192.168.7.50")
	other := netip.MustParseAddr("1.1.1.1")
	now := time.Now()

	if h.has(adb, now) {
		t.Fatal("known before it failed")
	}
	h.add(adb, now)
	if !h.has(adb, now.Add(9*time.Minute)) {
		t.Fatal("forgotten too soon")
	}
	if h.has(other, now) {
		t.Fatal("one dead host made another one dead")
	}
	if h.has(adb, now.Add(10*time.Minute)) {
		t.Fatal("remembered past its time")
	}

	h.add(adb, now)
	h.forget(adb)
	if h.has(adb, now) {
		t.Fatal("an address that answered is still dead")
	}

	h.add(other, now.Add(time.Hour))
	if _, kept := h.m[adb]; kept {
		t.Fatal("expired entries are not dropped")
	}
}
