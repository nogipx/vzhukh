package flows

import (
	"encoding/json"
	"strings"
	"testing"
)

// The app parses this JSON (lib/daemon/daemon_models.dart). An open flow
// must not carry an "ended" field, or the app would read the zero time.
func TestOpenFlowJSONHasNoEnded(t *testing.T) {
	table := New(1)
	e := table.Open(Flow{Network: "tcp", Destination: "1.2.3.4:443"})
	raw, err := json.Marshal(table.Snapshot(0))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(raw), `"ended"`) {
		t.Fatalf("open flow has ended: %s", raw)
	}
	e.Close(nil)
	raw, _ = json.Marshal(table.Snapshot(0))
	if !strings.Contains(string(raw), `"ended"`) {
		t.Fatalf("closed flow lacks ended: %s", raw)
	}
	t.Log(string(raw))
}
