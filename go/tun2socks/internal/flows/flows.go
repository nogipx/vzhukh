// Package flows keeps the connection list the app shows: every connection
// the daemon handled, what it was, where it went and why.
//
// Open connections are kept until they close; closed ones in a ring of
// fixed size, so a busy machine neither grows the list nor copies it on
// every close. The app polls with the sequence number of its last poll and
// gets every open connection plus whatever closed since.
package flows

import (
	"sync"
	"sync/atomic"
	"time"
)

// Flow is one connection as the app sees it.
type Flow struct {
	ID      uint64    `json:"id"`
	Network string    `json:"network"`
	Started time.Time `json:"started"`
	Ended   time.Time `json:"ended,omitzero"`
	Open    bool      `json:"open"`

	PID     int    `json:"pid,omitempty"`
	App     string `json:"app,omitempty"`
	AppPath string `json:"appPath,omitempty"`
	ExePath string `json:"exePath,omitempty"`

	Domain       string `json:"domain,omitempty"`
	DomainSource string `json:"domainSource,omitempty"`

	// Destination is what the app connected to: a placeholder address for a
	// connection made by name.
	Destination string `json:"destination"`

	// Dialed is what the daemon actually opened: the name and port through
	// a route, the resolved address directly.
	Dialed string `json:"dialed,omitempty"`

	Action string `json:"action"`
	Route  string `json:"route,omitempty"`
	RuleID string `json:"ruleId,omitempty"`

	// Matched is what of the rule matched: `app "telegram", port 443`.
	Matched string `json:"matched,omitempty"`

	Upload   int64 `json:"upload"`
	Download int64 `json:"download"`

	Error string `json:"error,omitempty"`

	seq uint64
}

// Snapshot is one poll's worth of the table.
type Snapshot struct {
	// Seq goes back in the next poll as since.
	Seq uint64 `json:"seq"`

	// Active is every open connection.
	Active []Flow `json:"active"`

	// Closed is every connection that closed after since, oldest first.
	Closed []Flow `json:"closed"`

	Totals Totals `json:"totals"`

	// Recording says whether closed connections and statistics are being
	// kept; the open ones are listed either way.
	Recording      bool      `json:"recording"`
	RecordingSince time.Time `json:"recordingSince,omitzero"`
}

// Totals count everything since the table was made or last cleared.
type Totals struct {
	Connections uint64 `json:"connections"`
	Upload      int64  `json:"upload"`
	Download    int64  `json:"download"`
}

// Table is safe for concurrent use.
type Table struct {
	mu     sync.Mutex
	nextID uint64
	seq    uint64
	active map[uint64]*Entry

	// closed is a ring: it grows to capacity, then the oldest is
	// overwritten. head is the oldest, count how many there are. Their seqs
	// run without gaps up to seq, the newest.
	closed   []Flow
	head     int
	count    int
	capacity int

	opened    atomic.Uint64
	upTotal   atomic.Int64
	downTotal atomic.Int64

	stats statsTable

	// Off, only open connections are tracked: nothing about where traffic
	// went is kept once a connection ends. On, closed ones go into the ring
	// and everything into the statistics.
	recording      bool
	recordingSince time.Time

	now func() time.Time
}

// New keeps up to capacity closed connections, recording from the start.
func New(capacity int) *Table {
	if capacity <= 0 {
		capacity = 1000
	}
	t := &Table{
		active:   make(map[uint64]*Entry),
		capacity: capacity,
		now:      time.Now,
	}
	t.stats = newStats(t.now())
	t.recording = true
	t.recordingSince = t.stats.since
	return t
}

// Entry is an open connection's handle. Byte counts go through it without a
// lock; everything else is set with Update.
type Entry struct {
	t    *Table
	mu   sync.Mutex
	flow Flow
	up   atomic.Int64
	down atomic.Int64
	done bool

	// Where the statistics count this connection, and how much of it they
	// have. Set and read with the table's lock held.
	key                    Key
	agg                    *aggregate
	countedUp, countedDown int64
}

// Open records a new connection. ID, Started and Open are filled in.
func (t *Table) Open(f Flow) *Entry {
	t.mu.Lock()
	defer t.mu.Unlock()
	t.nextID++
	f.ID = t.nextID
	f.Started = t.now()
	f.Open = true
	e := &Entry{t: t, flow: f}
	t.active[f.ID] = e
	t.opened.Add(1)
	if t.recording {
		t.statOpen(e, f.Started)
	}
	return e
}

// SetRecording starts or stops keeping history. What was kept stays until
// Clear; starting again adds to it. Connections open at the start count
// from then on.
func (t *Table) SetRecording(on bool) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if on == t.recording {
		return
	}
	now := t.now()
	if !on {
		t.accountLocked(now)
		t.recording = false
		return
	}
	t.recording = true
	t.recordingSince = now
	for _, e := range t.active {
		t.attach(e, now)
	}
}

// Recording reports whether history is being kept, and since when.
func (t *Table) Recording() (bool, time.Time) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.recording, t.recordingSince
}

// attach puts an already open e into the statistics, counting its bytes
// from now. t.mu is held.
func (t *Table) attach(e *Entry, now time.Time) {
	e.countedUp, e.countedDown = e.up.Load(), e.down.Load()
	if e.agg != nil {
		return
	}
	e.key = keyOf(e.flow)
	e.agg = t.stats.at(e.key, now)
	e.agg.open++
}

// statOpen counts e as a new connection of its key. t.mu is held.
func (t *Table) statOpen(e *Entry, now time.Time) {
	e.key = keyOf(e.flow)
	e.agg = t.stats.at(e.key, now)
	e.agg.open++
	if e.flow.AppPath != "" {
		e.agg.appPath = e.flow.AppPath
	}
	if e.flow.Matched != "" {
		e.agg.matched = e.flow.Matched
	}
	t.stats.count(e.key, e.agg, Counts{Conns: 1}, now)
}

// ID of the connection.
func (e *Entry) ID() uint64 { return e.flow.ID }

// Update changes fields of an open connection.
func (e *Entry) Update(change func(*Flow)) {
	e.mu.Lock()
	defer e.mu.Unlock()
	change(&e.flow)
}

// AddUpload counts bytes sent by the app.
func (e *Entry) AddUpload(n int) {
	e.up.Add(int64(n))
	e.t.upTotal.Add(int64(n))
}

// AddDownload counts bytes received by the app.
func (e *Entry) AddDownload(n int) {
	e.down.Add(int64(n))
	e.t.downTotal.Add(int64(n))
}

// Close moves the connection to the closed list. err, if any, is kept as
// the reason. Only the first call counts.
func (e *Entry) Close(err error) {
	e.mu.Lock()
	if e.done {
		e.mu.Unlock()
		return
	}
	e.done = true
	if err != nil && e.flow.Error == "" {
		e.flow.Error = err.Error()
	}
	f := e.snapshotLocked()
	e.mu.Unlock()

	t := e.t
	t.mu.Lock()
	defer t.mu.Unlock()
	delete(t.active, f.ID)
	f.Open = false
	f.Ended = t.now()
	if e.agg != nil {
		e.agg.open--
	}
	if !t.recording {
		return
	}
	e.account(f.Ended)
	if e.agg != nil && f.Error != "" {
		e.agg.addReason(f.Error)
		t.stats.count(e.key, e.agg, Counts{Errors: 1}, f.Ended)
	}
	t.seq++
	f.seq = t.seq
	if t.count < t.capacity {
		t.closed = append(t.closed, f)
		t.count++
		return
	}
	t.closed[t.head] = f
	t.head = (t.head + 1) % t.capacity
}

// Clear forgets the closed connections and starts the totals again. Open
// ones stay: they are still running. seq keeps counting, so a poll with an
// older since gets only what closes from now on.
func (t *Table) Clear() {
	t.mu.Lock()
	t.closed = nil
	t.head = 0
	t.count = 0
	t.opened.Store(uint64(len(t.active)))
	t.upTotal.Store(0)
	t.downTotal.Store(0)
	// The statistics start again too. Open connections count from here:
	// what they moved before the clear is not counted again.
	now := t.now()
	t.stats.reset(now)
	if t.recording {
		t.recordingSince = now
	}
	for _, e := range t.active {
		e.agg = nil
		if t.recording {
			t.attach(e, now)
		}
	}
	t.mu.Unlock()
}

func (e *Entry) snapshotLocked() Flow {
	f := e.flow
	f.Upload = e.up.Load()
	f.Download = e.down.Load()
	return f
}

// Snapshot returns the open connections and those closed after since.
func (t *Table) Snapshot(since uint64) Snapshot {
	t.mu.Lock()
	active := make([]*Entry, 0, len(t.active))
	for _, e := range t.active {
		active = append(active, e)
	}
	// Seqs are contiguous, so what is newer than since is the last n of
	// the ring and nothing older needs looking at.
	n := 0
	if since < t.seq {
		n = int(min(t.seq-since, uint64(t.count)))
	}
	closed := make([]Flow, 0, n)
	for i := t.count - n; i < t.count; i++ {
		closed = append(closed, t.closed[(t.head+i)%len(t.closed)])
	}
	seq := t.seq
	recording, recordingSince := t.recording, t.recordingSince
	t.mu.Unlock()

	s := Snapshot{
		Recording: recording,
		Seq:       seq,
		Active:    make([]Flow, 0, len(active)),
		Closed:    closed,
		Totals: Totals{
			Connections: t.opened.Load(),
			Upload:      t.upTotal.Load(),
			Download:    t.downTotal.Load(),
		},
	}
	if recording {
		s.RecordingSince = recordingSince
	}
	for _, e := range active {
		e.mu.Lock()
		s.Active = append(s.Active, e.snapshotLocked())
		e.mu.Unlock()
	}
	return s
}
