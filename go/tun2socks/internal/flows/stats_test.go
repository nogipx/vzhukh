package flows

import (
	"errors"
	"testing"
	"time"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time       { return c.t }
func (c *clock) wait(d time.Duration) { c.t = c.t.Add(d) }
func tableAt(c *clock, capacity int) *Table {
	t := New(capacity)
	t.now = c.now
	t.stats = newStats(c.now())
	return t
}

var origin = time.Date(2026, 10, 20, 12, 0, 0, 0, time.UTC)

func flow(app, domain string) Flow {
	return Flow{Network: "tcp", App: app, Domain: domain, Destination: "198.18.0.5:443", Action: "route", Route: "main"}
}

func rowOf(t *testing.T, s Stats, app, host string) Row {
	t.Helper()
	for _, r := range s.Rows {
		if r.App == app && r.Host == host {
			return r
		}
	}
	t.Fatalf("no row for %s %s in %+v", app, host, s.Rows)
	return Row{}
}

func TestStatsSumByKeyAndOutliveTheRing(t *testing.T) {
	c := &clock{origin}
	table := tableAt(c, 2)
	for i := 0; i < 5; i++ {
		e := table.Open(flow("Safari", "example.com"))
		e.AddUpload(10)
		e.AddDownload(100)
		e.Close(nil)
	}
	table.Open(flow("curl", "api.example.com")).Close(errors.New("refused"))

	s := table.Stats(0)
	safari := rowOf(t, s, "Safari", "example.com")
	if safari.Conns != 5 || safari.Upload != 50 || safari.Download != 500 || safari.Port != 443 {
		t.Fatalf("safari %+v", safari)
	}
	curl := rowOf(t, s, "curl", "api.example.com")
	if curl.Errors != 1 || len(curl.Reasons) != 1 || curl.Reasons[0].Error != "refused" {
		t.Fatalf("curl %+v", curl)
	}
	if got := len(table.Snapshot(0).Closed); got != 2 {
		t.Fatalf("ring kept %d", got)
	}
}

func TestLongConnectionCountsInTheMinutesItRan(t *testing.T) {
	c := &clock{origin}
	table := tableAt(c, 10)
	e := table.Open(flow("Music", "stream.example.com"))
	e.AddDownload(1000)
	table.Stats(0) // the poll accounts what moved so far

	c.wait(30 * time.Minute)
	e.AddDownload(50)
	e.Close(nil)

	if got := rowOf(t, table.Stats(5), "Music", "stream.example.com"); got.Download != 50 || got.Conns != 0 {
		t.Fatalf("last 5 minutes %+v", got)
	}
	if got := rowOf(t, table.Stats(60), "Music", "stream.example.com"); got.Download != 1050 || got.Conns != 1 {
		t.Fatalf("last hour %+v", got)
	}
	tl := table.Stats(0).Timeline
	if len(tl) != timelineCount || tl[len(tl)-1].Download != 50 || tl[len(tl)-31].Download != 1000 {
		t.Fatalf("timeline ends %+v, 30 min ago %+v", tl[len(tl)-1], tl[len(tl)-31])
	}
}

func TestQuietKeysLeaveTheWindowButOpenOnesStay(t *testing.T) {
	c := &clock{origin}
	table := tableAt(c, 10)
	table.Open(flow("Mail", "imap.example.com")).Close(nil)
	open := table.Open(flow("Slack", "slack.com"))

	c.wait(20 * time.Minute)
	s := table.Stats(5)
	if len(s.Rows) != 1 || s.Rows[0].App != "Slack" || s.Rows[0].Open != 1 {
		t.Fatalf("rows %+v", s.Rows)
	}
	open.Close(nil)
}

func TestTheKeySeenLongestAgoGoesFirst(t *testing.T) {
	c := &clock{origin}
	table := tableAt(c, 10)
	table.stats.maxKeys = 2
	held := table.Open(flow("A", "a.com")) // open: never evicted
	c.wait(time.Minute)
	table.Open(flow("B", "b.com")).Close(nil)
	c.wait(time.Minute)
	table.Open(flow("C", "c.com")).Close(nil)

	s := table.Stats(0)
	if len(s.Rows) != 2 || s.Evicted != 1 {
		t.Fatalf("rows %+v evicted %d", s.Rows, s.Evicted)
	}
	rowOf(t, s, "A", "a.com")
	rowOf(t, s, "C", "c.com")
	held.Close(nil)
}

func TestClearStartsTheStatisticsAgain(t *testing.T) {
	c := &clock{origin}
	table := tableAt(c, 10)
	open := table.Open(flow("Safari", "example.com"))
	open.AddDownload(500)
	table.Open(flow("curl", "x.com")).Close(nil)

	table.Clear()
	open.AddDownload(7)
	open.Close(nil)

	s := table.Stats(0)
	if len(s.Rows) != 1 {
		t.Fatalf("rows %+v", s.Rows)
	}
	if r := s.Rows[0]; r.App != "Safari" || r.Download != 7 || r.Open != 0 {
		t.Fatalf("after clear %+v", r)
	}
}

func TestNothingIsKeptUntilRecording(t *testing.T) {
	c := &clock{origin}
	table := tableAt(c, 10)
	table.SetRecording(false)
	table.Open(flow("Safari", "example.com")).Close(errors.New("refused"))
	open := table.Open(flow("Music", "stream.example.com"))
	open.AddDownload(500)

	s := table.Snapshot(0)
	if len(s.Closed) != 0 || len(s.Active) != 1 || s.Recording {
		t.Fatalf("not recording: %d closed, %d open, recording %v", len(s.Closed), len(s.Active), s.Recording)
	}
	if rows := table.Stats(0).Rows; len(rows) != 0 {
		t.Fatalf("stats while not recording: %+v", rows)
	}

	c.wait(time.Minute)
	table.SetRecording(true)
	open.AddDownload(7)
	open.Close(nil)
	r := rowOf(t, table.Stats(0), "Music", "stream.example.com")
	if r.Download != 7 || r.Conns != 0 || r.Open != 0 {
		t.Fatalf("an open connection counts from the start of recording: %+v", r)
	}
	if s := table.Snapshot(0); len(s.Closed) != 1 || !s.Recording || !s.RecordingSince.Equal(c.now()) {
		t.Fatalf("recording: %+v", s)
	}

	table.SetRecording(false)
	table.Open(flow("curl", "x.com")).Close(nil)
	if s := table.Snapshot(0); len(s.Closed) != 1 {
		t.Fatalf("stopped, kept %d", len(s.Closed))
	}
	if rows := table.Stats(0).Rows; len(rows) != 1 {
		t.Fatalf("what was recorded stays after stopping: %+v", rows)
	}
}
