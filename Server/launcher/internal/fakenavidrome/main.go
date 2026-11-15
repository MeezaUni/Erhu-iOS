// A stand-in for Navidrome used only by the launcher's tests: it answers /ping and implements
// the first-account rule of /auth/createAdmin (allowed once, then 403). It is never shipped.
package main

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
)

func main() {
	marker := filepath.Join(os.Getenv("ND_DATAFOLDER"), "fake-user")
	if _, err := os.Stat(os.Getenv("ND_MUSICFOLDER")); err != nil {
		os.Stderr.WriteString("music folder missing\n")
		os.Exit(2)
	}
	http.HandleFunc("/ping", func(w http.ResponseWriter, r *http.Request) { _, _ = w.Write([]byte(".")) })
	http.HandleFunc("/auth/createAdmin", func(w http.ResponseWriter, r *http.Request) {
		var in struct{ Username, Password string }
		if json.NewDecoder(r.Body).Decode(&in) != nil || in.Username == "" || in.Password == "" {
			http.Error(w, "bad", http.StatusUnprocessableEntity)
			return
		}
		if _, err := os.Stat(marker); err == nil {
			http.Error(w, "Cannot create another first admin", http.StatusForbidden)
			return
		}
		_ = os.WriteFile(marker, []byte(in.Username), 0o600)
		_, _ = w.Write([]byte(`{"username":"` + in.Username + `"}`))
	})
	_ = http.ListenAndServe(os.Getenv("ND_ADDRESS")+":"+os.Getenv("ND_PORT"), nil)
}
