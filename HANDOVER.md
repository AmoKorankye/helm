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
| **2 — Projects & Services** | Add/edit/delete projects & services in-app (currently seed-only), config UI | ⬜ Next |
| **3 — Process management** | Start/stop/restart, status indicators (running/stopped/crashed), auto-restart, log view | ⬜ |
| **4 — Worktrees** | Auto-detect git worktrees, launch services per worktree | ⬜ |
| **5 — Agent layer** | Parse Claude output for working/waiting state, show in sidebar, quick-launch presets | ⬜ |
| **6 — Always-on** | Sessions survive app close (tmux-backed), menu-bar pulse, notifications | ⬜ |
| **7 — Polish** | Split panes, command palette (⌘K), themes (GhosttyTheme — 485 schemes), keybindings, terminfo fidelity | ⬜ |

Phases 1–3 = usable daily driver. 4–6 = better than Solo/Unpeel. 7 = beautiful.

---

## 8. Immediate next steps (Phase 2)

1. **Add-project / add-service UI** — sheets/forms (the `+` button in `SidebarView` is a
   stub). Directory picker via `NSOpenPanel`. Persist through `AppStore`.
2. **Edit & delete** for projects and services (context menus / swipe).
3. **Polish the sidebar** — selection state, icons, maybe per-service status dot placeholder
   (wired up for real in Phase 3).

---

## 9. How to build/run

- Open `helm/helm/helm.xcodeproj` in **Xcode** (full Xcode required, not just CLT;
  `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`).
- `⌘R` to run. CLI build check:
  `xcodebuild -project helm.xcodeproj -scheme helm -configuration Debug build`.
- Package dependency is already resolved (`libghostty-spm`, pinned in `Package.resolved`).
  Runtime libghostty is **1.3.1**.
- Bundle id: `com.amokorankye.helm`. Repo root: `~/Desktop/amokorankye/dev/helm/helm/`
  (git repo lives here; sources in the nested `helm/` folder).
