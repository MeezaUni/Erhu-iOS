//go:build !windows

package main

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

func hideWindow(cmd *exec.Cmd) {}

func terminate(p *os.Process) { _ = p.Signal(syscall.SIGTERM) }

// looksLikeNavidrome checks the process name, so a recycled process id is never killed.
func looksLikeNavidrome(pid int) bool {
	out, err := exec.Command("ps", "-p", strconv.Itoa(pid), "-o", "comm=").Output()
	return err == nil && strings.Contains(strings.ToLower(string(out)), "navidrome")
}
