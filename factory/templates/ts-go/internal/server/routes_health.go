package server

import "net/http"

func init() {
	register(func(mux *http.ServeMux, _ Deps) {
		mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
			writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
		})
	})
}
