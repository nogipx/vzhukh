// Package sshtest runs a real SSH server in-process for tests.
//
// It serves direct-tcpip and nothing else, accepts one username and
// password, and can be told to stall: every connection stops moving bytes in
// both directions while staying open. That is what a laptop sees after
// sleeping, and the only way to tell it apart from a healthy idle connection
// is a request that never gets its reply.
package sshtest

import (
	"crypto/ed25519"
	"crypto/rand"
	"errors"
	"io"
	"net"
	"strconv"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
)

// RefusedHost is a destination the server refuses to open, so tests can see
// a refusal without depending on some local port being closed. On a machine
// running a transparent proxy every local port accepts.
const RefusedHost = "refused.test"

// Server is a running SSH server on a loopback port.
type Server struct {
	Host string
	Port int

	user, password string
	ln             net.Listener

	mu      sync.Mutex
	cond    *sync.Cond
	stalled bool
	conns   []net.Conn
	targets []string
}

// Start listens on 127.0.0.1 at a free port.
func Start(user, password string) (*Server, error) {
	return StartOn("127.0.0.1:0", user, password)
}

// StartOn listens on addr.
func StartOn(addr, user, password string) (*Server, error) {
	_, key, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return nil, err
	}
	signer, err := ssh.NewSignerFromKey(key)
	if err != nil {
		return nil, err
	}

	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	host, _, _ := net.SplitHostPort(ln.Addr().String())
	s := &Server{
		Host:     host,
		Port:     ln.Addr().(*net.TCPAddr).Port,
		user:     user,
		password: password,
		ln:       ln,
	}
	s.cond = sync.NewCond(&s.mu)

	cfg := &ssh.ServerConfig{
		PasswordCallback: func(meta ssh.ConnMetadata, given []byte) (*ssh.Permissions, error) {
			if meta.User() == s.user && string(given) == s.password {
				return nil, nil
			}
			return nil, errors.New("wrong credentials")
		},
	}
	cfg.AddHostKey(signer)

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			wrapped := &stallConn{Conn: conn, s: s}
			s.mu.Lock()
			s.conns = append(s.conns, wrapped)
			s.mu.Unlock()
			go s.serve(wrapped, cfg)
		}
	}()
	return s, nil
}

// User and Password are the credentials the server accepts.
func (s *Server) User() string     { return s.user }
func (s *Server) Password() string { return s.password }

// Addr is host:port.
func (s *Server) Addr() string { return net.JoinHostPort(s.Host, strconv.Itoa(s.Port)) }

// Stall freezes every connection, present and future, until Resume.
func (s *Server) Stall() {
	s.mu.Lock()
	s.stalled = true
	s.mu.Unlock()
}

// Resume lets stalled connections move again.
func (s *Server) Resume() {
	s.mu.Lock()
	s.stalled = false
	s.cond.Broadcast()
	s.mu.Unlock()
}

// DropConnections hangs up on every client without a graceful close.
func (s *Server) DropConnections() {
	s.mu.Lock()
	conns := s.conns
	s.conns = nil
	s.mu.Unlock()
	for _, conn := range conns {
		conn.Close()
	}
}

// Targets lists every destination a client asked to be forwarded to.
func (s *Server) Targets() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string(nil), s.targets...)
}

// Close stops listening and drops every connection.
func (s *Server) Close() {
	s.ln.Close()
	s.Resume()
	s.DropConnections()
}

func (s *Server) waitWhileStalled() {
	s.mu.Lock()
	for s.stalled {
		s.cond.Wait()
	}
	s.mu.Unlock()
}

// stallConn holds bytes back in both directions while the server is stalled.
type stallConn struct {
	net.Conn
	s *Server
}

func (c *stallConn) Read(p []byte) (int, error) {
	n, err := c.Conn.Read(p)
	// Bytes that arrived during the stall are held, not delivered: the
	// server must look as if it never saw them.
	c.s.waitWhileStalled()
	return n, err
}

func (c *stallConn) Write(p []byte) (int, error) {
	c.s.waitWhileStalled()
	return c.Conn.Write(p)
}

func (s *Server) serve(conn net.Conn, cfg *ssh.ServerConfig) {
	sshConn, chans, reqs, err := ssh.NewServerConn(conn, cfg)
	if err != nil {
		conn.Close()
		return
	}
	defer sshConn.Close()

	// Replies false to everything, keepalives included, which is all a
	// client needs to know the far end is still answering.
	go ssh.DiscardRequests(reqs)

	for newChannel := range chans {
		if newChannel.ChannelType() != "direct-tcpip" {
			newChannel.Reject(ssh.UnknownChannelType, newChannel.ChannelType())
			continue
		}
		go s.forward(newChannel)
	}
}

// directTCPIP is the payload of a direct-tcpip channel open, per RFC 4254 7.2.
type directTCPIP struct {
	DestHost string
	DestPort uint32
	SrcHost  string
	SrcPort  uint32
}

func (s *Server) forward(newChannel ssh.NewChannel) {
	var payload directTCPIP
	if err := ssh.Unmarshal(newChannel.ExtraData(), &payload); err != nil {
		newChannel.Reject(ssh.ConnectionFailed, "bad payload")
		return
	}

	target := net.JoinHostPort(payload.DestHost, strconv.Itoa(int(payload.DestPort)))
	s.mu.Lock()
	s.targets = append(s.targets, target)
	s.mu.Unlock()

	if payload.DestHost == RefusedHost {
		newChannel.Reject(ssh.ConnectionFailed, "refused")
		return
	}

	remote, err := net.DialTimeout("tcp", target, 5*time.Second)
	if err != nil {
		newChannel.Reject(ssh.ConnectionFailed, err.Error())
		return
	}
	defer remote.Close()

	channel, reqs, err := newChannel.Accept()
	if err != nil {
		return
	}
	defer channel.Close()
	go ssh.DiscardRequests(reqs)

	done := make(chan struct{}, 2)
	go func() { io.Copy(channel, remote); done <- struct{}{} }()
	go func() { io.Copy(remote, channel); done <- struct{}{} }()
	<-done
}
