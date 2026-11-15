//go:build windows

package main

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

// hideWindow keeps Navidrome's console window from appearing.
func hideWindow(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: 0x08000000} // CREATE_NO_WINDOW
}

func terminate(p *os.Process) { _ = p.Kill() }

// looksLikeNavidrome checks the process name, so a recycled process id is never killed.
func looksLikeNavidrome(pid int) bool {
	cmd := exec.Command("tasklist", "/FI", "PID eq "+strconv.Itoa(pid), "/FO", "CSV", "/NH")
	hideWindow(cmd)
	out, err := cmd.Output()
	return err == nil && strings.Contains(strings.ToLower(string(out)), "navidrome")
}
