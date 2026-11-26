# The base images are the factory store's copies, by their linux/amd64
# digests; the build logs in with the job's token.
ARG UPSTREAM=git.aisoftwarefactory.world/upstream/
# pin docker.io/library/node:24-bookworm-slim
FROM ${UPSTREAM}docker.io/library/node:24-bookworm-slim@sha256:e0e989b967dacc279681ed81774b2ce9eeebbb0efb8e0c427573235bebf1eda1 AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --ignore-scripts
COPY web/ ./
RUN npm run build

# pin docker.io/library/golang:1.25-bookworm
FROM ${UPSTREAM}docker.io/library/golang:1.25-bookworm@sha256:c268a04d59aea0b180ed9946a658cfab9e7b3391dc90eed6e4969ccff98c851f AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
COPY --from=web /src/web/dist ./web/dist
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server

# pin docker.io/library/debian
FROM ${UPSTREAM}docker.io/library/debian:bookworm-slim@sha256:311f7a192fd9a92b165a86b32fa3aae9005b11849bfb1db2d4fd784559ee464f
RUN groupadd --system --gid 65532 app && useradd --system --uid 65532 --gid app app && mkdir -p /data && chown app:app /data
ENV DATA_DIR=/data
COPY --from=build /out/server /usr/local/bin/server
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/server"]
