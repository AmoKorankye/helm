# Helm — Project Handover

_Last updated: 2026-06-27_

---

## 1. What Helm is

**Helm is a native macOS app that manages and launches terminal sessions** — a personal,
lightweight alternative to [Solo](https://soloterm.com/) and [Unpeel](https://unpeel.com/).

It is **not** a terminal-based (TUI) tool. It is a **GUI desktop application** with a sidebar
that organizes *projects* and *services*. Each service is a saved command (e.g. `claude`,
`npm run dev`) tied to a directory. Clicking a service opens a real, GPU-rendered terminal
inside the app, already in the right directory, with the command running. The headline use
case is **launching Claude Code (and other CLI agents) from saved presets with one click.**

Think: a dashboard of terminals + a launcher, not "a terminal emulator."

---

## 2. Why we're building it

The user lives in terminal-based editor/workspace tools and has tried the main options:

| Tool | Verdict |
|------|---------|
| **Solo** (soloterm.com) | Best tool tried, ~10x productivity. But the free tier caps at **20 processes**, and it's **heavy on battery** (M1 Pro) because it's built on **Tauri** — a Rust backend with a **WebKit WebView UI** (confirmed by inspecting `/Applications/Solo.app`: contains `Tauri IPC`, `__TAURI_INTERNALS__`, `src/ops/processes.rs`, links `WebKit.framework`). It markets as "native, not Electron," but the UI is still a web app. |
| **Unpeel** (unpeel.com) | The right idea, genuinely native (Swift + AppKit + Metal + libghostty), but **$59/yr** — out of budget. User won't pay a subscription for a terminal. |
| **cmux** | Disliked — "just a terminal wrapped in an app," not enough functionality. |

**Goal:** build a personal combination of Solo + Unpeel that is **maximally native and
battery-efficient**, with no service caps and no subscription. Battery efficiency is the
**top hard constraint** (M1 Pro daily driver).

---

## 3. Who's building it

AI engineer, 4+ yrs Python/ML, 2 yrs TypeScript/React/Rust/Vite. **New to Swift**, learning it
via AI-assisted development for this project. React experience transfers well to SwiftUI's
declarative model. This is a **personal tool** — no cross-platform, team, or App Store needs.

---

## 4. Tech stack & key decisions

| Decision | Choice | Why |
|----------|--------|-----|
| Platform | **macOS only** (not multiplatform) | Every feature is desktop-specific (PTYs, process mgmt, worktrees). Multiplatform template forces a lowest-common-denominator subset and blocks full AppKit. |
| UI | **SwiftUI + AppKit** | Truly native, no web layer = best battery. Beats Tauri/Solo at its core. |
| Language | **Swift** | The only path to fully-native macOS. SwiftUI ≈ React mentally. |
| Terminal engine | **libghostty** via [`libghostty-spm`](https://github.com/Lakr233/libghostty-spm) (products: `GhosttyTerminal`, `GhosttyTheme`) | Ghostty's renderer — fastest, GPU/Metal, what Unpeel uses. Chosen over SwiftTerm for performance, accepting a steeper integration. The SPM package ships a **prebuilt xcframework** — no C/Zig bridging needed; pure Swift API (`TerminalSurfaceView`, `TerminalViewState`, `TerminalController`, `TerminalSurfaceOptions`). |
| Session persistence (future) | Likely **tmux-backed** (Mori's approach) over a custom PTY daemon (Forge's approach) | Far simpler than writing our own daemon; processes survive app close. |

**Reference apps studied** (all open-source, SwiftUI + libghostty):
[Forge](https://github.com/rsml/forge) (closest — multiplexer for CLI agents, custom PTY daemon),
[Mori](https://github.com/vaayne/mori) (project/worktree model over tmux),
[macterm](https://github.com/thdxg/macterm), [Muxy](https://github.com/muxy-app/muxy).

---

## 5. Where we are now — Phase 1 COMPLETE ✅

A working app that builds and runs:

- Window with a **sidebar** listing projects, each with its services.
- Clicking a service opens a **real libghostty terminal** in the detail pane.
- The terminal **spawns directly in the project directory** and **runs the service command
  natively** (no typing simulation).
- **Claude Code launches with one click** and works. A plain `shell` service (empty command)
  gives a normal shell. **This proves Helm's entire core thesis.**

### File structure (`helm/helm/helm/`)
```
helmApp.swift                     App entry. WindowGroup, hidden title bar, 1280x800.
ContentView.swift                 NavigationSplitView (sidebar + detail) + WelcomeView.
Models/
  Project.swift                   Project { name, directory, [Service] }; Service { name, command, autoStart }. Codable.
  AppStore.swift                  @MainActor ObservableObject. CRUD + JSON persistence.
Views/
  Sidebar/SidebarView.swift       Sidebar list, sections per project, ServiceRow.
  Terminal/HelmTerminalPane.swift The terminal view. Sets native cwd + native command.
```

### Persistence
Projects/services are saved as JSON at
`~/Library/Application Support/Helm/projects.json`.
On first launch `AppStore` seeds one default project (the Helm repo itself) with `claude`
and `shell` services.

---

## 6. Hard-won technical learnings (don't re-discover these)

1. **App Sandbox MUST be off.** Xcode's macOS app template sets `ENABLE_APP_SANDBOX = YES`,
   which makes `exec`/`/usr/bin/login`/PTY spawning fail with `error.PermissionDenied`.
   Set `ENABLE_APP_SANDBOX = NO` (both Debug + Release in `project.pbxproj`). Fine for a
   personal, non-App-Store tool.

2. **Launch commands natively, never by simulating keystrokes.**
   `TerminalViewState.send()` → `ghostty_surface_text()` is **paste-style** and respects
   bracketed-paste mode, so a trailing `\r`/`\n` lands as a literal newline in zsh's edit
   buffer instead of executing (symptom: command typed but needs manual backspace+enter).
   There is **no public "press Return key" API**. Instead we set the command as the surface's
   process via ghostty config: `TerminalConfiguration().custom("command", "/bin/zsh -lic \"<cmd>\"")`.

3. **Wrap the command in a login + interactive shell** (`zsh -lic "<cmd>"`) so it inherits the
   user's full PATH (homebrew `/opt/homebrew/bin`, node, etc.). Running the bare command would
   miss homebrew PATH and fail with "command not found".

4. **Native working directory:** `TerminalSurfaceOptions(workingDirectory:)` feeds
   ghostty's `config.working_directory` — spawn in the right dir without typing `cd`.

5. **Per-pane isolation:** each `TerminalViewState` creates its own `TerminalController` +
   ghostty app, so per-service `command`/cwd config doesn't leak between terminals.

6. **Known benign log noise:** `ghostty terminfo not found, using xterm-256color`
   (falls back fine — claude/vim/htop all work) and `Publishing changes from within view
   updates` (library publishing state during initial layout). Neither blocks anything.
   Terminfo fidelity is a Phase 7 polish item.

7. **Consequence of native launch:** when the service process exits (e.g. you quit Claude),
   the surface shows "process exited" rather than dropping to a shell — it matches the
   "service" model. Switching to land-in-a-shell-after is a small tweak if wanted.

---

## 7. Roadmap

| Phase | Scope | Status |
|-------|-------|--------|
| **1 — Foundation** | Xcode project, libghostty embedded, one working terminal, launch claude | ✅ Done |
| **1.5 — Session decoupling** | Extract `SessionManager`/`TerminalSession`; retire `@StateObject`+`.id()` terminal ownership; AppKit host container so sessions survive switching. **Critical path — gates all later phases.** | ⬜ Next |
| **2 — Projects & Services** | Add/edit/delete projects & services in-app (currently seed-only), config UI | ⬜ |
| **3 — Process management** | Start/stop/restart, status indicators (running/stopped/crashed), auto-restart, log view | ⬜ |
| **4 — Worktrees** | Auto-detect git worktrees, launch services per worktree | ⬜ |
| **5 — Agent layer** | Parse Claude output for working/waiting state, show in sidebar, quick-launch presets | ⬜ |
| **6 — Always-on** | Sessions survive app close (tmux-backed), menu-bar pulse, notifications | ⬜ |
| **7 — Polish** | Split panes, command palette (⌘K), themes (GhosttyTheme — 485 schemes), keybindings, terminfo fidelity | ⬜ |

Phases 1–3 = usable daily driver. 4–6 = better than Solo/Unpeel. 7 = beautiful.

---

## 8. Immediate next steps (Phase 1.5 — must land before Phase 2)

The Phase 1 terminal is owned by the SwiftUI view (`@StateObject` in `HelmTerminalPane` +
`.id(service.id)` in `ContentView`), so **switching services destroys the PTY/process**.
This blocks process management, worktrees, and always-on. Phase 1.5 decouples the
terminal/process lifetime from the view lifetime. Then Phase 2 (CRUD) builds on the new seam.

1. **`SessionManager`** (`@MainActor ObservableObject`) owns `[SessionKey: TerminalSession]`,
   injected at app root. Detail pane calls `session(for:)` (create-or-return), never builds a
   terminal itself.
2. **`TerminalSession`** — reference type wrapping the long-lived `TerminalViewState` + Helm
   metadata (key, status, startedAt, exit info). The library consumes state as
   `@ObservedObject`, so an external owner is the intended pattern.
3. **`SessionHostView`** (`NSViewRepresentable`) — retains all live surface `NSView`s and
   toggles `isHidden` to show the selected one (card-stack), so GPU surface + scrollback +
   focus survive a switch. Measure that hidden surfaces idle their Metal loop; LRU-evict to
   `.detached` if not.
4. Rewrite `ContentView`/`HelmTerminalPane` to consume the above; **delete the `.id()`**.
5. **Verify:** launch `claude`, switch to another service and back — the session must still be
   running (not a fresh shell).

Then Phase 2: add/edit/delete project & service via sheets + inspector, `NSOpenPanel` picker,
validation in a draft model.

---

## 9. Architecture decisions (Phases 1.5–6) — settled 2026-06-27

Decided via a grilling session + Software/Backend Architect review (both read libghostty 1.3.1
source). Constraints honored: battery is the #1 hard constraint (→ zero-poll everywhere),
macOS-only, sandbox off, Rust only if a non-Swift layer is truly needed.

**Validated crux:** `TerminalSurfaceView` takes its state as `@ObservedObject`, not
`@StateObject`. The library *wants* an external owner. Today's `@StateObject` + `.id()` is
fighting it and tearing down PTYs on every service switch.

| # | Decision |
|---|----------|
| 1 | **Phase 1.5 decoupling lands before Phase 2** — CRUD redefines selection/identity; building it on the PTY-killing model means writing it twice. Critical path. |
| 2 | **`SessionManager` owns sessions**, injected at root; detail pane only *displays* a manager-owned `TerminalSession`. Sessions die only on explicit close/stop. |
| 3 | **Offscreen survival via AppKit host container** retaining surfaces with `isHidden` (card-stack). |
| 4 | **Composite `SessionKey`** = `serviceID` + instance token (`.primary` now; `.worktree(branch)` Phase 4). Tmux-safe slug `helm-<project>-<service>[-<worktree>]`. Makes Phase 4 additive, not a rewrite. |
| 5 | **Domain model stays Codable+JSON, grown additively** (all new fields defaulted): `environment`, `shell?` (nil = global `zsh -lic` default), `sortOrder`, `icon`, `colorHex`, `restartPolicy`, `persistent`, `worktreeEnabled`. Runtime state (status/pid/exit/agent-state) is **never persisted** — lives on `TerminalSession`. |
| 6 | **Six deep modules:** `SessionManager`, `TerminalSession`, `ProcessSupervisor` (Ph3 — *decides* restart, doesn't spawn), `PersistenceStore` (split out of `AppStore`), `WorktreeService` (Ph4), `AgentStateDetector` (Ph5). **All libghostty coupling sealed behind SessionManager/TerminalSession** — no other file imports `GhosttyTerminal`. |
| 7 | **Status is zero-poll** — `enum SessionStatus { starting, running, exited(code), crashed(code), detached }` driven by **kqueue `EVFILT_PROC`/`NOTE_EXIT` on the PTY child pid** + `waitpid` for the code. No timers, no read loops, no `git status` polling. |
| 8 | **libghostty pid:** 1.3.1 does **not** expose the child pid, and its `COMMAND_FINISHED` exit path is OSC/shell-integration-driven (won't fire for `claude` via `zsh -lic`); `SHOW_CHILD_EXITED` is unbridged. → **Carry a small C-shim/patch to libghostty-spm** to expose the child pid + bridge `SHOW_CHILD_EXITED`. (Phase 3.) |
| 9 | **On process exit:** show a **Helm restart affordance** (overlay + one-click restart), matching the service-dashboard model. |
| 10 | **Shell config:** **global default (`zsh -lic`) + per-service env vars**; `shell?` field present-but-defaulted for the rare override. |
| 11 | **Phase 2 CRUD:** modal **sheets** to create, **inspector** to edit, `NSOpenPanel` dir picker behind a helper, validation in a draft/form model (Views stay dumb). |
| 12 | **Rust scope:** Phases 2–5 are **pure Swift** (libghostty already owns PTY/spawn/cwd/env). Rust is a **deferred Phase 6+ contingency** only — a tiny *observer* status-sidecar (Unix socket + length-prefixed JSON), never the PTY owner. |
| 13 | **Phase 6 persistence = tmux-first** (Mori model): `tmux new-session -A -s helm-<key>` for idempotent attach/reattach; status via control-mode (`-CC`); logs via `pipe-pane` → file + `EVFILT_VNODE` tail. Accept a `brew install tmux` dependency w/ graceful degradation (tmux is **not** currently installed). Rust daemon only if a tmux spike fails. **Persistence is opt-in per service.** |

**Corrected build order:** `1.5 → 2 → 3 (+pid patch) → 4 → 5 → 6 (tmux)`.

---

## 10. How to build/run

- Open `helm/helm/helm.xcodeproj` in **Xcode** (full Xcode required, not just CLT;
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`).
- `⌘R` to run. CLI build check:
  `xcodebuild -project helm.xcodeproj -scheme helm -configuration Debug build`.
- Package dependency is already resolved (`libghostty-spm`, pinned in `Package.resolved`).
  Runtime libghostty is **1.3.1**.
- Bundle id: `com.amokorankye.helm`. Repo root: `~/Desktop/amokorankye/dev/helm/helm/`
  (git repo lives here; sources in the nested `helm/` folder).
