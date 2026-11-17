// Erhu Server: a small launcher that runs Navidrome for the Erhu music player.
// Copyright (C) 2026 the Erhu authors. Licensed under the GNU GPL v3.0; see LICENSE.

package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
)

// Config is what the listener chose: where the music is and which account they made.
// The password is never stored here; Navidrome keeps it.
type Config struct {
	MusicFolder    string `json:"musicFolder"`
	Port           int    `json:"port"`
	Username       string `json:"username"`
	AccountCreated bool   `json:"accountCreated"`
	// Cloudflare Tunnel: the address on the listener's domain, and the tunnel's id.
	CloudflareHost   string `json:"cloudflareHost,omitempty"`
	CloudflareTunnel string `json:"cloudflareTunnel,omitempty"`
}

const defaultPort = 4533

// Store loads and saves the config file and knows the launcher's folders.
type Store struct {
	mu   sync.Mutex
	home string
	cfg  Config
}

// homeDir is the launcher's folder: ERHU_SERVER_HOME if set (tests, portable use), otherwise
// the per-user config folder (%AppData%\ErhuServer, ~/Library/Application Support/ErhuServer).
func homeDir() (string, error) {
	if dir := os.Getenv("ERHU_SERVER_HOME"); dir != "" {
		return dir, nil
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(base, "ErhuServer"), nil
}

func openStore() (*Store, error) {
	home, err := homeDir()
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Join(home, "data"), 0o700); err != nil {
		return nil, err
	}
	s := &Store{home: home, cfg: Config{Port: defaultPort}}
	data, err := os.ReadFile(s.path())
	if err == nil {
		// A damaged file falls back to defaults rather than stopping the launcher.
		_ = json.Unmarshal(data, &s.cfg)
	}
	if s.cfg.Port < 1 || s.cfg.Port > 65535 {
		s.cfg.Port = defaultPort
	}
	return s, nil
}

func (s *Store) path() string    { return filepath.Join(s.home, "config.json") }
func (s *Store) DataDir() string { return filepath.Join(s.home, "data") }
func (s *Store) LogPath() string { return filepath.Join(s.home, "navidrome.log") }
func (s *Store) PidPath() string { return filepath.Join(s.home, "navidrome.pid") }

func (s *Store) Get() Config {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.cfg
}

// Update changes the config and saves it (written to a temporary file first, then renamed,
// so a crash never leaves half a file).
func (s *Store) Update(change func(*Config)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	change(&s.cfg)
	data, err := json.MarshalIndent(s.cfg, "", "  ")
	if err != nil {
		return err
	}
	tmp := s.path() + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, s.path())
}
