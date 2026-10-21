package flows

import (
	"net"
	"path"
	"sort"
	"strconv"
	"time"
)

// The statistics the analysis views read. Connections are summed by Key,
// so they outlive the ring of closed connections: a key costs a few hundred
// bytes however many connections it counts, where the ring keeps only the
// last couple of thousand. Keys not seen for longest go first when there
// are too many.

const (
	// bucketSpan is the resolution of a key's history.
	bucketSpan = 5 * time.Minute
	// bucketCount buckets of bucketSpan cover the longest window.
	bucketCount = 12
	// timelineCount one-minute points make the chart.
	timelineCount = 60
	// defaultMaxKeys bounds the memory the statistics take.
	defaultMaxKeys = 5000
	// maxReasons distinct errors are kept per key.
	maxReasons = 4
)

// Key is what connections are summed by.
type Key struct {
	App     string `json:"app,omitempty"`
	Host    string `json:"host"`
	Port    int    `json:"port"`
	Network string `json:"network"`
	Action  string `json:"action"`
	Route   string `json:"route,omitempty"`
	RuleID  string `json:"ruleId,omitempty"`
}

func keyOf(f Flow) Key {
	app := f.App
	if app == "" && f.ExePath != "" {
		app = path.Base(f.ExePath)
	}
	host, portText, err := net.SplitHostPort(f.Destination)
	if err != nil {
		host = f.Destination
	}
	if f.Domain != "" {
		host = f.Domain
	}
	port, _ := strconv.Atoi(portText)
	return Key{App: app, Host: host, Port: port, Network: f.Network, Action: f.Action, Route: f.Route, RuleID: f.RuleID}
}

// Counts are what a key or a moment adds up to.
type Counts struct {
	Conns    int64 `json:"conns"`
	Errors   int64 `json:"errors"`
	Upload   int64 `json:"upload"`
	Download int64 `json:"download"`
}

func (c *Counts) add(o Counts) {
	c.Conns += o.Conns
	c.Errors += o.Errors
	c.Upload += o.Upload
	c.Download += o.Download
}

type bucket struct {
	slot int64 // which span it is, counted from the epoch
	Counts
}

// Reason is one kind of error and how often it happened.
type Reason struct {
	Error string `json:"error"`
	Count int64  `json:"count"`
}

type aggregate struct {
	appPath string
	matched string
	first   time.Time
	last    time.Time
	open    int
	total   Counts
	buckets [bucketCount]bucket
	reasons []Reason
}

// Row is one key's statistics over a window.
type Row struct {
	Key
	AppPath string    `json:"appPath,omitempty"`
	Matched string    `json:"matched,omitempty"`
	First   time.Time `json:"first"`
	Last    time.Time `json:"last"`
	Open    int       `json:"open"`
	Counts
	Reasons []Reason `json:"reasons,omitempty"`
}

// Point is one minute of everything.
type Point struct {
	At time.Time `json:"at"`
	Counts
}

// Stats is what the analysis views poll.
type Stats struct {
	// Window is the minutes summed; 0 is everything since the last clear.
	Window int `json:"window"`
	// Since is when the statistics started: the daemon's start or the last
	// clear.
	Since    time.Time `json:"since"`
	Rows     []Row     `json:"rows"`
	Timeline []Point   `json:"timeline"`
	// Evicted counts keys dropped to stay within bounds.
	Evicted int64 `json:"evicted"`

	Recording bool `json:"recording"`
}

type statsTable struct {
	keys     map[Key]*aggregate
	maxKeys  int
	timeline [timelineCount]bucket
	since    time.Time
	evicted  int64
}

func newStats(now time.Time) statsTable {
	return statsTable{keys: map[Key]*aggregate{}, maxKeys: defaultMaxKeys, since: now}
}

func (s *statsTable) reset(now time.Time) {
	*s = statsTable{keys: map[Key]*aggregate{}, maxKeys: s.maxKeys, since: now}
}

// at finds or makes the aggregate for k.
func (s *statsTable) at(k Key, now time.Time) *aggregate {
	a := s.keys[k]
	if a != nil {
		return a
	}
	if len(s.keys) >= s.maxKeys {
		s.evictOldest()
	}
	a = &aggregate{first: now, last: now}
	s.keys[k] = a
	return a
}

// evictOldest drops the key seen longest ago that has nothing open.
func (s *statsTable) evictOldest() {
	var oldest Key
	var at time.Time
	found := false
	for k, a := range s.keys {
		if a.open > 0 {
			continue
		}
		if !found || a.last.Before(at) {
			oldest, at, found = k, a.last, true
		}
	}
	if found {
		delete(s.keys, oldest)
		s.evicted++
	}
}

// count adds c to k at now, in the key's history and in the timeline.
func (s *statsTable) count(k Key, a *aggregate, c Counts, now time.Time) {
	a.last = now
	a.total.add(c)

	slot := now.UnixNano() / int64(bucketSpan)
	b := &a.buckets[slot%bucketCount]
	if b.slot != slot {
		*b = bucket{slot: slot}
	}
	b.add(c)

	minute := now.Unix() / 60
	p := &s.timeline[minute%timelineCount]
	if p.slot != minute {
		*p = bucket{slot: minute}
	}
	p.add(c)
}

func (a *aggregate) addReason(err string) {
	for i := range a.reasons {
		if a.reasons[i].Error == err {
			a.reasons[i].Count++
			return
		}
	}
	if len(a.reasons) < maxReasons {
		a.reasons = append(a.reasons, Reason{Error: err, Count: 1})
		return
	}
	// The rarest makes room: what keeps happening matters more than what
	// happened once.
	sort.Slice(a.reasons, func(i, j int) bool { return a.reasons[i].Count > a.reasons[j].Count })
	a.reasons[len(a.reasons)-1] = Reason{Error: err, Count: 1}
}

// window sums a's buckets over the last minutes, or everything for 0.
func (a *aggregate) window(minutes int, now time.Time) Counts {
	if minutes <= 0 {
		return a.total
	}
	spans := int64((time.Duration(minutes)*time.Minute + bucketSpan - 1) / bucketSpan)
	newest := now.UnixNano() / int64(bucketSpan)
	var c Counts
	for _, b := range a.buckets {
		if b.slot > newest-spans && b.slot <= newest {
			c.add(b.Counts)
		}
	}
	return c
}

// Stats sums every key over the last minutes (rounded up to five), or
// since the last clear for 0. Keys with nothing in the window and nothing
// open are left out.
func (t *Table) Stats(minutes int) Stats {
	t.mu.Lock()
	defer t.mu.Unlock()
	now := t.now()
	t.accountLocked(now)

	out := Stats{Window: minutes, Since: t.stats.since, Evicted: t.stats.evicted, Rows: []Row{}, Recording: t.recording}
	for k, a := range t.stats.keys {
		c := a.window(minutes, now)
		if c == (Counts{}) && a.open == 0 {
			continue
		}
		out.Rows = append(out.Rows, Row{
			Key:     k,
			AppPath: a.appPath,
			Matched: a.matched,
			First:   a.first,
			Last:    a.last,
			Open:    a.open,
			Counts:  c,
			Reasons: append([]Reason(nil), a.reasons...),
		})
	}

	minute := now.Unix() / 60
	out.Timeline = make([]Point, 0, timelineCount)
	for m := minute - timelineCount + 1; m <= minute; m++ {
		p := Point{At: time.Unix(m*60, 0)}
		if b := t.stats.timeline[m%timelineCount]; b.slot == m {
			p.Counts = b.Counts
		}
		out.Timeline = append(out.Timeline, p)
	}
	return out
}

// accountLocked moves what open connections sent and received since the
// last call into the statistics, so a long download shows in the minutes
// it ran rather than all at once when it ends. t.mu is held.
func (t *Table) accountLocked(now time.Time) {
	if !t.recording {
		return
	}
	for _, e := range t.active {
		e.account(now)
	}
}

// account counts e's bytes not counted yet. t.mu is held.
func (e *Entry) account(now time.Time) {
	up, down := e.up.Load(), e.down.Load()
	d := Counts{Upload: up - e.countedUp, Download: down - e.countedDown}
	if d == (Counts{}) || e.agg == nil {
		return
	}
	e.countedUp, e.countedDown = up, down
	e.t.stats.count(e.key, e.agg, d, now)
}

// Account counts open connections' bytes every interval until the
// returned function is called, so the statistics stay true to time when
// nobody polls them.
func (t *Table) Account(every time.Duration) (stop func()) {
	done := make(chan struct{})
	go func() {
		tick := time.NewTicker(every)
		defer tick.Stop()
		for {
			select {
			case <-done:
				return
			case <-tick.C:
				t.mu.Lock()
				t.accountLocked(t.now())
				t.mu.Unlock()
			}
		}
	}()
	return func() { close(done) }
}
