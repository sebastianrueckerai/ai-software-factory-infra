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

// Deps is what every route gets; the foundation adds the store and the
// logged-in user to it.
type Deps struct {
	Config Config
}

// route registers its handlers on mux, reading what it needs from d.
type route func(mux *http.ServeMux, d Deps)

var routes []route

// register adds r to what New wires. Call it from a feature's own file's
// init: never add a route in New or in another feature's file.
func register(r route) {
	routes = append(routes, r)
}

// New serves every registered route (routes_health.go's /healthz among
// them), a 404 for the rest of /api/, the single-page app under /app/,
// and / redirecting to /app/.
func New(cfg Config) http.Handler {
	mux, d := http.NewServeMux(), Deps{Config: cfg}
	for _, r := range routes {
		r(mux, d)
	}
	mux.HandleFunc("/api/", notFound) // more specific patterns win
	mux.Handle("/app/", http.StripPrefix("/app", app()))
	mux.Handle("GET /{$}", http.RedirectHandler("/app/", http.StatusFound))
	return mux
}

func notFound(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusNotFound, map[string]string{"error": "not found"})
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
