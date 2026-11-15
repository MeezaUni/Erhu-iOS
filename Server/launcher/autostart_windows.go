//go:build windows

package main

import (
	"os"

	"golang.org/x/sys/windows/registry"
)

const runKey = `Software\Microsoft\Windows\CurrentVersion\Run`

// autostartEnabled reports whether Erhu Server starts at sign-in (second value: supported here).
func autostartEnabled() (bool, bool) {
	key, err := registry.OpenKey(registry.CURRENT_USER, runKey, registry.QUERY_VALUE)
	if err != nil {
		return false, true
	}
	defer key.Close()
	_, _, err = key.GetStringValue("ErhuServer")
	return err == nil, true
}

func setAutostart(enabled bool) error {
	key, _, err := registry.CreateKey(registry.CURRENT_USER, runKey, registry.SET_VALUE)
	if err != nil {
		return err
	}
	defer key.Close()
	if !enabled {
		if err := key.DeleteValue("ErhuServer"); err != nil && err != registry.ErrNotExist {
			return err
		}
		return nil
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	return key.SetStringValue("ErhuServer", `"`+exe+`" --background`)
}
