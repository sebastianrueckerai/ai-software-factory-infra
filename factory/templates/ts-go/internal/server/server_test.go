package server_test

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"[[.Image]]/internal/server"
)

// The app's pages need web/dist built first: bash check runs npm run build
// before go test.
func TestServer(t *testing.T) {
	srv := httptest.NewServer(server.New(server.Config{DataDir: t.TempDir()}))
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
