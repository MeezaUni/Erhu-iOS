// Erhu Server: a small launcher that runs Navidrome for the Erhu music player.
// Copyright (C) 2026 the Erhu authors. Licensed under the GNU GPL v3.0; see LICENSE.

package main

import (
	"bytes"
	_ "embed"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"path"
	"strconv"
	"strings"
	"time"
)

// The web app: Navidrome's own web interface, with everything it does, dressed in Erhu's look.
// Every request is passed through to Navidrome on this computer; its page gets Erhu's theme
// (colours, shapes, the Erhu name and icon) added on the way. The Subsonic API passes through
// unchanged, so the away-from-home address can point here and the phone app works through it.

//go:embed theme.css
var themeCSS []byte

//go:embed theme.js
var themeJS []byte

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

// themeTags go at the end of the page's head, after Navidrome's own styles, so they win.
const themeTags = `<link rel="stylesheet" href="/erhu/theme.css"><script src="/erhu/theme.js" defer></script>` +
	`<link rel="icon" type="image/png" href="/erhu/logo.png"><meta name="theme-color" content="#0E0F12">`

// isPage tells the requests that may answer with Navidrome's page (no file extension, or
// .html): those are fetched uncompressed so the theme can be added.
func isPage(p string) bool {
	if strings.HasPrefix(p, "/rest/") || strings.HasPrefix(p, "/api/") || strings.HasPrefix(p, "/auth/") {
		return false
	}
	ext := path.Ext(p)
	return ext == "" || ext == ".html"
}

// withTheme adds the theme to a Navidrome page.
func withTheme(page []byte) []byte {
	page = bytes.Replace(page, []byte("<title>Navidrome</title>"), []byte("<title>Erhu</title>"), 1)
	page = bytes.Replace(page, []byte(`content="#ffffff"`), []byte(`content="#0E0F12"`), 1)
	if i := bytes.LastIndex(page, []byte("</head>")); i >= 0 {
		return append(page[:i:i], append([]byte(themeTags), page[i:]...)...)
	}
	return page
}

func plainTransport() http.RoundTripper {
	t := http.DefaultTransport.(*http.Transport).Clone()
	t.DisableCompression = true
	return t
}

func (p *Player) handler() http.Handler {
	mux := http.NewServeMux()
	static := func(body []byte, kind string) http.HandlerFunc {
		return func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", kind)
			w.Header().Set("Cache-Control", "max-age=3600")
			w.Header().Set("X-Content-Type-Options", "nosniff")
			_, _ = w.Write(body)
		}
	}
	mux.HandleFunc("GET /erhu/theme.css", static(themeCSS, "text/css; charset=utf-8"))
	mux.HandleFunc("GET /erhu/theme.js", static(themeJS, "text/javascript; charset=utf-8"))
	mux.HandleFunc("GET /erhu/logo.png", static(logoPNG, "image/png"))
	// Navidrome's icons (the browser tab, the home screen) become Erhu's.
	for _, icon := range []string{"favicon-16x16.png", "favicon-32x32.png", "apple-touch-icon.png",
		"android-chrome-192x192.png", "android-chrome-512x512.png"} {
		mux.HandleFunc("GET /app/"+icon, static(logoPNG, "image/png"))
	}

	proxy := &httputil.ReverseProxy{
		Rewrite: func(r *httputil.ProxyRequest) {
			target := &url.URL{Scheme: "http", Host: "127.0.0.1:" + strconv.Itoa(p.store.Get().Port)}
			r.SetURL(target)
			r.SetXForwarded()
			r.Out.Host = r.In.Host
			if isPage(r.In.URL.Path) {
				r.Out.Header.Del("Accept-Encoding")
			}
		},
		// Compression is whatever the browser asked for; pages are fetched plain (see isPage).
		Transport:     plainTransport(),
		FlushInterval: -1, // stream audio and Navidrome's live updates as they come
		ModifyResponse: func(res *http.Response) error {
			if !strings.HasPrefix(res.Header.Get("Content-Type"), "text/html") || res.Header.Get("Content-Encoding") != "" {
				return nil
			}
			page, err := io.ReadAll(io.LimitReader(res.Body, 4<<20))
			res.Body.Close()
			if err != nil {
				return err
			}
			page = withTheme(page)
			res.Body = io.NopCloser(bytes.NewReader(page))
			res.ContentLength = int64(len(page))
			res.Header.Set("Content-Length", strconv.Itoa(len(page)))
			res.Header.Del("ETag")
			res.Header.Set("Cache-Control", "no-cache")
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, r *http.Request, err error) {
			http.Error(w, "Erhu Server isn't running the music server right now.", http.StatusBadGateway)
		},
	}
	mux.Handle("/", proxy)
	return mux
}
