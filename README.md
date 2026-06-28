# Helm

A native macOS launcher for terminal sessions and CLI agents.

Helm organizes your work into **projects** and **services** (a service is just a saved command tied to a directory, e.g. `claude` or `npm run dev`). Click one and it opens a real, GPU-rendered terminal — already in the right directory, with the command running. The headline use case is one-click launch of Claude Code and other CLI agents. Think of it as a dashboard of terminals plus a launcher, not a terminal emulator.

## Built with

- **Swift** + **SwiftUI** / **AppKit** — fully native macOS, no web layer
- **[libghostty](https://github.com/Lakr233/libghostty-spm)** (via `libghostty-spm`) — Ghostty's Metal-accelerated terminal engine
- **tmux** — backs the always-on session persistence
- **Xcode** — build & tooling
