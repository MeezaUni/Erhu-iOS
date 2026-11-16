package main

import (
	"context"
	"crypto/rand"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	qrcode "github.com/skip2/go-qrcode"
)

//go:embed ui.html
var pageHTML string

//go:embed assets/logo.png
var logoPNG []byte

// Control is the launcher's own page, served only to this computer (127.0.0.1). Requests that
// change anything must carry the page's token, and the Host header must be local, so other web
// pages open in the browser can't drive the launcher.
type Control struct {
	store  *Store
	server *Server
	remote *Remote
	ffmpeg *FFmpeg
	// The Erhu web player's port (0: not running).
	playerPort int
	token      string
	listener   net.Listener
	quit       func()
	// chooseFolder shows the system's folder picker ("" if cancelled).
	chooseFolder func() (string, error)
}

const controlPort = 4534

func newControl(store *Store, server *Server, quit func()) (*Control, error) {
	raw := make([]byte, 16)
	if _, err := rand.Read(raw); err != nil {
		return nil, err
	}
	var listener net.Listener
	var err error
	for port := controlPort; port < controlPort+10; port++ {
		if listener, err = net.Listen("tcp", "127.0.0.1:"+strconv.Itoa(port)); err == nil {
			break
		}
	}
	if err != nil {
		return nil, err
	}
	return &Control{store: store, server: server, remote: newRemote(), ffmpeg: newFFmpeg(store.DataDir()), token: hex.EncodeToString(raw), listener: listener, quit: quit, chooseFolder: pickFolder}, nil
}

func (c *Control) Port() int { return c.listener.Addr().(*net.TCPAddr).Port }
func (c *Control) URL() string {
	return "http://127.0.0.1:" + strconv.Itoa(c.Port()) + "/"
}

func (c *Control) Serve() error {
	srv := &http.Server{Handler: c.handler(), ReadHeaderTimeout: 10 * time.Second}
	return srv.Serve(c.listener)
}

func (c *Control) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data:")
		fmt.Fprint(w, strings.ReplaceAll(pageHTML, "{{TOKEN}}", c.token))
	})
	mux.HandleFunc("GET /logo.png", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(logoPNG)
	})
	mux.HandleFunc("GET /qr.png", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("t") != c.token {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		state := c.state()
		if state.Invite == "" {
			http.NotFound(w, r)
			return
		}
		png, err := qrcode.Encode(state.Invite, qrcode.Medium, 512)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "no-store")
		_, _ = w.Write(png)
	})
	mux.HandleFunc("GET /api/state", c.api(func(r *http.Request) (any, error) { return c.state(), nil }))
	mux.HandleFunc("POST /api/choose-folder", c.api(func(r *http.Request) (any, error) {
		path, err := c.chooseFolder()
		if err != nil {
			return nil, err
		}
		if path == "" {
			return c.state(), nil
		}
		return c.setFolder(path)
	}))
	mux.HandleFunc("POST /api/folder", c.api(func(r *http.Request) (any, error) {
		var in struct{ Path string }
		if err := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<16)).Decode(&in); err != nil {
			return nil, errors.New("bad request")
		}
		return c.setFolder(strings.TrimSpace(in.Path))
	}))
	mux.HandleFunc("POST /api/account", c.api(func(r *http.Request) (any, error) {
		var in struct{ Username, Password string }
		if err := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<16)).Decode(&in); err != nil {
			return nil, errors.New("bad request")
		}
		in.Username = strings.TrimSpace(in.Username)
		if err := checkAccount(in.Username, in.Password); err != nil {
			return nil, err
		}
		err := c.server.CreateAccount(r.Context(), in.Username, in.Password)
		if errors.Is(err, errAccountExists) {
			// Made earlier (or in Navidrome's own page): remember that, and tell the listener.
			_ = c.store.Update(func(cfg *Config) { cfg.AccountCreated = true })
			return nil, errors.New("This server already has an account. Use that username and password in Erhu.")
		}
		if err != nil {
			return nil, err
		}
		if err := c.store.Update(func(cfg *Config) { cfg.AccountCreated = true; cfg.Username = in.Username }); err != nil {
			return nil, err
		}
		return c.state(), nil
	}))
	mux.HandleFunc("POST /api/restart", c.api(func(r *http.Request) (any, error) {
		_ = c.server.Start()
		return c.state(), nil
	}))
	mux.HandleFunc("POST /api/autostart", c.api(func(r *http.Request) (any, error) {
		var in struct{ Enabled bool }
		if err := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<16)).Decode(&in); err != nil {
			return nil, errors.New("bad request")
		}
		if err := setAutostart(in.Enabled); err != nil {
			return nil, err
		}
		return c.state(), nil
	}))
	mux.HandleFunc("POST /api/remote", c.api(func(r *http.Request) (any, error) {
		// Enabled starts the setup; Stop only stops the setup's steps; neither turns it off.
		var in struct{ Enabled, Stop bool }
		if err := json.NewDecoder(http.MaxBytesReader(nil, r.Body, 1<<16)).Decode(&in); err != nil {
			return nil, errors.New("bad request")
		}
		switch {
		case in.Enabled:
			c.remote.Start(c.publishPort())
		case in.Stop:
			c.remote.Cancel()
		default:
			c.remote.Cancel()
			if err := c.remote.Disable(r.Context()); err != nil {
				return nil, err
			}
		}
		return c.state(), nil
	}))
	mux.HandleFunc("POST /api/ffmpeg", c.api(func(r *http.Request) (any, error) {
		if err := c.ffmpeg.Install(func() { _ = c.server.Start() }); err != nil {
			return nil, err
		}
		return c.state(), nil
	}))
	mux.HandleFunc("POST /api/quit", c.api(func(r *http.Request) (any, error) {
		go func() { time.Sleep(200 * time.Millisecond); c.quit() }()
		return map[string]bool{"quitting": true}, nil
	}))
	return mux
}

// publishPort is what the away-from-home address forwards to: the web app in Erhu's look (it
// passes the Subsonic API through, so the phone app works through it too), or Navidrome itself
// if that couldn't start.
func (c *Control) publishPort() int {
	if c.playerPort != 0 {
		return c.playerPort
	}
	return c.store.Get().Port
}

func (c *Control) setFolder(path string) (any, error) {
	info, err := os.Stat(path)
	if err != nil || !info.IsDir() {
		return nil, errors.New("That folder can't be opened. Choose a folder that exists.")
	}
	if err := c.store.Update(func(cfg *Config) { cfg.MusicFolder = path }); err != nil {
		return nil, err
	}
	_ = c.server.Start()
	return c.state(), nil
}

func checkAccount(username, password string) error {
	switch {
	case len(username) < 2 || strings.ContainsAny(username, " \t/\\"):
		return errors.New("Choose a username of at least 2 characters, without spaces.")
	case len(password) < 12:
		// Away from home the server is reachable from the internet, so the password matters.
		return errors.New("Choose a password of at least 12 characters.")
	}
	return nil
}

// api wraps a handler: local Host only, the page's token required, JSON in and out.
func (c *Control) api(fn func(*http.Request) (any, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		host, _, err := net.SplitHostPort(r.Host)
		if err != nil || (host != "127.0.0.1" && host != "localhost") || r.Header.Get("X-Erhu-Token") != c.token {
			http.Error(w, `{"error":"forbidden"}`, http.StatusForbidden)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Minute) // the folder picker waits for the person
		defer cancel()
		out, err := fn(r.WithContext(ctx))
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		if err != nil {
			w.WriteHeader(http.StatusBadRequest)
			_ = json.NewEncoder(w).Encode(map[string]string{"error": err.Error()})
			return
		}
		_ = json.NewEncoder(w).Encode(out)
	}
}

// PageState is everything the page shows.
type PageState struct {
	State          State    `json:"state"`
	Problem        string   `json:"problem"`
	MusicFolder    string   `json:"musicFolder"`
	Username       string   `json:"username"`
	AccountCreated bool     `json:"accountCreated"`
	Addresses      []string `json:"addresses"`
	Invite         string   `json:"invite"`
	WebPlayer      string   `json:"webPlayer"`
	// The web player's addresses for other devices on the network.
	WebPlayerOthers []string    `json:"webPlayerOthers,omitempty"`
	Autostart       bool        `json:"autostart"`
	AutostartKnown  bool        `json:"autostartSupported"`
	Remote          RemoteState `json:"remote"`
	FFmpeg          FFmpegState `json:"ffmpeg"`
	Version         string      `json:"version"`
	Name            string      `json:"name"`
}

func (c *Control) state() PageState {
	cfg := c.store.Get()
	state, problem := c.server.Status()
	out := PageState{State: state, Problem: problem, MusicFolder: cfg.MusicFolder, Username: cfg.Username,
		AccountCreated: cfg.AccountCreated, Version: version, Name: computerName(),
		WebPlayer: "http://localhost:" + strconv.Itoa(cfg.Port)}
	if c.playerPort != 0 {
		out.WebPlayer = "http://localhost:" + strconv.Itoa(c.playerPort)
		for _, ip := range lanAddresses() {
			out.WebPlayerOthers = append(out.WebPlayerOthers, serverURL(ip, c.playerPort))
		}
	}
	for _, ip := range lanAddresses() {
		out.Addresses = append(out.Addresses, serverURL(ip, cfg.Port))
	}
	publish := c.publishPort()
	if publish != cfg.Port {
		old := []int{cfg.Port}
		for p := playerPort; p < playerPort+10; p++ {
			old = append(old, p)
		}
		c.remote.SetOldPorts(old...)
	}
	out.Remote = c.remote.State(publish)
	go c.remote.MoveIfNeeded(publish)
	out.FFmpeg = c.ffmpeg.State()
	wanted, step, problem := c.remote.progress()
	if wanted {
		go c.remote.Advance(publish) // the page refreshes every two seconds, which moves the setup on
	}
	out.Remote.SettingUp, out.Remote.Step = wanted, step
	if problem != "" {
		out.Remote.Problem = problem
	}
	if len(out.Addresses) > 0 && state == StateRunning {
		out.Invite = inviteURL(out.Addresses[0], out.Remote.Address, cfg.Username, out.Name)
	}
	out.Autostart, out.AutostartKnown = autostartEnabled()
	return out
}
