// Erhu Server: a small launcher that runs Navidrome for the Erhu music player.
// Copyright (C) 2026 the Erhu authors. Licensed under the GNU GPL v3.0; see LICENSE.

package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Away-from-home listening goes through Tailscale Funnel. Tailscale runs on this computer only;
// "tailscale funnel" gives it a permanent public HTTPS address
// (https://<computer>.<tailnet>.ts.net) that forwards to the server, so Erhu on any phone can
// reach it with no extra app. Nothing is opened on the router: the computer keeps an outgoing
// connection to Tailscale, which relays requests to it. The server is reachable from the
// internet and protected by its account password, so the page asks for a strong one.

// RemoteState is what the page shows about away-from-home access.
type RemoteState struct {
	// "missing" (Tailscale isn't installed), "signedOut", "off", "on", or "error".
	Status  string `json:"status"`
	Address string `json:"address,omitempty"`
	// A Tailscale page the listener must open once to allow HTTPS addresses on their network.
	ApproveURL string `json:"approveUrl,omitempty"`
	Problem    string `json:"problem,omitempty"`
	// While the one-button setup runs: what it is doing or waiting for.
	SettingUp bool   `json:"settingUp,omitempty"`
	Step      string `json:"step,omitempty"`
}

// runner runs the Tailscale command line; replaced in tests.
type runner func(ctx context.Context, args ...string) ([]byte, error)

type Remote struct {
	mu      sync.Mutex
	run     runner
	cached  RemoteState
	checked time.Time
	approve string
	setup   *tsSetup
	// From the last check: this computer's Tailscale name, its serve config, and the Funnel
	// port that publishes the server (0: none).
	host  string
	serve tsServe
	port  int
}

func newRemote() *Remote { return &Remote{run: runTailscale, setup: newSetup()} }

// tailscaleBinary finds the Tailscale command line: on the PATH, or where the Windows and
// macOS apps install it.
func tailscaleBinary() string {
	if path, err := exec.LookPath("tailscale"); err == nil {
		return path
	}
	var candidates []string
	switch runtime.GOOS {
	case "windows":
		for _, base := range []string{os.Getenv("ProgramFiles"), os.Getenv("ProgramFiles(x86)")} {
			if base != "" {
				candidates = append(candidates, filepath.Join(base, "Tailscale", "tailscale.exe"))
			}
		}
	case "darwin":
		candidates = []string{"/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"}
	}
	for _, path := range candidates {
		if info, err := os.Stat(path); err == nil && !info.IsDir() {
			return path
		}
	}
	return ""
}

var errNoTailscale = errors.New("tailscale is not installed")

func runTailscale(ctx context.Context, args ...string) ([]byte, error) {
	bin := tailscaleBinary()
	if bin == "" {
		return nil, errNoTailscale
	}
	cmd := exec.CommandContext(ctx, bin, args...)
	hideWindow(cmd)
	return cmd.CombinedOutput()
}

// State is cached for a few seconds: the page asks every two seconds.
func (r *Remote) State(port int) RemoteState {
	r.mu.Lock()
	defer r.mu.Unlock()
	if time.Since(r.checked) < 10*time.Second {
		return r.cached
	}
	r.cached = r.check(port)
	r.checked = time.Now()
	return r.cached
}

func (r *Remote) forget() {
	r.mu.Lock()
	r.checked = time.Time{}
	r.mu.Unlock()
}

type tsStatus struct {
	BackendState string
	Self         *struct{ DNSName string }
}

type tsServe struct {
	TCP         map[string]struct{ HTTPS bool }
	AllowFunnel map[string]bool
	Web         map[string]struct {
		Handlers map[string]struct{ Proxy string }
	}
}

// funnelPorts are the HTTPS ports Tailscale Funnel can publish on, in the order Erhu Server
// tries them. A port already used for something else is never touched: listeners who serve
// other things through Tailscale keep them.
var funnelPorts = []int{443, 8443, 10000}

func (r *Remote) check(port int) RemoteState {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := r.run(ctx, "status", "--json")
	if errors.Is(err, errNoTailscale) {
		return RemoteState{Status: "missing"}
	}
	var status tsStatus
	if jsonErr := json.Unmarshal(jsonPart(out), &status); jsonErr != nil {
		if err != nil {
			// "tailscale status" fails while the app is stopped or signed out.
			return RemoteState{Status: "signedOut"}
		}
		return RemoteState{Status: "error", Problem: "Tailscale's answer couldn't be read."}
	}
	if status.BackendState != "Running" || status.Self == nil || status.Self.DNSName == "" {
		return RemoteState{Status: "signedOut"}
	}
	host := strings.TrimSuffix(status.Self.DNSName, ".")
	r.host = host
	state := RemoteState{Status: "off", ApproveURL: r.approve}
	out, err = r.run(ctx, "serve", "status", "--json")
	var cfg tsServe
	if err == nil {
		_ = json.Unmarshal(jsonPart(out), &cfg)
	}
	r.serve = cfg
	r.port = 0
	if https, ok := servingPort(cfg, host, port); ok {
		r.approve = ""
		r.port = https
		return RemoteState{Status: "on", Address: httpsAddress(host, https)}
	}
	return state
}

func httpsAddress(host string, port int) string {
	if port == 443 {
		return "https://" + host
	}
	return "https://" + host + ":" + strconv.Itoa(port)
}

// servingPort is the Funnel port that publishes the server (forwards to [port]), if any.
// Served only inside the tailnet (no funnel) doesn't count: phones without Tailscale couldn't
// reach it.
func servingPort(cfg tsServe, host string, port int) (int, bool) {
	target := ":" + strconv.Itoa(port)
	for _, https := range funnelPorts {
		key := host + ":" + strconv.Itoa(https)
		if !cfg.TCP[strconv.Itoa(https)].HTTPS || !cfg.AllowFunnel[key] {
			continue
		}
		for _, handler := range cfg.Web[key].Handlers {
			proxy := strings.TrimSuffix(handler.Proxy, "/")
			if proxy == strconv.Itoa(port) || strings.HasSuffix(proxy, target) {
				return https, true
			}
		}
	}
	return 0, false
}

// freeFunnelPort is the first Funnel port nothing else uses (0: all are taken).
func freeFunnelPort(cfg tsServe, host string) int {
	for _, https := range funnelPorts {
		_, tcp := cfg.TCP[strconv.Itoa(https)]
		_, web := cfg.Web[host+":"+strconv.Itoa(https)]
		if !tcp && !web {
			return https
		}
	}
	return 0
}

// jsonPart drops anything Tailscale prints before its JSON (warnings about the client version).
func jsonPart(out []byte) []byte {
	if i := strings.IndexByte(string(out), '{'); i >= 0 {
		return out[i:]
	}
	return out
}

var approveLink = regexp.MustCompile(`https://login\.tailscale\.com/\S+`)

// Enable asks Tailscale to publish the server at this computer's HTTPS address. The first time,
// Tailscale may ask the listener to allow Funnel on their account: the link is kept for the page.
func (r *Remote) Enable(ctx context.Context, port int) error {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	r.forget()
	if r.State(port).Status == "on" {
		return nil
	}
	r.mu.Lock()
	https := freeFunnelPort(r.serve, r.host)
	r.mu.Unlock()
	if https == 0 {
		return errors.New("Tailscale Funnel's ports (443, 8443 and 10000) are all used for other things on this computer. Free one of them in Tailscale, then press the button again.")
	}
	out, err := r.run(ctx, "funnel", "--bg", "--https="+strconv.Itoa(https), strconv.Itoa(port))
	defer r.forget()
	if link := approveLink.FindString(string(out)); link != "" {
		r.mu.Lock()
		r.approve = link
		r.mu.Unlock()
		return errors.New("Tailscale needs your permission once: open the link shown below, allow it, then press the button again.")
	}
	if errors.Is(err, errNoTailscale) {
		return errors.New("Install Tailscale on this computer first.")
	}
	if err != nil {
		return errors.New("Tailscale couldn't turn this on: " + firstLine(out, err))
	}
	return nil
}

// Disable stops publishing the HTTPS address. Other things served through Tailscale are left alone.
func (r *Remote) Disable(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	r.mu.Lock()
	https := r.port
	r.mu.Unlock()
	if https == 0 {
		return nil // not published by Erhu Server: nothing to turn off
	}
	out, err := r.run(ctx, "funnel", "--https="+strconv.Itoa(https), "off")
	r.forget()
	if err != nil {
		return errors.New("Tailscale couldn't turn this off: " + firstLine(out, err))
	}
	return nil
}

func firstLine(out []byte, err error) string {
	text := strings.TrimSpace(string(out))
	if text == "" {
		return err.Error()
	}
	if i := strings.IndexByte(text, '\n'); i >= 0 {
		text = text[:i]
	}
	return text
}
