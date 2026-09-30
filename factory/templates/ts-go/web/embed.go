// Package web embeds the built single-page app.
package web

import "embed"

// Dist is web/dist: the Vite build, or only .gitkeep before a build.
//
//go:embed all:dist
var Dist embed.FS
