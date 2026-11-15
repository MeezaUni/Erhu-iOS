//go:build !windows && !darwin

package main

import "errors"

// Starting at sign-in is offered on Windows and macOS only.
func autostartEnabled() (bool, bool) { return false, false }

func setAutostart(bool) error {
	return errors.New("starting at sign-in isn't available on this system")
}
