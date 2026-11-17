// Erhu Server: a small launcher that runs Navidrome for the Erhu music player.
// Copyright (C) 2026 the Erhu authors. Licensed under the GNU GPL v3.0; see LICENSE.

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net/http"
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

// Away-from-home listening through Cloudflare Tunnel: a permanent address on the listener's own
// domain (a free one works, for example from DigitalPlat), served from Cloudflare's servers
// nearest the phone. The computer keeps an outgoing connection to Cloudflare, so nothing is
// opened on the router and it works behind carrier-grade NAT. Nothing is installed on the phone.
//
// One button: install cloudflared (winget or Homebrew), sign in to Cloudflare once in the
// browser (choosing the domain), create a tunnel named erhu-server, point the chosen address at
// it, then run it with the server, pointing at the Erhu web app (which passes the Subsonic API
// through, so the phone app works through it).

const tunnelName = "erhu-server"

// CloudflareState is what the page shows about Cloudflare.
type CloudflareState struct {
	// "off", "settingUp", "starting" (running, not answering yet) or "on".
	Status     string `json:"status"`
	Host       string `json:"host,omitempty"`
	Address    string `json:"address,omitempty"`
	Step       string `json:"step,omitempty"`
	Problem    string `json:"problem,omitempty"`
	CanInstall bool   `json:"canInstall"`
}

type Cloudflare struct {
	mu       sync.Mutex
	store    *Store
	port     func() int
	run      func(ctx context.Context, name string, args ...string) ([]byte, error)
	stream   func(ctx context.Context, line func(string), name string, args ...string) error
	open     func(url string)
	lookPath func(string) (string, error)
	exists   func(string) bool
	// Starts the tunnel; returns a stop function and a channel closed when it exits.
	start func(bin string, args []string, log string) (stop func(), done <-chan struct{}, err error)
	probe func(url string) bool

	busy     bool
	step     string
	problem  string
	stopRun  func()
	running  bool
	answered bool
	wanted   bool
}

func newCloudflare(store *Store, port func() int) *Cloudflare {
	return &Cloudflare{store: store, port: port, run: runCommand, stream: streamCommand, open: openBrowser,
		lookPath: exec.LookPath, exists: func(path string) bool { info, err := os.Stat(path); return err == nil && !info.IsDir() },
		start: startProcess, probe: answers200}
}

// binary finds cloudflared ("" if it isn't installed).
func (c *Cloudflare) binary() string {
	if path, err := c.lookPath("cloudflared"); err == nil {
		return path
	}
	var candidates []string
	switch runtime.GOOS {
	case "windows":
		for _, base := range []string{os.Getenv("ProgramFiles(x86)"), os.Getenv("ProgramFiles")} {
			if base != "" {
				candidates = append(candidates, filepath.Join(base, "cloudflared", "cloudflared.exe"))
			}
		}
		if local := os.Getenv("LOCALAPPDATA"); local != "" {
			candidates = append(candidates, filepath.Join(local, "Microsoft", "WinGet", "Links", "cloudflared.exe"))
		}
	case "darwin":
		candidates = []string{"/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"}
	}
	for _, path := range candidates {
		if c.exists(path) {
			return path
		}
	}
	return ""
}

func (c *Cloudflare) installer() []string {
	switch runtime.GOOS {
	case "windows":
		if winget, err := c.lookPath("winget"); err == nil {
			return []string{winget, "install", "--id", "Cloudflare.cloudflared", "--exact", "--silent",
				"--accept-source-agreements", "--accept-package-agreements"}
		}
	case "darwin":
		for _, brew := range []string{"/opt/homebrew/bin/brew", "/usr/local/bin/brew"} {
			if c.exists(brew) {
				return []string{brew, "install", "cloudflared"}
			}
		}
	}
	return nil
}

// certPath is where "cloudflared tunnel login" saves its sign-in.
func certPath() string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".cloudflared", "cert.pem")
}

var hostPattern = regexp.MustCompile(`^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$`)

// normalizeHost turns what the listener typed ("https://Music.erhu.dpdns.org/") into a host name.
func normalizeHost(text string) (string, error) {
	host := strings.ToLower(strings.TrimSpace(text))
	host = strings.TrimPrefix(strings.TrimPrefix(host, "https://"), "http://")
	host = strings.TrimSuffix(strings.SplitN(host, "/", 2)[0], ".")
	if !hostPattern.MatchString(host) {
		return "", errors.New("Type the address you want, on your domain in Cloudflare, for example music.erhu.dpdns.org.")
	}
	return host, nil
}

func (c *Cloudflare) State() CloudflareState {
	cfg := c.store.Get()
	c.mu.Lock()
	defer c.mu.Unlock()
	state := CloudflareState{Status: "off", Host: cfg.CloudflareHost, Step: c.step, Problem: c.problem,
		CanInstall: c.binary() != "" || c.installer() != nil}
	switch {
	case c.busy:
		state.Status = "settingUp"
	case c.running && cfg.CloudflareHost != "" && c.answered:
		state.Status, state.Address = "on", "https://"+cfg.CloudflareHost
	case c.running && cfg.CloudflareHost != "":
		state.Status, state.Address = "starting", "https://"+cfg.CloudflareHost
	}
	return state
}

func (c *Cloudflare) say(step string) {
	c.mu.Lock()
	c.step = step
	c.mu.Unlock()
}

// Setup runs the one-button setup in the background for [host].
func (c *Cloudflare) Setup(hostText string) error {
	host, err := normalizeHost(hostText)
	if err != nil {
		return err
	}
	c.mu.Lock()
	if c.busy {
		c.mu.Unlock()
		return nil
	}
	c.busy, c.problem, c.step = true, "", ""
	c.mu.Unlock()
	go func() {
		err := c.setup(host)
		c.mu.Lock()
		c.busy, c.step = false, ""
		if err != nil {
			c.problem = err.Error()
		}
		c.mu.Unlock()
	}()
	return nil
}

func (c *Cloudflare) setup(host string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Minute)
	defer cancel()
	bin := c.binary()
	if bin == "" {
		command := c.installer()
		if command == nil {
			return errors.New("Erhu Server can't install cloudflared here. Install it from developers.cloudflare.com (Cloudflare Tunnel downloads), then press the button again.")
		}
		c.say("Installing Cloudflare's tunnel program (cloudflared)…")
		out, err := c.run(ctx, command[0], command[1:]...)
		if bin = c.binary(); bin == "" {
			return errors.New("cloudflared couldn't be installed: " + firstLine(out, errOr(err, "it wasn't found afterwards")))
		}
	}
	if !c.exists(certPath()) {
		c.say("Sign in to Cloudflare in the page that opened, and choose your domain (the one " + host + " is on). Erhu Server continues by itself.")
		opened := false
		err := c.stream(ctx, func(line string) {
			if url := cloudflareLink.FindString(line); url != "" && !opened {
				opened = true
				c.open(url)
			}
		}, bin, "tunnel", "login")
		if !c.exists(certPath()) {
			return errors.New("Cloudflare sign-in didn't finish" + suffix(err) + ". Press the button and sign in again.")
		}
	}
	c.say("Creating the tunnel…")
	id, err := c.tunnelID(ctx, bin)
	if err != nil {
		return err
	}
	if id == "" {
		out, err := c.run(ctx, bin, "tunnel", "create", tunnelName)
		if err != nil {
			return errors.New("Cloudflare couldn't create the tunnel: " + firstLine(out, err))
		}
		if id, err = c.tunnelID(ctx, bin); err != nil || id == "" {
			return errors.New("The tunnel was created but couldn't be found afterwards. Press the button again.")
		}
	}
	c.say("Pointing " + host + " at this computer…")
	if out, err := c.run(ctx, bin, "tunnel", "route", "dns", "--overwrite-dns", id, host); err != nil {
		return errors.New("Cloudflare couldn't point " + host + " at the tunnel: " + firstLine(out, err) +
			". Check that the domain is added to your Cloudflare account and shows Active.")
	}
	if err := c.store.Update(func(cfg *Config) { cfg.CloudflareHost, cfg.CloudflareTunnel = host, id }); err != nil {
		return err
	}
	c.Start()
	return nil
}

func suffix(err error) string {
	if err == nil {
		return ""
	}
	return " (" + err.Error() + ")"
}

var cloudflareLink = regexp.MustCompile(`https://dash\.cloudflare\.com/\S+`)

// tunnelID finds the erhu-server tunnel in the account ("" if there is none).
func (c *Cloudflare) tunnelID(ctx context.Context, bin string) (string, error) {
	out, err := c.run(ctx, bin, "tunnel", "list", "--output", "json")
	if err != nil {
		return "", errors.New("Cloudflare couldn't list your tunnels: " + firstLine(out, err))
	}
	return findTunnel(out, tunnelName), nil
}

func findTunnel(out []byte, name string) string {
	var tunnels []struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		DeletedAt string `json:"deleted_at"`
	}
	if err := json.Unmarshal(jsonArray(out), &tunnels); err != nil {
		return ""
	}
	for _, t := range tunnels {
		if t.Name == name && (t.DeletedAt == "" || strings.HasPrefix(t.DeletedAt, "0001-")) {
			return t.ID
		}
	}
	return ""
}

// jsonArray drops anything cloudflared prints before its JSON.
func jsonArray(out []byte) []byte {
	if i := strings.IndexByte(string(out), '['); i >= 0 {
		return out[i:]
	}
	return out
}

// Start runs the tunnel (if one is set up), restarting it if it stops, until [Stop].
func (c *Cloudflare) Start() {
	cfg := c.store.Get()
	bin := c.binary()
	if cfg.CloudflareHost == "" || cfg.CloudflareTunnel == "" || bin == "" {
		return
	}
	c.mu.Lock()
	if c.wanted {
		c.mu.Unlock()
		return
	}
	c.wanted = true
	c.mu.Unlock()
	go c.keepRunning(bin, cfg)
}

func (c *Cloudflare) keepRunning(bin string, cfg Config) {
	delay := 2 * time.Second
	for {
		c.mu.Lock()
		wanted := c.wanted
		c.mu.Unlock()
		if !wanted {
			return
		}
		args := []string{"tunnel", "--no-autoupdate", "run", "--url", "http://127.0.0.1:" + strconv.Itoa(c.port()), cfg.CloudflareTunnel}
		stop, done, err := c.start(bin, args, filepath.Join(c.store.home, "cloudflared.log"))
		if err != nil {
			c.mu.Lock()
			c.problem = "The Cloudflare tunnel couldn't start: " + err.Error()
			c.mu.Unlock()
			time.Sleep(30 * time.Second)
			continue
		}
		c.mu.Lock()
		c.stopRun, c.running, c.answered, c.problem = stop, true, false, ""
		c.mu.Unlock()
		go c.watch(cfg.CloudflareHost, done)
		<-done
		c.mu.Lock()
		c.running, c.answered, c.stopRun = false, false, nil
		c.mu.Unlock()
		time.Sleep(delay)
		if delay < time.Minute {
			delay *= 2
		}
	}
}

// watch marks the address as working once it answers from the internet.
func (c *Cloudflare) watch(host string, done <-chan struct{}) {
	for i := 0; i < 40; i++ {
		select {
		case <-done:
			return
		case <-time.After(3 * time.Second):
		}
		if c.probe("https://" + host + "/rest/ping.view") {
			c.mu.Lock()
			c.answered = true
			c.mu.Unlock()
			return
		}
	}
}

// Stop stops the tunnel (when quitting, or turning it off).
func (c *Cloudflare) Stop() {
	c.mu.Lock()
	c.wanted = false
	stop := c.stopRun
	c.mu.Unlock()
	if stop != nil {
		stop()
	}
}

// Disable turns Cloudflare off: the tunnel stops and Erhu forgets the address (the tunnel and
// the address stay in the Cloudflare account, so turning it on again is quick).
func (c *Cloudflare) Disable() error {
	c.Stop()
	return c.store.Update(func(cfg *Config) { cfg.CloudflareHost = "" })
}

func streamCommand(ctx context.Context, line func(string), name string, args ...string) error {
	cmd := exec.CommandContext(ctx, name, args...)
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

func startProcess(bin string, args []string, logPath string) (func(), <-chan struct{}, error) {
	logFile, err := openLog(logPath)
	if err != nil {
		return nil, nil, err
	}
	cmd := exec.Command(bin, args...)
	cmd.Stdout, cmd.Stderr = logFile, logFile
	hideWindow(cmd)
	if err := cmd.Start(); err != nil {
		logFile.Close()
		return nil, nil, err
	}
	done := make(chan struct{})
	go func() { _ = cmd.Wait(); logFile.Close(); close(done) }()
	return func() { _ = cmd.Process.Kill() }, done, nil
}

// answers200 is whether [url] answers at all (any HTTP reply means the tunnel reaches us).
func answers200(url string) bool {
	client := http.Client{Timeout: 10 * time.Second}
	res, err := client.Get(url)
	if err != nil {
		return false
	}
	res.Body.Close()
	return res.StatusCode < 500
}
