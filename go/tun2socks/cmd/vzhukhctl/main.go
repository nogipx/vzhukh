// Command vzhukhctl talks to vzhukhd from a terminal, the same way the app
// does. For poking at the helper without the app.
//
//	vzhukhctl status
//	vzhukhctl start config.json
//	vzhukhctl flows
//	vzhukhctl stop
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"time"
)

func main() {
	socket := flag.String("socket", "/var/run/vzhukhd.sock", "control socket")
	flag.Usage = func() {
		fmt.Fprintln(os.Stderr, "usage: vzhukhctl [-socket path] hello|status|start <config.json>|stop|flows [since]|nudge")
	}
	flag.Parse()
	if flag.NArg() == 0 {
		flag.Usage()
		os.Exit(2)
	}

	method := flag.Arg(0)
	var params any
	switch method {
	case "start":
		if flag.NArg() < 2 {
			fail("start needs a config file")
		}
		raw, err := os.ReadFile(flag.Arg(1))
		if err != nil {
			fail(err.Error())
		}
		params = json.RawMessage(raw)
	case "flows":
		since := 0
		if flag.NArg() > 1 {
			fmt.Sscan(flag.Arg(1), &since)
		}
		params = map[string]int{"since": since}
	}

	conn, err := net.DialTimeout("unix", *socket, 2*time.Second)
	if err != nil {
		fail(err.Error())
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(30 * time.Second))

	req, _ := json.Marshal(map[string]any{"id": 1, "method": method, "params": params})
	if _, err := conn.Write(append(req, '\n')); err != nil {
		fail(err.Error())
	}
	reader := bufio.NewReaderSize(conn, 1<<20)
	line, err := reader.ReadBytes('\n')
	if err != nil {
		fail("no answer: " + err.Error())
	}
	var resp struct {
		Result json.RawMessage `json:"result"`
		Error  string          `json:"error"`
	}
	if err := json.Unmarshal(line, &resp); err != nil {
		fail(err.Error())
	}
	if resp.Error != "" {
		fail(resp.Error)
	}
	var pretty any
	json.Unmarshal(resp.Result, &pretty)
	out, _ := json.MarshalIndent(pretty, "", "  ")
	fmt.Println(string(out))
}

func fail(msg string) {
	fmt.Fprintln(os.Stderr, "vzhukhctl:", msg)
	os.Exit(1)
}
