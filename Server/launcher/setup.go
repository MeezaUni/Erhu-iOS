// Erhu Server: a small launcher that runs Navidrome for the Erhu music player.
// Copyright (C) 2026 the Erhu authors. Licensed under the GNU GPL v3.0; see LICENSE.

package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"
)

// One button sets up away-from-home access. Erhu Server does each step itself as soon as the
// one before it is done, opening a page only when the listener has to act:
//
//  1. Tailscale missing: download the official installer from pkgs.tailscale.com and open it
//     (the listener clicks through it; Windows and macOS check Tailscale's signature).
//  2. Signed out: start Tailscale and open its sign-in page in the browser.
//  3. Signed in: turn on Funnel. The first time, open the page that allows it.
//  4. On: done. The page shows the address and the QR code includes it.

// setup holds the progress of the button's steps.
type tsSetup struct {
	mu       sync.Mutex
	wanted   bool
	busy     bool
	step     string
	problem  string
	stage    string    // the status the last step was taken for
	lastTry  time.Time // when Funnel was last asked for (it is asked again while waiting for approval)
	opened   map[string]bool
	download func(ctx context.Context, url, dir string) (string, error)
	install  func(file string) error
	open     func(url string)
	stream   func(ctx context.Context, line func(string), args ...string) error
	startApp func()
}

func newSetup() *tsSetup {
	return &tsSetup{opened: map[string]bool{}, download: downloadFile, install: openInstaller, open: openBrowser,
		stream: streamTailscale, startApp: startTailscaleApp}
}

// installerURL is Tailscale's official installer for this system ("" where Erhu Server
// can't install it: Linux and NAS systems use their own package managers).
var installerURL = func() string {
	switch runtime.GOOS {
	case "windows":
		return "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe"
	case "darwin":
		return "https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg"
	}
	return ""
}

// Start begins (or resumes) the setup.
func (r *Remote) Start(port int) {
	r.setup.mu.Lock()
	r.setup.wanted = true
	r.setup.problem = ""
	r.setup.stage = ""
	r.setup.mu.Unlock()
	r.forget()
	go r.Advance(port)
}

// Cancel stops taking further steps (an installer or page already open stays open).
func (r *Remote) Cancel() {
	r.setup.mu.Lock()
	r.setup.wanted, r.setup.step, r.setup.problem = false, "", ""
	r.setup.mu.Unlock()
}

// progress is what the page shows while the setup runs.
func (r *Remote) progress() (wanted bool, step, problem string) {
	r.setup.mu.Lock()
	defer r.setup.mu.Unlock()
	return r.setup.wanted, r.setup.step, r.setup.problem
}

func (r *Remote) say(step string) {
	r.setup.mu.Lock()
	r.setup.step = step
	r.setup.mu.Unlock()
}

func (r *Remote) fail(problem string) {
	r.setup.mu.Lock()
	r.setup.problem, r.setup.step, r.setup.wanted = problem, "", false
	r.setup.mu.Unlock()
}

// openOnce opens a page in the browser the first time it is asked for.
func (r *Remote) openOnce(url string) {
	r.setup.mu.Lock()
	first := !r.setup.opened[url]
	r.setup.opened[url] = true
	r.setup.mu.Unlock()
	if first {
		r.setup.open(url)
	}
}

// Advance takes the next step, if one is due. The page's regular refresh calls it while the
// setup is wanted, so the setup moves on by itself once the listener finishes a step.
func (r *Remote) Advance(port int) {
	s := r.setup
	s.mu.Lock()
	if !s.wanted || s.busy {
		s.mu.Unlock()
		return
	}
	s.busy = true
	s.mu.Unlock()
	defer func() { s.mu.Lock(); s.busy = false; s.mu.Unlock() }()

	state := r.State(port)
	s.mu.Lock()
	repeat := s.stage == state.Status
	s.stage = state.Status
	retryFunnel := time.Since(s.lastTry) > 15*time.Second
	s.mu.Unlock()

	switch state.Status {
	case "on":
		r.Cancel()
	case "missing":
		if repeat {
			return // the installer is open; wait for it
		}
		url := installerURL()
		if url == "" {
			r.fail("Install Tailscale with your system's package manager (see tailscale.com/download), then press the button again.")
			return
		}
		r.say("Downloading Tailscale…")
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
		defer cancel()
		file, err := s.download(ctx, url, filepath.Join(os.TempDir(), "ErhuServer"))
		if err != nil {
			r.fail("Tailscale couldn't be downloaded (" + err.Error() + "). Install it from tailscale.com/download, then press the button again.")
			return
		}
		if err := s.install(file); err != nil {
			r.fail("The Tailscale installer couldn't be opened (" + err.Error() + "). Install it from tailscale.com/download, then press the button again.")
			return
		}
		if runtime.GOOS == "darwin" {
			r.say("The Tailscale installer is open: click through it. When Tailscale starts, allow what macOS asks for (the VPN configuration). Erhu Server continues by itself.")
		} else {
			r.say("The Tailscale installer is open: click through it and choose Yes when Windows asks. Erhu Server continues by itself.")
		}
	case "signedOut":
		if repeat {
			return // signing in; wait for it
		}
		r.say("Starting Tailscale…")
		s.startApp()
		r.say("Sign in to Tailscale in the page that opened in your browser (a free account; Google, Microsoft, Apple or GitHub works). Erhu Server continues by itself.")
		go r.signIn()
	case "off", "error":
		if !retryFunnel {
			return
		}
		s.mu.Lock()
		s.lastTry = time.Now()
		s.mu.Unlock()
		r.say("Turning on away-from-home access…")
		err := r.Enable(context.Background(), port)
		if link := r.State(port).ApproveURL; link != "" {
			r.openOnce(link)
			r.say("Tailscale asks once to allow Funnel: in the page that opened, allow it. Erhu Server continues by itself.")
			return
		}
		if err != nil {
			r.fail(err.Error())
		}
	}
}

var loginLink = regexp.MustCompile(`https://login\.tailscale\.com/\S+`)

// signIn runs "tailscale up", which prints a sign-in link (opened in the browser) and returns
// once the listener has signed in.
func (r *Remote) signIn() {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	err := r.setup.stream(ctx, func(line string) {
		if link := loginLink.FindString(line); link != "" {
			r.openOnce(link)
		}
	}, "up")
	r.forget()
	if err != nil && ctx.Err() == nil {
		// Signing in from the Tailscale app itself also works: the next check notices it.
		r.say("If no sign-in page opened, open Tailscale and sign in there. Erhu Server continues by itself.")
	}
	r.setup.mu.Lock()
	r.setup.stage = "" // check again and take the next step
	r.setup.mu.Unlock()
}

// streamTailscale runs the Tailscale command line and passes each line it prints to line.
func streamTailscale(ctx context.Context, line func(string), args ...string) error {
	bin := tailscaleBinary()
	if bin == "" {
		return errNoTailscale
	}
	cmd := exec.CommandContext(ctx, bin, args...)
	hideWindow(cmd)
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	cmd.Stderr = cmd.Stdout
	if err := cmd.Start(); err != nil {
		return err
	}
	scanner := bufio.NewScanner(pipe)
	for scanner.Scan() {
		line(scanner.Text())
	}
	return cmd.Wait()
}

// startTailscaleApp opens the Tailscale app, which macOS needs running before its command line
// works. On Windows the installer starts Tailscale's service itself.
func startTailscaleApp() {
	if runtime.GOOS == "darwin" {
		cmd := exec.Command("open", "-a", "Tailscale")
		_ = cmd.Run()
		time.Sleep(3 * time.Second)
	}
}

// downloadFile saves url (following redirects to the versioned file) into dir and returns the path.
func downloadFile(ctx context.Context, url, dir string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	name := path.Base(resp.Request.URL.Path)
	if !strings.HasPrefix(strings.ToLower(name), "tailscale") {
		return "", errors.New("unexpected file " + name)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	target := filepath.Join(dir, name)
	tmp := target + ".part"
	out, err := os.Create(tmp)
	if err != nil {
		return "", err
	}
	// Tailscale's installers are well under 200 MB.
	n, err := io.Copy(out, io.LimitReader(resp.Body, 200<<20))
	out.Close()
	if err == nil && resp.ContentLength > 0 && n != resp.ContentLength {
		err = errors.New("the download was cut short")
	}
	if err != nil {
		os.Remove(tmp)
		return "", err
	}
	return target, os.Rename(tmp, target)
}

// openInstaller opens the downloaded installer the way double-clicking it would, so Windows can
// ask for administrator permission and macOS opens it in Installer.
func openInstaller(file string) error {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("powershell", "-NoProfile", "-NonInteractive", "-Command",
			"Start-Process -FilePath '"+strings.ReplaceAll(file, "'", "''")+"'")
	case "darwin":
		cmd = exec.Command("open", file)
	default:
		return errors.New("not supported on this system")
	}
	hideWindow(cmd)
	return cmd.Run()
}
