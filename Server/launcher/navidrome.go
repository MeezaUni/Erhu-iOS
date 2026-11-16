package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Navidrome is run as a separate, unmodified program. This file starts and stops it, watches
// it, and creates the first account through its own API.

type State string

const (
	StateSetup    State = "setup"    // no music folder chosen yet
	StateStarting State = "starting" // launched, not answering yet
	StateRunning  State = "running"
	StateFailed   State = "failed"
	StateStopped  State = "stopped"
)

type Server struct {
	store *Store

	mu      sync.Mutex
	cmd     *exec.Cmd
	state   State
	problem string
	gen     int // increases on every start/stop, so an old process's exit is ignored
}

func newServer(store *Store) *Server {
	s := &Server{store: store, state: StateStopped}
	if store.Get().MusicFolder == "" {
		s.state = StateSetup
	}
	return s
}

func (s *Server) Status() (State, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.state, s.problem
}

// navidromePath finds the Navidrome program shipped next to the launcher.
func navidromePath() (string, error) {
	name := "navidrome"
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	var dirs []string
	if custom := os.Getenv("ERHU_NAVIDROME"); custom != "" {
		return custom, nil
	}
	if exe, err := os.Executable(); err == nil {
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		dirs = append(dirs, filepath.Dir(exe))
	}
	if wd, err := os.Getwd(); err == nil {
		dirs = append(dirs, wd)
	}
	for _, dir := range dirs {
		candidate := filepath.Join(dir, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate, nil
		}
	}
	return "", fmt.Errorf("%s was not found next to Erhu Server. Download Erhu Server again and keep its files together", name)
}

// Start launches Navidrome with the saved settings. It returns once the process has started;
// Status changes to running when the server answers.
func (s *Server) Start() error {
	cfg := s.store.Get()
	if cfg.MusicFolder == "" {
		s.set(StateSetup, "")
		return errors.New("choose your music folder first")
	}
	if info, err := os.Stat(cfg.MusicFolder); err != nil || !info.IsDir() {
		s.set(StateFailed, "The music folder "+cfg.MusicFolder+" can't be opened. Choose it again.")
		return errors.New("music folder missing")
	}
	bin, err := navidromePath()
	if err != nil {
		s.set(StateFailed, err.Error())
		return err
	}
	s.Stop()
	killLeftover(s.store.PidPath())
	if !portFree(cfg.Port) {
		msg := fmt.Sprintf("Port %d is already used by another program on this computer. Close it (another music server?) and press Restart.", cfg.Port)
		s.set(StateFailed, msg)
		return errors.New(msg)
	}

	logFile, err := openLog(s.store.LogPath())
	if err != nil {
		s.set(StateFailed, "Can't write the log file: "+err.Error())
		return err
	}
	cmd := exec.Command(bin)
	cmd.Dir = s.store.DataDir()
	cmd.Env = append(os.Environ(),
		"ND_MUSICFOLDER="+cfg.MusicFolder,
		"ND_DATAFOLDER="+s.store.DataDir(),
		"ND_PORT="+strconv.Itoa(cfg.Port),
		"ND_ADDRESS=0.0.0.0",
		// No usage statistics to the Navidrome project, and no public share links.
		"ND_ENABLEINSIGHTSCOLLECTOR=false",
		"ND_ENABLESHARING=false",
		"ND_ENABLEDOWNLOADS=true",
		"ND_SCANNER_ENABLED=true",
		"ND_SCANNER_SCANONSTARTUP=true",
		"ND_LOGLEVEL=info",
		// Erhu Server's web app restyles Navidrome's dark look.
		"ND_DEFAULTTHEME=Dark",
		// Keep more of the smaller copies made for streaming away from home (Navidrome's default
		// is 100MB), so a song played or seeked in again comes from the cache instead of being
		// converted again. Same copies, same quality; about 1GB of disk at most.
		"ND_TRANSCODINGCACHESIZE=1GB",
	)
	// With ffmpeg, Navidrome can send smaller MP3 copies (Erhu uses them away from home).
	if ffmpeg := newFFmpeg(s.store.DataDir()).Path(); ffmpeg != "" {
		cmd.Env = append(cmd.Env, "ND_FFMPEGPATH="+ffmpeg)
	}
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	hideWindow(cmd)
	if err := cmd.Start(); err != nil {
		logFile.Close()
		s.set(StateFailed, "Navidrome could not be started: "+err.Error())
		return err
	}
	_ = os.WriteFile(s.store.PidPath(), []byte(strconv.Itoa(cmd.Process.Pid)), 0o600)

	s.mu.Lock()
	s.gen++
	gen := s.gen
	s.cmd = cmd
	s.state = StateStarting
	s.problem = ""
	s.mu.Unlock()

	go func() { // the process ended
		err := cmd.Wait()
		logFile.Close()
		s.mu.Lock()
		defer s.mu.Unlock()
		if s.gen != gen {
			return // stopped or restarted on purpose
		}
		s.cmd = nil
		s.state = StateFailed
		s.problem = "Navidrome stopped unexpectedly"
		if err != nil {
			s.problem += " (" + err.Error() + ")"
		}
		if tail := lastLogLines(s.store.LogPath(), 3); tail != "" {
			s.problem += ": " + tail
		}
	}()
	go func() { // wait until it answers
		deadline := time.Now().Add(60 * time.Second)
		for time.Now().Before(deadline) {
			if s.generation() != gen {
				return
			}
			if answers(cfg.Port) {
				s.mu.Lock()
				if s.gen == gen && s.state == StateStarting {
					s.state = StateRunning
				}
				s.mu.Unlock()
				return
			}
			time.Sleep(300 * time.Millisecond)
		}
		s.mu.Lock()
		if s.gen == gen && s.state == StateStarting {
			s.state = StateFailed
			s.problem = "Navidrome started but is not answering. See the log file " + s.store.LogPath()
		}
		s.mu.Unlock()
	}()
	return nil
}

// Stop ends Navidrome and waits (briefly) for it to go.
func (s *Server) Stop() {
	s.mu.Lock()
	cmd := s.cmd
	s.cmd = nil
	s.gen++
	if s.state != StateSetup {
		s.state = StateStopped
	}
	s.problem = ""
	s.mu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return
	}
	terminate(cmd.Process)
	done := make(chan struct{})
	go func() { _, _ = cmd.Process.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
	}
	_ = os.Remove(s.store.PidPath())
}

func (s *Server) set(state State, problem string) {
	s.mu.Lock()
	s.state, s.problem = state, problem
	s.mu.Unlock()
}

func (s *Server) generation() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.gen
}

// answers reports whether something speaks HTTP on the port (Navidrome answers /ping).
func answers(port int) bool {
	client := http.Client{Timeout: 2 * time.Second}
	resp, err := client.Get(fmt.Sprintf("http://127.0.0.1:%d/ping", port))
	if err != nil {
		return false
	}
	resp.Body.Close()
	return true
}

var errAccountExists = errors.New("an account already exists on this server")

// CreateAccount makes the first (administrator) account through Navidrome's own API, which
// only allows it while the server has no users.
func (s *Server) CreateAccount(ctx context.Context, username, password string) error {
	if state, _ := s.Status(); state != StateRunning {
		return errors.New("the server is not running yet")
	}
	body, _ := json.Marshal(map[string]string{"username": username, "password": password})
	url := fmt.Sprintf("http://127.0.0.1:%d/auth/createAdmin", s.store.Get().Port)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	text, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	switch {
	case resp.StatusCode == http.StatusForbidden:
		return errAccountExists
	case resp.StatusCode >= 300:
		return fmt.Errorf("the server refused to create the account (HTTP %d): %s", resp.StatusCode, strings.TrimSpace(string(text)))
	}
	return nil
}

// openLog starts a fresh log, keeping the previous one as .old.
func openLog(path string) (*os.File, error) {
	if info, err := os.Stat(path); err == nil && info.Size() > 0 {
		_ = os.Rename(path, path+".old")
	}
	return os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
}

func lastLogLines(path string, n int) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	text := strings.Join(lines, " | ")
	if len(text) > 600 {
		text = text[len(text)-600:]
	}
	return text
}

// killLeftover ends a Navidrome left running by a launcher that crashed, so the port is free.
func killLeftover(pidPath string) {
	data, err := os.ReadFile(pidPath)
	if err != nil {
		return
	}
	_ = os.Remove(pidPath)
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 {
		return
	}
	if proc, err := os.FindProcess(pid); err == nil && looksLikeNavidrome(pid) {
		_ = proc.Kill()
		time.Sleep(500 * time.Millisecond)
	}
}
