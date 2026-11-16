package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"
)

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// setup builds the stand-in server, points the launcher at it and gives a fresh settings folder.
func setup(t *testing.T) (*Store, *Server, *Control) {
	t.Helper()
	dir := t.TempDir()
	fake := filepath.Join(dir, "navidrome")
	if runtime.GOOS == "windows" {
		fake += ".exe"
	}
	if out, err := exec.Command("go", "build", "-o", fake, "./internal/fakenavidrome").CombinedOutput(); err != nil {
		t.Fatalf("building the stand-in server: %v\n%s", err, out)
	}
	t.Setenv("ERHU_NAVIDROME", fake)
	t.Setenv("ERHU_SERVER_HOME", filepath.Join(dir, "home"))
	store, err := openStore()
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Update(func(c *Config) { c.Port = freePort(t) }); err != nil {
		t.Fatal(err)
	}
	server := newServer(store)
	t.Cleanup(server.Stop)
	control, err := newControl(store, server, func() {})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { control.listener.Close() })
	// Never reach a real Tailscale on the test machine.
	control.remote.run = (&fakeTailscale{statusErr: errNoTailscale}).run
	return store, server, control
}

func waitFor(t *testing.T, server *Server, want State) {
	t.Helper()
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if state, _ := server.Status(); state == want {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	state, problem := server.Status()
	t.Fatalf("state is %q (%s), want %q", state, problem, want)
}

func call(t *testing.T, c *Control, method, path, token, host string, body any) (int, map[string]any) {
	t.Helper()
	var buf bytes.Buffer
	if body != nil {
		_ = json.NewEncoder(&buf).Encode(body)
	}
	req := httptest.NewRequest(method, path, &buf)
	req.Host = host
	if token != "" {
		req.Header.Set("X-Erhu-Token", token)
	}
	rec := httptest.NewRecorder()
	c.handler().ServeHTTP(rec, req)
	var out map[string]any
	_ = json.Unmarshal(rec.Body.Bytes(), &out)
	return rec.Code, out
}

func TestSetupFlowFolderAccountAndPairing(t *testing.T) {
	store, server, control := setup(t)
	host := "127.0.0.1:4534"
	if state, _ := server.Status(); state != StateSetup {
		t.Fatalf("a new install starts in setup, got %q", state)
	}

	// A folder that doesn't exist is refused and nothing is saved.
	if code, out := call(t, control, "POST", "/api/folder", control.token, host, map[string]string{"path": filepath.Join(t.TempDir(), "nope")}); code != 400 || out["error"] == "" {
		t.Fatalf("missing folder: %d %v", code, out)
	}
	if store.Get().MusicFolder != "" {
		t.Fatal("a refused folder must not be saved")
	}

	music := t.TempDir()
	if code, out := call(t, control, "POST", "/api/folder", control.token, host, map[string]string{"path": music}); code != 200 {
		t.Fatalf("set folder: %d %v", code, out)
	}
	waitFor(t, server, StateRunning)

	// Weak account details are refused before reaching the server.
	for _, bad := range []map[string]string{{"username": "a", "password": "longenough"}, {"username": "me", "password": "short"}, {"username": "has space", "password": "longenough"}} {
		if code, _ := call(t, control, "POST", "/api/account", control.token, host, bad); code != 400 {
			t.Fatalf("%v should be refused", bad)
		}
	}
	code, out := call(t, control, "POST", "/api/account", control.token, host, map[string]string{"username": "listener", "password": "correct horse"})
	if code != 200 || out["accountCreated"] != true || out["username"] != "listener" {
		t.Fatalf("create account: %d %v", code, out)
	}
	if cfg := store.Get(); !cfg.AccountCreated || cfg.Username != "listener" {
		t.Fatalf("config not saved: %+v", cfg)
	}
	data, _ := os.ReadFile(store.path())
	if strings.Contains(string(data), "correct horse") {
		t.Fatal("the password must never be written to the config file")
	}
	// A second account can't be made this way; the listener is told to use the existing one.
	if code, out := call(t, control, "POST", "/api/account", control.token, host, map[string]string{"username": "other", "password": "another password"}); code != 400 || !strings.Contains(out["error"].(string), "already has an account") {
		t.Fatalf("second account: %d %v", code, out)
	}

	// The pairing link carries the address, user and computer name, and no password.
	_, state := call(t, control, "GET", "/api/state", control.token, host, nil)
	if invite, _ := state["invite"].(string); invite != "" {
		u, err := url.Parse(invite)
		if err != nil || u.Scheme != "erhu" || u.Host != "server" || u.Query().Get("user") != "listener" || !strings.HasPrefix(u.Query().Get("url"), "http://") {
			t.Fatalf("bad invite %q", invite)
		}
		if strings.Contains(invite, "correct") {
			t.Fatal("invite contains the password")
		}
	} else if addrs, _ := state["addresses"].([]any); len(addrs) > 0 {
		t.Fatal("running with an address but no invite")
	}

	// Restarting keeps the account and comes back up.
	if code, _ := call(t, control, "POST", "/api/restart", control.token, host, map[string]any{}); code != 200 {
		t.Fatal("restart failed")
	}
	waitFor(t, server, StateRunning)
	server.Stop()
	if state, _ := server.Status(); state != StateStopped {
		t.Fatalf("after Stop: %q", state)
	}
	if answers(store.Get().Port) {
		t.Fatal("the server process is still answering after Stop")
	}
}

func TestOnlyThisComputersPageMayDriveTheLauncher(t *testing.T) {
	_, _, control := setup(t)
	good := "127.0.0.1:4534"
	if code, _ := call(t, control, "GET", "/api/state", control.token, good, nil); code != 200 {
		t.Fatal("the page's own request must work")
	}
	if code, _ := call(t, control, "GET", "/api/state", "", good, nil); code != 403 {
		t.Fatal("a request without the token must be refused")
	}
	if code, _ := call(t, control, "POST", "/api/quit", "wrong", good, map[string]any{}); code != 403 {
		t.Fatal("a wrong token must be refused")
	}
	// DNS rebinding: another site's name pointing at 127.0.0.1.
	if code, _ := call(t, control, "GET", "/api/state", control.token, "evil.example:4534", nil); code != 403 {
		t.Fatal("a foreign Host must be refused")
	}
	req := httptest.NewRequest("GET", "/qr.png", nil)
	rec := httptest.NewRecorder()
	control.handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusForbidden {
		t.Fatal("the QR code needs the token")
	}
}

func TestPortInUseIsExplained(t *testing.T) {
	store, server, _ := setup(t)
	l, err := net.Listen("tcp", ":0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	music := t.TempDir()
	_ = store.Update(func(c *Config) { c.Port = l.Addr().(*net.TCPAddr).Port; c.MusicFolder = music })
	if err := server.Start(); err == nil {
		t.Fatal("starting on a used port must fail")
	}
	if state, problem := server.Status(); state != StateFailed || !strings.Contains(problem, "already used") {
		t.Fatalf("%q %q", state, problem)
	}
}

func TestServerCrashIsReported(t *testing.T) {
	store, server, _ := setup(t)
	music := t.TempDir()
	_ = store.Update(func(c *Config) { c.MusicFolder = music })
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, server, StateRunning)
	server.mu.Lock()
	proc := server.cmd.Process
	server.mu.Unlock()
	_ = proc.Kill()
	waitFor(t, server, StateFailed)
	if _, problem := server.Status(); !strings.Contains(problem, "stopped unexpectedly") {
		t.Fatalf("problem: %q", problem)
	}
	// Restart recovers.
	if err := server.Start(); err != nil {
		t.Fatal(err)
	}
	waitFor(t, server, StateRunning)
}

func TestInviteLinkAndAddresses(t *testing.T) {
	got := inviteURL("http://192.168.1.20:4533", "", "listener", "Living room PC")
	want := "erhu://server?name=Living%20room%20PC&url=http%3A%2F%2F192.168.1.20%3A4533&user=listener"
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	got = inviteURL("http://192.168.1.20:4533", "https://pc.tail1234.ts.net", "listener", "")
	want = "erhu://server?remote=https%3A%2F%2Fpc.tail1234.ts.net&url=http%3A%2F%2F192.168.1.20%3A4533&user=listener"
	if got != want {
		t.Fatalf("got  %s\nwant %s", got, want)
	}
	if serverURL("192.168.1.20", 4533) != "http://192.168.1.20:4533" {
		t.Fatal("serverURL")
	}
	for ip, private := range map[string]bool{"192.168.1.5": true, "10.0.0.2": true, "172.20.1.1": true, "100.100.1.1": true, "8.8.8.8": false, "172.32.0.1": false} {
		if isPrivate(net.ParseIP(ip)) != private {
			t.Errorf("isPrivate(%s) should be %v", ip, private)
		}
	}
	for _, addr := range lanAddresses() {
		if ip := net.ParseIP(addr); ip == nil || ip.IsLoopback() {
			t.Errorf("unusable address %q", addr)
		}
	}
}

func TestConfigSurvivesRestartAndDamage(t *testing.T) {
	t.Setenv("ERHU_SERVER_HOME", t.TempDir())
	store, err := openStore()
	if err != nil {
		t.Fatal(err)
	}
	_ = store.Update(func(c *Config) { c.MusicFolder = "/music"; c.Username = "me"; c.AccountCreated = true })
	again, _ := openStore()
	if cfg := again.Get(); cfg.MusicFolder != "/music" || cfg.Username != "me" || !cfg.AccountCreated || cfg.Port != defaultPort {
		t.Fatalf("%+v", cfg)
	}
	_ = os.WriteFile(again.path(), []byte("{broken"), 0o600)
	damaged, err := openStore()
	if err != nil || damaged.Get().Port != defaultPort || damaged.Get().MusicFolder != "" {
		t.Fatalf("a damaged file should fall back to defaults: %v %+v", err, damaged.Get())
	}
}

// fakeTailscale answers like the Tailscale command line, from canned output.
type fakeTailscale struct {
	mu                    sync.Mutex
	status, serve, enable string
	statusErr, enableErr  error
	calls                 [][]string
}

// set changes the canned answers while the setup may be running in the background.
func (f *fakeTailscale) set(change func(f *fakeTailscale)) {
	f.mu.Lock()
	defer f.mu.Unlock()
	change(f)
}

func (f *fakeTailscale) run(ctx context.Context, args ...string) ([]byte, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, args)
	switch {
	case args[0] == "status":
		return []byte(f.status), f.statusErr
	case len(args) > 1 && args[0] == "serve" && args[1] == "status":
		return []byte(f.serve), nil
	case args[0] == "funnel":
		return []byte(f.enable), f.enableErr
	}
	return nil, errors.New("unexpected command")
}

const tsRunning = `Warning: client version differs
{"BackendState":"Running","Self":{"DNSName":"pc.tail1234.ts.net."}}`

func TestRemoteStates(t *testing.T) {
	cases := []struct {
		name string
		fake *fakeTailscale
		want RemoteState
	}{
		{"missing", &fakeTailscale{statusErr: errNoTailscale}, RemoteState{Status: "missing"}},
		{"stopped", &fakeTailscale{status: "Tailscale is stopped.", statusErr: errors.New("exit status 1")}, RemoteState{Status: "signedOut"}},
		{"signed out", &fakeTailscale{status: `{"BackendState":"NeedsLogin","Self":{"DNSName":""}}`}, RemoteState{Status: "signedOut"}},
		{"off", &fakeTailscale{status: tsRunning, serve: `{}`}, RemoteState{Status: "off"}},
		{"other port", &fakeTailscale{status: tsRunning,
			serve: `{"TCP":{"443":{"HTTPS":true}},"Web":{"pc.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}`},
			RemoteState{Status: "off"}},
		{"private only", &fakeTailscale{status: tsRunning,
			serve: `{"TCP":{"443":{"HTTPS":true}},"Web":{"pc.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:4533"}}}}}`},
			RemoteState{Status: "off"}},
		{"on", &fakeTailscale{status: tsRunning,
			serve: `{"TCP":{"443":{"HTTPS":true}},"Web":{"pc.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:4533"}}}},"AllowFunnel":{"pc.tail1234.ts.net:443":true}}`},
			RemoteState{Status: "on", Address: "https://pc.tail1234.ts.net"}},
	}
	for _, c := range cases {
		r := &Remote{run: c.fake.run}
		if got := r.State(4533); got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}

func TestRemoteEnableAsksForApprovalOnce(t *testing.T) {
	fake := &fakeTailscale{status: tsRunning, serve: `{}`,
		enable: "Funnel is not enabled on your tailnet.\nTo enable, visit:\n\n         https://login.tailscale.com/f/funnel?node=abc123\n", enableErr: context.DeadlineExceeded}
	r := &Remote{run: fake.run}
	err := r.Enable(context.Background(), 4533)
	if err == nil || !strings.Contains(err.Error(), "permission") {
		t.Fatalf("want a permission message, got %v", err)
	}
	if got := r.State(4533); got.Status != "off" || got.ApproveURL != "https://login.tailscale.com/f/funnel?node=abc123" {
		t.Fatalf("%+v", got)
	}
	if got := funnelCalls(fake); len(got) != 1 || got[0] != "funnel --bg --https=443 4533" {
		t.Fatalf("ran %v", got)
	}
	// Once allowed, the next try works and the link goes away.
	fake.enable, fake.enableErr = "Available on the internet:\nhttps://pc.tail1234.ts.net/\n", nil
	fake.serve = `{"TCP":{"443":{"HTTPS":true}},"Web":{"pc.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:4533"}}}},"AllowFunnel":{"pc.tail1234.ts.net:443":true}}`
	if err := r.Enable(context.Background(), 4533); err != nil {
		t.Fatal(err)
	}
	if got := r.State(4533); got != (RemoteState{Status: "on", Address: "https://pc.tail1234.ts.net"}) {
		t.Fatalf("%+v", got)
	}
}

// TestOneButtonSetup walks the whole away-from-home setup with a stand-in Tailscale: install,
// sign in, allow Funnel, done. Each page opens once, and nothing else is run.
func TestOneButtonSetup(t *testing.T) {
	defer func(old func() string) { installerURL = old }(installerURL)
	installerURL = func() string { return "https://pkgs.tailscale.com/stable/tailscale-setup-latest.exe" }
	fake := &fakeTailscale{statusErr: errNoTailscale}
	r := &Remote{run: fake.run, setup: newSetup()}
	var mu sync.Mutex
	var opened, installed []string
	seen := func() ([]string, []string) {
		mu.Lock()
		defer mu.Unlock()
		return append([]string(nil), opened...), append([]string(nil), installed...)
	}
	signIn := make(chan struct{})
	r.setup.open = func(url string) { mu.Lock(); opened = append(opened, url); mu.Unlock() }
	r.setup.startApp = func() {}
	r.setup.download = func(ctx context.Context, url, dir string) (string, error) {
		return filepath.Join(dir, "tailscale-setup.exe"), nil
	}
	r.setup.install = func(file string) error { mu.Lock(); installed = append(installed, file); mu.Unlock(); return nil }
	r.setup.stream = func(ctx context.Context, line func(string), args ...string) error {
		line("To authenticate, visit:")
		line("\thttps://login.tailscale.com/a/xyz789")
		<-signIn
		return nil
	}
	step := func() {
		r.forget()
		r.Advance(4533)
	}

	r.Start(4533)
	time.Sleep(50 * time.Millisecond) // Start advances in the background
	step()
	if _, installed := seen(); len(installed) != 1 {
		t.Fatalf("installer opened %d times", len(installed))
	}
	if _, msg, _ := r.progress(); !strings.Contains(msg, "installer is open") {
		t.Fatalf("step: %q", msg)
	}

	// Installed, not signed in: the sign-in page opens once.
	fake.set(func(f *fakeTailscale) { f.statusErr, f.status = nil, `{"BackendState":"NeedsLogin"}` })
	step()
	step()
	time.Sleep(50 * time.Millisecond)
	if opened, _ := seen(); len(opened) != 1 || opened[0] != "https://login.tailscale.com/a/xyz789" {
		t.Fatalf("opened %v", opened)
	}

	// Signed in; Funnel needs approval: the approval page opens once.
	close(signIn)
	time.Sleep(50 * time.Millisecond)
	fake.set(func(f *fakeTailscale) {
		f.status, f.serve = tsRunning, `{}`
		f.enable, f.enableErr = "Funnel is not enabled on your tailnet.\nTo enable, visit:\n\n https://login.tailscale.com/f/funnel?node=n1\n", context.DeadlineExceeded
	})
	step()
	if opened, _ := seen(); len(opened) != 2 || opened[1] != "https://login.tailscale.com/f/funnel?node=n1" {
		t.Fatalf("opened %v", opened)
	}

	// Allowed: the next try turns it on and the setup ends.
	fake.set(func(f *fakeTailscale) {
		f.enable, f.enableErr = "Available on the internet:\nhttps://pc.tail1234.ts.net/\n", nil
		f.serve = `{"TCP":{"443":{"HTTPS":true}},"Web":{"pc.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:4533"}}}},"AllowFunnel":{"pc.tail1234.ts.net:443":true}}`
	})
	r.setup.mu.Lock()
	r.setup.lastTry = time.Time{}
	r.setup.mu.Unlock()
	step()
	step()
	if wanted, _, problem := r.progress(); wanted || problem != "" {
		t.Fatalf("setup should be finished: wanted=%v problem=%q", wanted, problem)
	}
	if got := r.State(4533); got.Status != "on" || got.Address != "https://pc.tail1234.ts.net" {
		t.Fatalf("%+v", got)
	}
	if opened, installed := seen(); len(installed) != 1 || len(opened) != 2 {
		t.Fatalf("extra steps: installed %v opened %v", installed, opened)
	}
}

func funnelCalls(f *fakeTailscale) []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	var out []string
	for _, call := range f.calls {
		if call[0] == "funnel" {
			out = append(out, strings.Join(call, " "))
		}
	}
	return out
}

// Someone who already publishes other things through Tailscale keeps them: Erhu Server takes
// the next free Funnel port, shows that address, and turns off only its own port.
func TestRemoteLeavesOtherFunnelEntriesAlone(t *testing.T) {
	other := `{"TCP":{"443":{"HTTPS":true}},"Web":{"pc.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}},"AllowFunnel":{"pc.tail1234.ts.net:443":true}}`
	fake := &fakeTailscale{status: tsRunning, serve: other, enable: "Available on the internet:\nhttps://pc.tail1234.ts.net:8443/\n"}
	r := &Remote{run: fake.run, setup: newSetup()}
	if got := r.State(4533); got.Status != "off" {
		t.Fatalf("someone else's site on 443 is not Erhu Server: %+v", got)
	}
	if err := r.Enable(context.Background(), 4533); err != nil {
		t.Fatal(err)
	}
	if got := funnelCalls(fake); len(got) != 1 || got[0] != "funnel --bg --https=8443 4533" {
		t.Fatalf("ran %v", got)
	}
	fake.set(func(f *fakeTailscale) {
		f.serve = `{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true}},"Web":{"pc.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}},"pc.tail1234.ts.net:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:4533"}}}},"AllowFunnel":{"pc.tail1234.ts.net:443":true,"pc.tail1234.ts.net:8443":true}}`
	})
	r.forget()
	if got := r.State(4533); got != (RemoteState{Status: "on", Address: "https://pc.tail1234.ts.net:8443"}) {
		t.Fatalf("%+v", got)
	}
	if err := r.Disable(context.Background()); err != nil {
		t.Fatal(err)
	}
	if got := funnelCalls(fake); got[len(got)-1] != "funnel --https=8443 off" {
		t.Fatalf("turned off %v", got)
	}

	// All three Funnel ports taken by other things: nothing is changed, and the page says why.
	full := &fakeTailscale{status: tsRunning, serve: `{"TCP":{"443":{"HTTPS":true},"8443":{"HTTPS":true},"10000":{"HTTPS":true}}}`}
	r = &Remote{run: full.run, setup: newSetup()}
	if err := r.Enable(context.Background(), 4533); err == nil || !strings.Contains(err.Error(), "all used") {
		t.Fatalf("want a message about the ports, got %v", err)
	}
	if got := funnelCalls(full); len(got) != 0 {
		t.Fatalf("changed Tailscale anyway: %v", got)
	}
	// Turning off when Erhu Server never published anything changes nothing either.
	if err := r.Disable(context.Background()); err != nil || len(funnelCalls(full)) != 0 {
		t.Fatalf("Disable touched Tailscale: %v %v", err, funnelCalls(full))
	}
}

func TestFFmpegIsFoundOrInstalledWithTheSystemsPackageManager(t *testing.T) {
	dir := t.TempDir()
	files := map[string]bool{}
	f := newFFmpeg(dir)
	f.exists = func(path string) bool { return files[path] }
	f.lookPath = func(name string) (string, error) { return "", errors.New("not found") }
	if f.State().Found {
		t.Fatal("nothing installed yet")
	}
	// One in Erhu Server's own folder is used.
	own := filepath.Join(dir, exeName("ffmpeg"))
	files[own] = true
	if got := f.Path(); got != own {
		t.Fatalf("path %q", got)
	}
	delete(files, own)
	// ERHU_FFMPEG wins when it points at a file.
	t.Setenv("ERHU_FFMPEG", "/custom/ffmpeg")
	files["/custom/ffmpeg"] = true
	if got := f.Path(); got != "/custom/ffmpeg" {
		t.Fatalf("path %q", got)
	}
	t.Setenv("ERHU_FFMPEG", "")
	delete(files, "/custom/ffmpeg")

	// Installing runs the package manager, then restarts the server once ffmpeg is there.
	var ran []string
	var mu sync.Mutex
	f.run = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		mu.Lock()
		defer mu.Unlock()
		ran = append([]string{name}, args...)
		files[own] = true // the stand-in "installs" it
		return nil, nil
	}
	f.lookPath = func(name string) (string, error) {
		if name == "winget" {
			return `C:\winget.exe`, nil
		}
		return "", errors.New("not found")
	}
	files["/opt/homebrew/bin/brew"] = true
	if f.installer() == nil {
		if runtime.GOOS == "windows" || runtime.GOOS == "darwin" {
			t.Fatal("an installer should be available")
		}
		if err := f.Install(func() {}); err == nil {
			t.Fatal("no installer: Install should say so")
		}
		return
	}
	restarted := make(chan struct{})
	if err := f.Install(func() { close(restarted) }); err != nil {
		t.Fatal(err)
	}
	select {
	case <-restarted:
	case <-time.After(5 * time.Second):
		t.Fatal("not restarted after installing")
	}
	mu.Lock()
	defer mu.Unlock()
	if len(ran) == 0 || !(strings.Contains(ran[0], "winget") || strings.Contains(ran[0], "brew")) {
		t.Fatalf("ran %v", ran)
	}
}

// The web player serves its page and passes the Subsonic API through to the music server.
func TestWebPlayerServesItsPageAndTheAPI(t *testing.T) {
	music := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/rest/ping" || r.URL.Query().Get("u") != "listener" {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"subsonic-response":{"status":"ok","version":"1.16.1"}}`))
	}))
	defer music.Close()
	port, _ := strconv.Atoi(music.URL[strings.LastIndex(music.URL, ":")+1:])
	t.Setenv("ERHU_SERVER_HOME", t.TempDir())
	store, err := openStore()
	if err != nil {
		t.Fatal(err)
	}
	_ = store.Update(func(c *Config) { c.Port = port })
	page := httptest.NewServer((&Player{store: store}).handler())
	defer page.Close()

	res, err := http.Get(page.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || !strings.Contains(string(body), "<title>Erhu</title>") || res.Header.Get("Content-Security-Policy") == "" {
		t.Fatalf("page: %d %q", res.StatusCode, res.Header)
	}
	res, err = http.Get(page.URL + "/rest/ping?u=listener&f=json")
	if err != nil {
		t.Fatal(err)
	}
	body, _ = io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || !strings.Contains(string(body), `"status":"ok"`) {
		t.Fatalf("api: %d %s", res.StatusCode, body)
	}
	// Nothing else of Erhu Server is reachable from the player's address.
	for _, path := range []string{"/api/state", "/qr.png", "/rest/../api/state"} {
		res, err := http.Get(page.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		res.Body.Close()
		if res.StatusCode == 200 {
			t.Fatalf("%s should not be served", path)
		}
	}
	// The music server stopped: a clear error, not a hang.
	music.Close()
	res, err = http.Get(page.URL + "/rest/ping?u=listener")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusBadGateway {
		t.Fatalf("got %d", res.StatusCode)
	}
}
