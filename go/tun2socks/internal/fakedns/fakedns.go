// Package fakedns answers DNS queries with placeholder addresses.
//
// Every name an app looks up gets an address from a reserved pool
// (198.18.0.0/16 by default, half of the range set aside for benchmarking and
// routed nowhere; the tunnel's own addresses sit in the other half).
// When the app then connects to that address, the daemon knows which name it
// meant, and can decide by domain and let the far end of the chain resolve
// the name itself. The real address is never looked up locally for a name
// that goes through a route, so the lookup does not leak either.
package fakedns

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"strings"
	"sync"

	"golang.org/x/net/dns/dnsmessage"
)

// DefaultPrefix is the first half of the benchmarking range (RFC 2544).
var DefaultPrefix = netip.MustParsePrefix("198.18.0.0/16")

// Pool hands out addresses from a prefix, one per name, and remembers which
// is which. When it runs out it reuses the oldest address; at /16 that takes
// some 65,000 distinct names.
type Pool struct {
	mu     sync.Mutex
	base   uint32
	size   uint32
	next   uint32
	byIP   map[netip.Addr]string
	byName map[string]netip.Addr
}

// NewPool takes an IPv4 prefix no smaller than /24.
func NewPool(prefix netip.Prefix) (*Pool, error) {
	if !prefix.Addr().Is4() || prefix.Bits() > 24 {
		return nil, fmt.Errorf("fakedns: pool %s must be IPv4 and at least /24", prefix)
	}
	prefix = prefix.Masked()
	a := prefix.Addr().As4()
	base := uint32(a[0])<<24 | uint32(a[1])<<16 | uint32(a[2])<<8 | uint32(a[3])
	total := uint32(1) << (32 - prefix.Bits())
	return &Pool{
		// Skip the network address and .1, which the tunnel interface may
		// use, and leave the last address alone as well.
		base:   base + 2,
		size:   total - 3,
		byIP:   make(map[netip.Addr]string),
		byName: make(map[string]netip.Addr),
	}, nil
}

// Contains reports whether ip is one this pool hands out.
func (p *Pool) Contains(ip netip.Addr) bool {
	if !ip.Is4() && !ip.Is4In6() {
		return false
	}
	a := ip.Unmap().As4()
	n := uint32(a[0])<<24 | uint32(a[1])<<16 | uint32(a[2])<<8 | uint32(a[3])
	return n >= p.base && n < p.base+p.size
}

// Assign returns the address for name, giving it one if it has none.
func (p *Pool) Assign(name string) netip.Addr {
	name = normalize(name)
	p.mu.Lock()
	defer p.mu.Unlock()

	if ip, ok := p.byName[name]; ok {
		return ip
	}
	n := p.base + p.next
	p.next = (p.next + 1) % p.size
	ip := netip.AddrFrom4([4]byte{byte(n >> 24), byte(n >> 16), byte(n >> 8), byte(n)})

	if old, taken := p.byIP[ip]; taken {
		delete(p.byName, old)
	}
	p.byIP[ip] = name
	p.byName[name] = ip
	return ip
}

// Lookup returns the name an address was given to.
func (p *Pool) Lookup(ip netip.Addr) (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	name, ok := p.byIP[ip.Unmap()]
	return name, ok
}

func normalize(name string) string {
	return strings.TrimSuffix(strings.ToLower(name), ".")
}

// Forwarder sends a query to a real resolver and returns its answer. name is
// the question, already parsed, for callers that pick a resolver by it.
type Forwarder func(ctx context.Context, query []byte, name string) ([]byte, error)

// DefaultExclude are names that must resolve for real: local networks,
// reverse lookups and the like. A placeholder address for a printer on the
// LAN would send its traffic into the tunnel.
var DefaultExclude = []string{
	"local", "lan", "home", "home.arpa", "localdomain", "localhost",
	"in-addr.arpa", "ip6.arpa", "internal", "corp",
}

// Server answers queries. A and AAAA for ordinary names are answered from
// the pool; everything else goes to Forward.
type Server struct {
	Pool    *Pool
	Exclude []string
	Forward Forwarder

	// RealAnswer, when set, picks more names to forward for a real answer
	// besides Exclude: those a rule leaves to the system.
	RealAnswer func(name string) bool

	// TTL of placeholder answers. Short, so that apps ask again rather than
	// cling to an address after the daemon stops. Zero means 1s.
	TTL uint32
}

// typeSVCB and typeHTTPS (RFC 9460) carry address hints. A browser that
// finds real addresses there connects to them and skips the placeholder.
const (
	typeSVCB  dnsmessage.Type = 64
	typeHTTPS dnsmessage.Type = 65
)

// Answer returns the reply to one query.
func (s *Server) Answer(ctx context.Context, query []byte) ([]byte, error) {
	var parser dnsmessage.Parser
	header, err := parser.Start(query)
	if err != nil {
		return nil, fmt.Errorf("fakedns: bad query: %w", err)
	}
	question, err := parser.Question()
	if err != nil {
		return nil, fmt.Errorf("fakedns: bad question: %w", err)
	}
	name := normalize(question.Name.String())

	if question.Class != dnsmessage.ClassINET || s.Excluded(name) ||
		(s.RealAnswer != nil && s.RealAnswer(name)) {
		return s.forward(ctx, query, name)
	}

	switch question.Type {
	case dnsmessage.TypeA:
		return s.reply(header, question, s.Pool.Assign(name))
	case dnsmessage.TypeAAAA, typeHTTPS, typeSVCB:
		// No data: the name exists, it just has nothing of this type.
		// Apps fall back to A, and the placeholder.
		return s.reply(header, question, netip.Addr{})
	default:
		return s.forward(ctx, query, name)
	}
}

func (s *Server) forward(ctx context.Context, query []byte, name string) ([]byte, error) {
	if s.Forward == nil {
		return nil, errors.New("fakedns: no forwarder for " + name)
	}
	return s.Forward(ctx, query, name)
}

// Excluded is true for names that must resolve for real. A single label is
// in that class too: it is a local host name, and the system resolver would
// have added a search domain before asking if it had one.
func (s *Server) Excluded(name string) bool {
	name = normalize(name)
	if !strings.Contains(name, ".") {
		return true
	}
	exclude := s.Exclude
	if exclude == nil {
		exclude = DefaultExclude
	}
	for _, suffix := range exclude {
		if name == suffix || strings.HasSuffix(name, "."+suffix) {
			return true
		}
	}
	return false
}

func (s *Server) reply(
	query dnsmessage.Header,
	question dnsmessage.Question,
	ip netip.Addr,
) ([]byte, error) {
	ttl := s.TTL
	if ttl == 0 {
		ttl = 1
	}
	builder := dnsmessage.NewBuilder(nil, dnsmessage.Header{
		ID:                 query.ID,
		Response:           true,
		OpCode:             query.OpCode,
		RecursionDesired:   query.RecursionDesired,
		RecursionAvailable: true,
		RCode:              dnsmessage.RCodeSuccess,
	})
	builder.EnableCompression()
	if err := builder.StartQuestions(); err != nil {
		return nil, err
	}
	if err := builder.Question(question); err != nil {
		return nil, err
	}
	if err := builder.StartAnswers(); err != nil {
		return nil, err
	}
	if ip.IsValid() {
		err := builder.AResource(
			dnsmessage.ResourceHeader{Name: question.Name, Class: dnsmessage.ClassINET, TTL: ttl},
			dnsmessage.AResource{A: ip.As4()},
		)
		if err != nil {
			return nil, err
		}
	}
	return builder.Finish()
}
