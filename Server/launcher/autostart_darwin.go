//go:build darwin

package main

import (
	"encoding/xml"
	"os"
	"path/filepath"
	"strings"
)

func agentPath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "LaunchAgents", "org.erhu.server.plist"), nil
}

// autostartEnabled reports whether Erhu Server starts at sign-in (second value: supported here).
func autostartEnabled() (bool, bool) {
	path, err := agentPath()
	if err != nil {
		return false, false
	}
	_, err = os.Stat(path)
	return err == nil, true
}

func setAutostart(enabled bool) error {
	path, err := agentPath()
	if err != nil {
		return err
	}
	if !enabled {
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	var escaped strings.Builder
	_ = xml.EscapeText(&escaped, []byte(exe))
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>org.erhu.server</string>
	<key>ProgramArguments</key>
	<array><string>` + escaped.String() + `</string><string>--background</string></array>
	<key>RunAtLoad</key><true/>
</dict>
</plist>
`
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return os.WriteFile(path, []byte(plist), 0o644)
}
