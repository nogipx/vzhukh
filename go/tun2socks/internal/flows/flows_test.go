package flows

import (
	"errors"
	"sync"
	"testing"
)

func TestOpenUpdateCountClose(t *testing.T) {
	table := New(10)
	e := table.Open(Flow{Network: "tcp", Destination: "198.18.0.2:443"})
	e.Update(func(f *Flow) { f.Domain = "example.com"; f.Action = "route" })
	e.AddUpload(100)
	e.AddDownload(2000)

	s := table.Snapshot(0)
	if len(s.Active) != 1 || len(s.Closed) != 0 {
		t.Fatalf("active %d closed %d", len(s.Active), len(s.Closed))
	}
	got := s.Active[0]
	if !got.Open || got.Domain != "example.com" || got.Upload != 100 || got.Download != 2000 || got.ID == 0 {
		t.Fatalf("active flow %+v", got)
	}

	e.Close(errors.New("reset"))
	e.Close(errors.New("second close ignored"))

	s2 := table.Snapshot(s.Seq)
	if len(s2.Active) != 0 || len(s2.Closed) != 1 {
		t.Fatalf("active %d closed %d", len(s2.Active), len(s2.Closed))
	}
	c := s2.Closed[0]
	if c.Open || c.Error != "reset" || c.Ended.IsZero() || c.Download != 2000 {
		t.Fatalf("closed flow %+v", c)
	}
	if s2.Totals.Connections != 1 || s2.Totals.Upload != 100 || s2.Totals.Download != 2000 {
		t.Fatalf("totals %+v", s2.Totals)
	}

	// Polling again with the new seq gives nothing new.
	if s3 := table.Snapshot(s2.Seq); len(s3.Closed) != 0 {
		t.Fatalf("closed again: %+v", s3.Closed)
	}
}

func TestClosedRingKeepsTheNewest(t *testing.T) {
	table := New(3)
	for i := 0; i < 5; i++ {
		table.Open(Flow{Network: "tcp"}).Close(nil)
	}
	s := table.Snapshot(0)
	if len(s.Closed) != 3 {
		t.Fatalf("%d closed kept", len(s.Closed))
	}
	if s.Closed[0].ID != 3 || s.Closed[2].ID != 5 {
		t.Fatalf("kept ids %d..%d", s.Closed[0].ID, s.Closed[2].ID)
	}
}

func TestRingGivesOnlyWhatClosedSinceAfterWrapping(t *testing.T) {
	table := New(3)
	for i := 0; i < 7; i++ {
		table.Open(Flow{Network: "tcp"}).Close(nil)
	}
	s := table.Snapshot(5)
	if len(s.Closed) != 2 || s.Closed[0].ID != 6 || s.Closed[1].ID != 7 {
		t.Fatalf("since 5: %+v", s.Closed)
	}
	if got := table.Snapshot(s.Seq).Closed; len(got) != 0 {
		t.Fatalf("nothing new, got %d", len(got))
	}
	// Further back than the ring holds: only what is still kept.
	if got := table.Snapshot(1).Closed; len(got) != 3 || got[0].ID != 5 {
		t.Fatalf("since 1: %+v", got)
	}
}

func TestClearForgetsClosedAndTotalsButNotOpen(t *testing.T) {
	table := New(10)
	open := table.Open(Flow{Network: "tcp"})
	for i := 0; i < 3; i++ {
		e := table.Open(Flow{Network: "tcp"})
		e.AddUpload(100)
		e.Close(nil)
	}
	before := table.Snapshot(0)
	table.Clear()

	s := table.Snapshot(0)
	if len(s.Closed) != 0 || len(s.Active) != 1 {
		t.Fatalf("after clear: %d closed, %d open", len(s.Closed), len(s.Active))
	}
	if s.Totals != (Totals{Connections: 1}) {
		t.Fatalf("totals %+v", s.Totals)
	}
	open.Close(nil)
	if got := table.Snapshot(before.Seq).Closed; len(got) != 1 || got[0].ID != open.ID() {
		t.Fatalf("after clear, since the old seq: %+v", got)
	}
}

func TestConcurrentUse(t *testing.T) {
	table := New(100)
	var wg sync.WaitGroup
	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			e := table.Open(Flow{Network: "tcp"})
			for j := 0; j < 100; j++ {
				e.AddUpload(1)
				e.AddDownload(2)
			}
			table.Snapshot(0)
			e.Close(nil)
		}()
	}
	wg.Wait()
	s := table.Snapshot(0)
	if s.Totals.Upload != 5000 || s.Totals.Download != 10000 || len(s.Active) != 0 {
		t.Fatalf("totals %+v active %d", s.Totals, len(s.Active))
	}
}
