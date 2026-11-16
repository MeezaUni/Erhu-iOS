package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
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
	code, out := call(t, control, "POST", "/api/account", control.token, host, map[string]string{"username": "azeem", "password": "correct horse"})
	if code != 200 || out["accountCreated"] != true || out["username"] != "azeem" {
		t.Fatalf("create account: %d %v", code, out)
	}
	if cfg := store.Get(); !cfg.AccountCreated || cfg.Username != "azeem" {
		t.Fatalf("config not saved: %+v", cfg)
	}
	data, _ := os.ReadFile(store.path())
	if strings.Contains(string(data), "correct horse") {
		t.Fatal("the password must never be written to the config file")
	}
	// A second account can't be made this way; the listener is told to use the existing one.
	if code, out := call(t, control, "POST", "/api/account", control.token, host, map[string]string{"username": "other", "password": "another one"}); code != 400 || !strings.Contains(out["error"].(string), "already has an account") {
		t.Fatalf("second account: %d %v", code, out)
	}

	// The pairing link carries the address, user and computer name, and no password.
	_, state := call(t, control, "GET", "/api/state", control.token, host, nil)
	if invite, _ := state["invite"].(string); invite != "" {
		u, err := url.Parse(invite)
		if err != nil || u.Scheme != "erhu" || u.Host != "server" || u.Query().Get("user") != "azeem" || !strings.HasPrefix(u.Query().Get("url"), "http://") {
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
	status, serve, enable string
	statusErr, enableErr  error
	calls                 [][]string
}

func (f *fakeTailscale) run(ctx context.Context, args ...string) ([]byte, error) {
	f.calls = append(f.calls, args)
	switch {
	case args[0] == "status":
		return []byte(f.status), f.statusErr
	case len(args) > 1 && args[0] == "serve" && args[1] == "status":
		return []byte(f.serve), nil
	case args[0] == "serve":
		return []byte(f.enable), f.enableErr
	}
	return nil, errors.New("unexpected command")
}

const tsRunning = `Warning: client version differs
{"BackendState":"Running","Self":{"DNSName":"pc.tail1234.ts.net."}}`

func TestRemoteStates(t *testing.T) {
	cases := []struct {
		name string
		fake fakeTailscale
		want RemoteState
	}{
		{"missing", fakeTailscale{statusErr: errNoTailscale}, RemoteState{Status: "missing"}},
		{"stopped", fakeTailscale{status: "Tailscale is stopped.", statusErr: errors.New("exit status 1")}, RemoteState{Status: "signedOut"}},
		{"signed out", fakeTailscale{status: `{"BackendState":"NeedsLogin","Self":{"DNSName":""}}`}, RemoteState{Status: "signedOut"}},
		{"off", fakeTailscale{status: tsRunning, serve: `{}`}, RemoteState{Status: "off"}},
		{"other port", fakeTailscale{status: tsRunning,
			serve: `{"TCP":{"443":{"HTTPS":true}},"Web":{"pc.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}`},
			RemoteState{Status: "off"}},
		{"on", fakeTailscale{status: tsRunning,
			serve: `{"TCP":{"443":{"HTTPS":true}},"Web":{"pc.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:4533"}}}}}`},
			RemoteState{Status: "on", Address: "https://pc.tail1234.ts.net"}},
	}
	for _, c := range cases {
		fake := c.fake
		r := &Remote{run: fake.run}
		if got := r.State(4533); got != c.want {
			t.Errorf("%s: got %+v, want %+v", c.name, got, c.want)
		}
	}
}

func TestRemoteEnableAsksForApprovalOnce(t *testing.T) {
	fake := &fakeTailscale{status: tsRunning, serve: `{}`,
		enable: "Serve is not enabled on your tailnet.\nTo enable, visit:\n\n         https://login.tailscale.com/f/serve?node=abc123\n", enableErr: context.DeadlineExceeded}
	r := &Remote{run: fake.run}
	err := r.Enable(context.Background(), 4533)
	if err == nil || !strings.Contains(err.Error(), "permission") {
		t.Fatalf("want a permission message, got %v", err)
	}
	if got := r.State(4533); got.Status != "off" || got.ApproveURL != "https://login.tailscale.com/f/serve?node=abc123" {
		t.Fatalf("%+v", got)
	}
	last := fake.calls[0]
	if strings.Join(last, " ") != "serve --bg 4533" {
		t.Fatalf("ran %v", last)
	}
	// Once allowed, the next try works and the link goes away.
	fake.enable, fake.enableErr = "Available within your tailnet:\nhttps://pc.tail1234.ts.net/\n", nil
	fake.serve = `{"TCP":{"443":{"HTTPS":true}},"Web":{"pc.tail1234.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:4533"}}}}}`
	if err := r.Enable(context.Background(), 4533); err != nil {
		t.Fatal(err)
	}
	if got := r.State(4533); got != (RemoteState{Status: "on", Address: "https://pc.tail1234.ts.net"}) {
		t.Fatalf("%+v", got)
	}
}
