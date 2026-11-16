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

// Away-from-home listening goes through Tailscale, a free private network between the
// listener's own devices. "tailscale serve" gives this computer an HTTPS address on that
// network (https://<computer>.<tailnet>.ts.net) that forwards to the server. Nothing is opened
// on the router and the server is not put on the public internet: only devices signed in to
// the listener's Tailscale account can reach it.

// RemoteState is what the page shows about away-from-home access.
type RemoteState struct {
	// "missing" (Tailscale isn't installed), "signedOut", "off", "on", or "error".
	Status  string `json:"status"`
	Address string `json:"address,omitempty"`
	// A Tailscale page the listener must open once to allow HTTPS addresses on their network.
	ApproveURL string `json:"approveUrl,omitempty"`
	Problem    string `json:"problem,omitempty"`
}

// runner runs the Tailscale command line; replaced in tests.
type runner func(ctx context.Context, args ...string) ([]byte, error)

type Remote struct {
	mu      sync.Mutex
	run     runner
	cached  RemoteState
	checked time.Time
	approve string
}

func newRemote() *Remote { return &Remote{run: runTailscale} }

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
	TCP map[string]struct{ HTTPS bool }
	Web map[string]struct {
		Handlers map[string]struct{ Proxy string }
	}
}

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
	state := RemoteState{Status: "off", ApproveURL: r.approve}
	out, err = r.run(ctx, "serve", "status", "--json")
	if err == nil && serving(jsonPart(out), host, port) {
		r.approve = ""
		return RemoteState{Status: "on", Address: "https://" + host}
	}
	return state
}

// serving reports whether Tailscale serves https://host (port 443) by forwarding to the server.
func serving(data []byte, host string, port int) bool {
	var cfg tsServe
	if json.Unmarshal(data, &cfg) != nil || !cfg.TCP["443"].HTTPS {
		return false
	}
	web, ok := cfg.Web[host+":443"]
	if !ok {
		return false
	}
	target := ":" + strconv.Itoa(port)
	for _, handler := range web.Handlers {
		proxy := strings.TrimSuffix(handler.Proxy, "/")
		if proxy == strconv.Itoa(port) || strings.HasSuffix(proxy, target) {
			return true
		}
	}
	return false
}

// jsonPart drops anything Tailscale prints before its JSON (warnings about the client version).
func jsonPart(out []byte) []byte {
	if i := strings.IndexByte(string(out), '{'); i >= 0 {
		return out[i:]
	}
	return out
}

var approveLink = regexp.MustCompile(`https://login\.tailscale\.com/\S+`)

// Enable asks Tailscale to serve the server at this computer's HTTPS address. The first time,
// Tailscale may ask the listener to allow HTTPS on their network: the link is kept for the page.
func (r *Remote) Enable(ctx context.Context, port int) error {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	out, err := r.run(ctx, "serve", "--bg", strconv.Itoa(port))
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

// Disable stops serving the HTTPS address. Other things served through Tailscale are left alone.
func (r *Remote) Disable(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	out, err := r.run(ctx, "serve", "--https=443", "off")
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
