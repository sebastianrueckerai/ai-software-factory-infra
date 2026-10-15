# The base images are the factory store's copies, by their linux/amd64
# digests; the build logs in with the job's token.
ARG UPSTREAM=git.aisoftwarefactory.world/upstream/
FROM ${UPSTREAM}docker.io/library/node:24-bookworm-slim@sha256:5cbc7caba8c2c0f0bca675d1b61b9f2857e1cf1853c6164ee9dd409501a936e7 AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --ignore-scripts
COPY web/ ./
RUN npm run build

FROM ${UPSTREAM}docker.io/library/golang:1.25-bookworm@sha256:c268a04d59aea0b180ed9946a658cfab9e7b3391dc90eed6e4969ccff98c851f AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
COPY --from=web /src/web/dist ./web/dist
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/server ./cmd/server

FROM ${UPSTREAM}docker.io/library/debian:bookworm-slim@sha256:f3034a6ec3c1205360777c4aae76234998866ad18806ae62b63a3f84ccad782b
RUN groupadd --system --gid 65532 app && useradd --system --uid 65532 --gid app app && mkdir -p /data && chown app:app /data
ENV DATA_DIR=/data
COPY --from=build /out/server /usr/local/bin/server
USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/server"]
