package main

import (
	"flag"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strconv"
	"sync"
	"syscall"
	"time"

	"github.com/ncruces/zenity"
)

// version is set at build time (-ldflags "-X main.version=...").
var version = "dev"

func main() {
	background := flag.Bool("background", false, "start without opening the Erhu Server page (used when starting at sign-in)")
	noTray := flag.Bool("no-tray", false, "run without a tray / menu bar icon (press Ctrl-C to quit)")
	showVersion := flag.Bool("version", false, "print the version and exit")
	flag.Parse()
	if *showVersion {
		fmt.Println("Erhu Server", version)
		return
	}

	// One launcher at a time: if another is running, show its page and leave.
	if url := runningControlURL(); url != "" {
		openBrowser(url)
		return
	}

	store, err := openStore()
	if err != nil {
		fatal("Erhu Server can't use its settings folder: " + err.Error())
	}
	server := newServer(store)

	var once sync.Once
	quitRequested := make(chan struct{})
	quit := func() { once.Do(func() { close(quitRequested) }) }

	control, err := newControl(store, server, quit)
	if err != nil {
		fatal("Erhu Server can't open its page: " + err.Error())
	}
	go func() { _ = control.Serve() }()
	// The Erhu web player (another browser tab, or another device on the network).
	if player, err := newPlayer(store); err == nil {
		control.playerPort = player.Port()
		go func() { _ = player.Serve() }()
	}

	if store.Get().MusicFolder != "" {
		_ = server.Start()
	}
	control.cloudflare.Start() // a Cloudflare tunnel set up earlier runs with the server
	if !*background {
		openBrowser(control.URL())
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	go func() { <-signals; quit() }()

	shutdown := func() { control.cloudflare.Stop(); server.Stop() }
	if *noTray {
		fmt.Println("Erhu Server page:", control.URL())
		<-quitRequested
		shutdown()
		return
	}
	runTray(control.URL(), server, quitRequested, quit) // returns when quitting
	shutdown()
}

// runningControlURL finds an Erhu Server that is already running on this computer.
func runningControlURL() string {
	client := http.Client{Timeout: 500 * time.Millisecond}
	for port := controlPort; port < controlPort+10; port++ {
		url := "http://127.0.0.1:" + strconv.Itoa(port) + "/"
		resp, err := client.Get(url + "logo.png")
		if err != nil {
			continue
		}
		resp.Body.Close()
		if resp.StatusCode == http.StatusOK && resp.Header.Get("Content-Type") == "image/png" {
			return url
		}
	}
	return ""
}

func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", url)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		cmd = exec.Command("xdg-open", url)
	}
	hideWindow(cmd)
	_ = cmd.Start()
}

// pickFolder shows the system's folder picker. "" means the person cancelled.
func pickFolder() (string, error) {
	path, err := zenity.SelectFile(zenity.Title("Choose your music folder"), zenity.Directory())
	if err == zenity.ErrCanceled {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("the folder picker could not be shown (%v). Use “Type a path instead”", err)
	}
	return path, nil
}

func fatal(message string) {
	fmt.Fprintln(os.Stderr, message)
	_ = zenity.Error(message, zenity.Title("Erhu Server"))
	os.Exit(1)
}
