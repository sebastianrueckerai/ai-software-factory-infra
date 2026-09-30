# [[.Name]]

A TypeScript single-page frontend and a Go API, built into one image. The
factory seeded this repository from its template `ts-go` with a minimal app
that builds, passes its checks and deploys to staging as it is. Its CI
(`.forgejo/`) is fixed: agents cannot change `.forgejo/`, so keep to these
conventions; a change that breaks them turns the checks red, and no merge
happens without green checks.

## Before you end

Run `bash check`, the repository's checks, which CI runs too. When it
passes, commit and end. `check` is yours: extend it when the app needs
more checked, never remove what it runs (the pull request checks go red
when it no longer names `gosec` and `go test -race`).

## Layout

- The Go module is at the root: `go.mod`, module `[[.Image]]`. It carries
  `ignore ./web/node_modules` (the directive Go 1.25 has), because
  `go vet ./...`, gosec and `go test ./...` would otherwise walk
  `web/node_modules`, where some npm packages ship `.go` files.
- `internal/server.New(server.Config)` returns the app's `http.Handler`:
  `/healthz`, the API under `/api/`, the single-page app under `/app/`, and
  `/` redirecting to `/app/`. Tests start it with `httptest.NewServer`;
  `cmd/server` serves it on 8080 and reads `DATA_DIR`.
- `web/dist` is embedded with `//go:embed all:dist` in package `web`
  (`web/embed.go`). `web/dist/.gitkeep` is committed so the embed compiles
  before a build; `npm run build` puts it back after Vite empties `dist`.
  The Go tests of `/app/` need the web build first, as `check` runs it.
- `web/` is a Vite, React and TypeScript app with the scripts `lint`
  (`tsc --noEmit`), `test` (vitest) and `build`, and `package-lock.json`
  committed. Install with `npm ci --ignore-scripts`: no install script runs.
  `src/App.tsx` exports the routes; `src/test/render.tsx` has
  `renderAt(path)`, which renders them in a memory router, and
  `src/test/fetch.ts` has `mockFetch`, which answers each fetch by method
  and path (204 and 304 with no body).
- Migrations are named `<UTC yyyymmddhhmmss>_<slug>.sql`, the time the file
  was written, slug `[a-z0-9_]+`, never by the next number. The checks
  refuse a new `.sql` file under any `migrations/` directory named
  otherwise.
- Acceptance tests live in `acceptance/`: plain Go tests over `httptest`
  and `server.New`, run by `go test ./...`.
- The `Dockerfile` at the root builds `web` in a Node stage and the Go
  binary in a Go stage, and runs it as uid 65532 on 8080. Its base images
  are pinned by digest already; CI pins the app image by digest when it
  rolls.
- `deploy/base/` holds the workload: a Deployment (one replica, `strategy:
  Recreate` for the ReadWriteOnce data volume at `/data`, `/tmp` writable,
  probes on `/healthz`), the `data` claim and a Service on 8080. It already
  meets the namespace's Pod Security (restricted) and names the pull
  secret `forgejo-registry`: change it only for what the app needs.
  `deploy/staging/` sets the namespace and the image digest, which only
  CI's roll commits change.

## What the checks run

Pull requests (`.forgejo/workflows/pr.yml`): `bash check`, that `check`
still runs `gosec` and `go test -race`, then the names of added migrations, and with a `Dockerfile` the image build. Deleting
`check` or the `Dockerfile` once they exist on main turns the checks red.
On `main` (`.forgejo/workflows/ci.yml`) `bash check` runs again, the image
is pushed by digest, staging rolls and the run waits until staging's pod
runs that digest; with `deploy/prod/kustomization.yaml` prod follows after
15 minutes on staging without an alert.
