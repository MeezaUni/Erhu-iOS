package main

import (
	_ "embed"
	"runtime"
	"time"

	"fyne.io/systray"
)

//go:embed assets/icon.ico
var iconICO []byte

//go:embed assets/icon.png
var iconPNG []byte

// runTray shows the tray (Windows) or menu bar (macOS) icon and blocks until Erhu Server quits.
func runTray(pageURL string, server *Server, quitRequested <-chan struct{}, quit func()) {
	systray.Run(func() {
		if runtime.GOOS == "windows" {
			systray.SetIcon(iconICO)
		} else {
			systray.SetIcon(iconPNG)
		}
		systray.SetTooltip("Erhu Server")
		open := systray.AddMenuItem("Open Erhu Server", "Show the Erhu Server page")
		status := systray.AddMenuItem("Starting…", "")
		status.Disable()
		systray.AddSeparator()
		quitItem := systray.AddMenuItem("Quit Erhu Server", "Stop the music server")
		labels := map[State]string{StateSetup: "Choose your music folder", StateStarting: "Starting…",
			StateRunning: "Running", StateFailed: "Problem: open Erhu Server", StateStopped: "Stopped"}
		go func() {
			ticker := time.NewTicker(2 * time.Second)
			defer ticker.Stop()
			for {
				state, _ := server.Status()
				status.SetTitle(labels[state])
				select {
				case <-open.ClickedCh:
					openBrowser(pageURL)
				case <-quitItem.ClickedCh:
					quit()
				case <-quitRequested:
					systray.Quit()
					return
				case <-ticker.C:
				}
			}
		}()
	}, func() {})
}
