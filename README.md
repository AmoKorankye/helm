# Helm

> A native macOS launcher for your terminal sessions and CLI agents.

Helm is a SwiftUI + AppKit desktop app that organizes your work into **projects** and
**services**, then launches each one into a real, GPU-rendered terminal — already in the
right directory, with the command already running. The headline use case is **one-click
launch of Claude Code and other CLI agents** from saved presets.

Think of it as a **dashboard of terminals plus a launcher** — not a terminal emulator.

---

## What it is

A service is just a saved command tied to a directory (e.g. `claude` in `~/dev/app`, or
`npm run dev` in `~/dev/api`). A sidebar groups services under their projects. Click one and
Helm opens a [libghostty](https://github.com/Lakr233/libghostty-spm) terminal — the same
Metal-accelerated engine Ghostty uses — spawned natively in that directory with the command
running. No `cd`, no typing, no keystroke simulation.

Sessions are decoupled from the UI: they're owned by a session manager and stay alive when
you switch between services, so a long-running agent keeps working in the background while
you look at something else.

## Why

Helm is a personal, battery-efficient answer to tools the author already uses and likes but
couldn't keep using:

| Tool | The catch |
|------|-----------|
| **[Solo](https://soloterm.com/)** | Excellent, but the free tier caps at 20 processes, and the Tauri/WebKit web UI is heavy on battery on Apple Silicon. |
| **[Unpeel](https://unpeel.com/)** | The right idea and genuinely native, but a paid subscription. |

Helm's goal is the overlap: **maximally native, no web layer, no process caps, no
subscription.** There is no Electron, Tauri, or embedded browser anywhere in it — battery
efficiency on Apple Silicon is the top design constraint. It's pure Swift; no Rust needed.

## Features

All of the following are implemented and on `main`:

- **One-click launch** of saved services into native libghostty (GPU / Metal) terminals,
  spawned in the right directory with the command already running.
- **Decoupled, long-lived sessions** — terminals survive switching between services; they're
  owned by a session manager, not the view.
- **In-app project & service management** — add, edit, delete, and reorder projects and
  services, with a directory picker. No config files to hand-edit.
- **Per-service process control** — start / stop / restart from hover controls on each row,
  live status dots, and optional auto-restart policies (`never` / `onCrash` / `always`, with
  exponential backoff).
- **Git worktree fan-out** — a service can run per-worktree, turning one service into N
  concurrent sessions, one per worktree branch.
- **Agent layer** — an agent-state badge (attention / working / done) for CLI agents like
  Claude Code, plus quick-launch presets.
- **Always-on persistence** (opt-in per service, tmux-backed) — persistent services survive
  app close and reattach on relaunch, with a menu-bar item, local notifications, and a
  per-session log panel.

## Requirements

| | |
|---|---|
| **OS** | macOS (Apple Silicon friendly; built and run on an M1 Pro daily driver) |
| **To build** | Full **Xcode** — the Command Line Tools alone are not enough |
| **For persistence** | **tmux** (`brew install tmux`) — only needed for the always-on feature; Helm degrades gracefully when it's absent |

This is a personal app: it is **not** distributed on the App Store, and the App Sandbox is
intentionally **off** (required to spawn PTYs and child processes).

## Build & run

```bash
# Point xcode-select at full Xcode if needed:
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Open the project in Xcode and run:

```bash
open helm.xcodeproj   # then press ⌘R
```

Or build from the command line:

```bash
xcodebuild -project helm.xcodeproj -scheme helm -configuration Debug build
```

The libghostty dependency (`libghostty-spm`) is already resolved and pinned in
`Package.resolved`; the runtime libghostty version is **1.3.1**. Bundle id:
`com.amokorankye.helm`.

## Tests

```bash
xcodebuild test -project helm.xcodeproj -scheme helm -destination 'platform=macOS'
```

35 tests in the `helmTests` target cover `TmuxLauncher` quoting, the `JSONFileStore`,
git-worktree porcelain parsing, `SessionKey.slug` injectivity, and the `AnsiStripper`.

## Architecture

The core model is **project → service → session**:

- **Project / Service** — the persisted domain model (`Codable`, stored as JSON under
  `~/Library/Application Support/Helm/`). New fields are always added defaulted and decoded
  with `decodeIfPresent` so older files keep loading. Runtime state (status, exit info,
  agent state) is never persisted — it lives on the session.
- **`SessionManager` / `TerminalSession`** — own the live terminals, keyed by a composite
  `SessionKey` (service + instance, e.g. `.primary` or `.worktree(branch)`). The detail pane
  only *displays* a manager-owned session via create-or-return; it never builds a terminal
  itself. **All libghostty coupling is sealed behind these session files** — no other part of
  the app imports `GhosttyTerminal`.
- **`SessionHostView`** — an AppKit container that retains every live surface `NSView` and
  toggles visibility (a card-stack), so the GPU surface, scrollback, and focus survive a
  service switch.

Around that core sit a handful of deep, single-purpose modules:

- **`ProcessSupervisor`** — *decides* whether to auto-restart on exit; it doesn't spawn.
- **`WorktreeService`** — detects git worktrees and drives the per-worktree fan-out.
- **`AgentStateDetector`** — derives agent state from ghostty signals (bell/notification while
  unfocused → attention, exit → done, OSC progress → working).
- **`TmuxService` / `TmuxLauncher`** — back the opt-in persistence feature with a dedicated
  `tmux -L helm` server.
- **`JSONFileStore` / `PersistenceStore`** — the storage seam for projects, presets, and the
  tmux session index.

A deliberate theme throughout is **zero-poll, event-driven status**: liveness comes from
ghostty's `terminalDidClose` callback (and tmux's `pane-died` hook via a file-tail for
persistent sessions) rather than timers or read loops — again, in service of battery life.

## Status & roadmap

**Phases 1–6 are complete** — Helm is functionally done as a daily driver:

| Phase | Scope | Status |
|-------|-------|--------|
| 1 — Foundation | One working libghostty terminal; launch Claude Code | ✅ |
| 1.5 — Session decoupling | Long-lived, view-independent sessions | ✅ |
| 2 — Projects & Services | In-app CRUD and config | ✅ |
| 3 — Process management | Start/stop/restart, status, auto-restart | ✅ |
| 4 — Worktrees | Per-worktree fan-out | ✅ |
| 5 — Agent layer | Agent-state badge + quick-launch presets | ✅ |
| 6 — Always-on | tmux-backed persistence, menu bar, notifications, logs | ✅ |
| 7 — Polish | Split panes, command palette, themes, keybindings | ⬜ Deferred |

**Phase 7 (UI polish)** is intentionally deferred. The UI is functional but not yet refined,
so there are no screenshots here yet — they'll come with the frontend pass.

### Limitations

- macOS-only, not sandboxed, and not on the App Store — by design, for a personal tool.
- Persistent (tmux-backed) agent sessions lose live progress and desktop-notification signals
  through tmux; only bell, title, and exit survive. This is a known tmux limitation.

## A note on this project

Helm is a personal project built for one developer's daily workflow. There's no LICENSE file
and no support guarantee — it's shared in the spirit of "here's how I solved this." Feel free
to read, learn from, or adapt it.
