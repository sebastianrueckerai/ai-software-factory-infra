// Package server is the app's HTTP handler; tests start it with New.
package server

import (
	"encoding/json"
	"io/fs"
	"net/http"
	"strings"

	"[[.Image]]/web"
)

// Config is what the handler is built with.
type Config struct {
	// DataDir is where the app keeps its data (DATA_DIR, the data volume).
	DataDir string
}

// New serves /healthz, the API under /api/ and the single-page app under
// /app/; / redirects to /app/.
func New(cfg Config) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	})
	mux.HandleFunc("/api/", func(w http.ResponseWriter, _ *http.Request) {
		writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
	})
	mux.Handle("/app/", http.StripPrefix("/app", app()))
	mux.Handle("GET /{$}", http.RedirectHandler("/app/", http.StatusFound))
	return mux
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

// app serves web/dist, and index.html for every path that is not a file:
// the client-side router owns those.
func app() http.Handler {
	dist, err := fs.Sub(web.Dist, "dist")
	if err != nil {
		panic(err)
	}
	files := http.FileServerFS(dist)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if st, err := fs.Stat(dist, strings.TrimPrefix(r.URL.Path, "/")); err != nil || st.IsDir() {
			r.URL.Path = "/"
		}
		files.ServeHTTP(w, r)
	})
}
