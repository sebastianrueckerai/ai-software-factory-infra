package server

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The app's pages need web/dist built first: bash check runs npm run build
// before go test.
func TestServer(t *testing.T) {
	srv := httptest.NewServer(New(Config{DataDir: t.TempDir()}))
	defer srv.Close()
	for _, c := range []struct{ path, want string }{
		{"/healthz", `{"status":"ok"}`},
		{"/app/", `<div id="root">`},
		{"/app/some/page", `<div id="root">`},
	} {
		res, err := http.Get(srv.URL + c.path)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(res.Body)
		_ = res.Body.Close()
		if res.StatusCode != http.StatusOK || !strings.Contains(string(body), c.want) {
			t.Errorf("GET %s: %d %q, want 200 holding %q", c.path, res.StatusCode, body, c.want)
		}
	}
}

// A stand-in feature file: registers its own route from its own init, as
// routes_health.go does.
func init() {
	register(func(mux *http.ServeMux, _ Deps) {
		mux.HandleFunc("GET /api/ping", func(w http.ResponseWriter, _ *http.Request) {
			writeJSON(w, http.StatusOK, map[string]bool{"pong": true})
		})
	})
}

// round2-design.md section 8: a feature's init registers its routes with
// register; New wires them alongside /healthz and the /api/ catch-all.
func TestFeatureRoutesRegisterThemselves(t *testing.T) {
	srv := httptest.NewServer(New(Config{DataDir: t.TempDir()}))
	defer srv.Close()
	for _, c := range []struct {
		path string
		want int
		body string
	}{
		{"/api/ping", http.StatusOK, `{"pong":true}`},
		{"/healthz", http.StatusOK, `{"status":"ok"}`},
		{"/api/nope", http.StatusNotFound, `{"error":"not found"}`},
	} {
		res, err := http.Get(srv.URL + c.path)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(res.Body)
		_ = res.Body.Close()
		if res.StatusCode != c.want || strings.TrimSpace(string(body)) != c.body {
			t.Errorf("GET %s: %d %q, want %d %q", c.path, res.StatusCode, body, c.want, c.body)
		}
	}
}
