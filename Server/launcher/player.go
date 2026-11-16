// Erhu Server: a small launcher that runs Navidrome for the Erhu music player.
// Copyright (C) 2026 the Erhu authors. Licensed under the GNU GPL v3.0; see LICENSE.

package main

import (
	_ "embed"
	"fmt"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// The Erhu web player: a page in Erhu's own look that plays the music on this server in a
// browser, on this computer or another one on the same network. It talks to Navidrome through
// the Subsonic API (the same one the iPhone app uses), passed through here so the page and the
// API share one address. It serves only that page, its icon and the API: nothing that changes
// Erhu Server itself.

//go:embed player.html
var playerHTML string

const playerPort = 4535

type Player struct {
	listener net.Listener
	store    *Store
}

func newPlayer(store *Store) (*Player, error) {
	var listener net.Listener
	var err error
	for port := playerPort; port < playerPort+10; port++ {
		if listener, err = net.Listen("tcp", ":"+strconv.Itoa(port)); err == nil {
			break
		}
	}
	if err != nil {
		return nil, err
	}
	return &Player{listener: listener, store: store}, nil
}

func (p *Player) Port() int { return p.listener.Addr().(*net.TCPAddr).Port }

func (p *Player) Serve() error {
	srv := &http.Server{Handler: p.handler(), ReadHeaderTimeout: 10 * time.Second}
	return srv.Serve(p.listener)
}

func (p *Player) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Content-Security-Policy",
			"default-src 'self'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob:; connect-src 'self'")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		fmt.Fprint(w, playerHTML)
	})
	mux.HandleFunc("GET /logo.png", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/png")
		w.Header().Set("Cache-Control", "max-age=86400")
		_, _ = w.Write(logoPNG)
	})
	// The Subsonic API, passed through to Navidrome on this computer.
	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			target := &url.URL{Scheme: "http", Host: "127.0.0.1:" + strconv.Itoa(p.store.Get().Port)}
			r.SetURL(target)
			r.Out.Host = target.Host
		},
		FlushInterval: -1, // stream audio as it comes
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "Erhu Server isn't running the music server right now.", http.StatusBadGateway)
		},
	}
	mux.HandleFunc("/rest/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodPost && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if strings.Contains(r.URL.Path, "..") {
			http.NotFound(w, r)
			return
		}
		proxy.ServeHTTP(w, r)
	})
	return mux
}
