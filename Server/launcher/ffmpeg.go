// Erhu Server: a small launcher that runs Navidrome for the Erhu music player.
// Copyright (C) 2026 the Erhu authors. Licensed under the GNU GPL v3.0; see LICENSE.

package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sync"
	"time"
)

// With ffmpeg, Navidrome can send smaller MP3 copies of songs, which Erhu uses away from home
// (much less to send through the internet connection). Erhu Server finds an ffmpeg that is
// already installed, or installs one with the system's own package manager on request:
// winget on Windows, Homebrew on macOS. Those check what they download themselves.

// FFmpegState is what the page shows.
type FFmpegState struct {
	Found      bool   `json:"found"`
	Path       string `json:"path,omitempty"`
	CanInstall bool   `json:"canInstall"`
	Installing bool   `json:"installing"`
	Problem    string `json:"problem,omitempty"`
}

type FFmpeg struct {
	mu         sync.Mutex
	dataDir    string
	installing bool
	problem    string
	// Replaced in tests.
	lookPath func(string) (string, error)
	run      func(ctx context.Context, name string, args ...string) ([]byte, error)
	exists   func(string) bool
}

func newFFmpeg(dataDir string) *FFmpeg {
	return &FFmpeg{dataDir: dataDir, lookPath: exec.LookPath, run: runCommand,
		exists: func(path string) bool { info, err := os.Stat(path); return err == nil && !info.IsDir() }}
}

func runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	hideWindow(cmd)
	return cmd.CombinedOutput()
}

func exeName(name string) string {
	if runtime.GOOS == "windows" {
		return name + ".exe"
	}
	return name
}

// Path is an ffmpeg Navidrome can use ("" if none is installed).
func (f *FFmpeg) Path() string {
	if path := os.Getenv("ERHU_FFMPEG"); path != "" && f.exists(path) {
		return path
	}
	candidates := []string{filepath.Join(f.dataDir, exeName("ffmpeg"))}
	if path, err := f.lookPath("ffmpeg"); err == nil {
		candidates = append(candidates, path)
	}
	switch runtime.GOOS {
	case "windows":
		if local := os.Getenv("LOCALAPPDATA"); local != "" {
			// Where winget puts the commands it installs (not on the PATH of programs already running).
			candidates = append(candidates, filepath.Join(local, "Microsoft", "WinGet", "Links", "ffmpeg.exe"))
			matches, _ := filepath.Glob(filepath.Join(local, "Microsoft", "WinGet", "Packages", "Gyan.FFmpeg*", "*", "bin", "ffmpeg.exe"))
			candidates = append(candidates, matches...)
		}
	case "darwin":
		candidates = append(candidates, "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg")
	}
	for _, path := range candidates {
		if f.exists(path) {
			return path
		}
	}
	return ""
}

// installer is the command that installs ffmpeg here (nil: none available).
func (f *FFmpeg) installer() []string {
	switch runtime.GOOS {
	case "windows":
		if winget, err := f.lookPath("winget"); err == nil {
			return []string{winget, "install", "--id", "Gyan.FFmpeg.Essentials", "--exact", "--silent",
				"--accept-source-agreements", "--accept-package-agreements"}
		}
	case "darwin":
		for _, brew := range []string{"/opt/homebrew/bin/brew", "/usr/local/bin/brew"} {
			if f.exists(brew) {
				return []string{brew, "install", "ffmpeg"}
			}
		}
	}
	return nil
}

func (f *FFmpeg) State() FFmpegState {
	path := f.Path()
	f.mu.Lock()
	defer f.mu.Unlock()
	return FFmpegState{Found: path != "", Path: path, CanInstall: path == "" && f.installer() != nil,
		Installing: f.installing, Problem: f.problem}
}

// Install installs ffmpeg in the background, then calls done (to restart Navidrome so it uses it).
func (f *FFmpeg) Install(done func()) error {
	command := f.installer()
	if command == nil {
		return errors.New("Erhu Server can't install ffmpeg on this computer. Install it yourself (see the guide), then press Restart server.")
	}
	f.mu.Lock()
	if f.installing {
		f.mu.Unlock()
		return nil
	}
	f.installing, f.problem = true, ""
	f.mu.Unlock()
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Minute)
		defer cancel()
		out, err := f.run(ctx, command[0], command[1:]...)
		f.mu.Lock()
		f.installing = false
		if f.Path() == "" {
			f.problem = "ffmpeg couldn't be installed: " + firstLine(out, errOr(err, "it wasn't found afterwards"))
		}
		f.mu.Unlock()
		if f.Path() != "" {
			done()
		}
	}()
	return nil
}

func errOr(err error, message string) error {
	if err != nil {
		return err
	}
	return errors.New(message)
}
