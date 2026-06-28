import SwiftUI
import AppKit
import GhosttyTerminal

/// AppKit host container that retains every live terminal surface and shows the
/// selected one (a "card stack"). Offscreen surfaces survive a service switch —
/// the GPU surface, scrollback, and focus are all preserved — because the
/// `TerminalView`s stay in the view hierarchy, merely hidden (HANDOVER §9,
/// decision 3).
///
/// CRITICAL (battery — the #1 constraint, HANDOVER §2): `isHidden = true` alone
/// does NOT idle the Metal render loop while the view is in-window. We must call
/// `setSurfaceVisible(false)` on offscreen panes to stop the display link, and
/// `setSurfaceVisible(true)` on the visible one.
struct SessionHostView: NSViewRepresentable {
    @ObservedObject var manager: SessionManager
    let selectedKey: SessionKey?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let coord = context.coordinator

        // (1) Add a hosted view for any session we aren't yet hosting, AND rebuild
        //     the slot when a session was REPLACED under the same key (restart =
        //     rebuild-in-place, grill M1: a surface can't be reused, so the new
        //     session carries a brand-new `viewState`). We detect replacement by
        //     comparing the identity of the `viewState` the hosted view was built
        //     from; a mismatch means remove-old + add-new, never skip.
        for (key, session) in manager.sessions {
            // A user-stopped session asks us to free its surface so ghostty closes
            // the PTY master and SIGHUPs the whole foreground job tree — but the
            // session STAYS in the dict (no respawn). Drop our strong ref to its
            // hosted view; deallocating the view tears down its ghostty surface
            // (coordinator deinit → `ghostty_surface_free`). We do NOT re-host it;
            // the RestartOverlay covers the empty area until Restart rebuilds.
            if session.surfaceShouldClose {
                if let dead = coord.hosted[key] {
                    dead.setSurfaceVisible(false)
                    dead.removeFromSuperview()
                    coord.hosted[key] = nil
                    coord.hostedStateID[key] = nil
                }
                continue
            }
            let currentStateID = ObjectIdentifier(session.viewState)
            if coord.hosted[key] != nil, coord.hostedStateID[key] == currentStateID {
                continue   // already hosting the current surface; nothing to do.
            }
            // Tear down a stale surface for this key (rebuild case).
            if let old = coord.hosted[key] {
                old.setSurfaceVisible(false)
                old.removeFromSuperview()
            }
            let view = TerminalView(frame: container.bounds)
            view.autoresizingMask = [.width, .height]
            // Replicate the library representable's wiring order exactly:
            // delegate → controller → configuration. Phase 5 (§6/M1): the delegate
            // is the session's forwarding shim, NOT the raw viewState — it forwards
            // every stock call to viewState (so all @Published state stays
            // populated) AND captures OSC 9;4 progress the stock object drops.
            view.delegate = session.hostDelegate
            view.controller = session.viewState.controller
            view.configuration = session.viewState.configuration
            view.isHidden = true
            view.setSurfaceVisible(false)
            container.addSubview(view)
            coord.hosted[key] = view
            coord.hostedStateID[key] = currentStateID
        }

        // (2) Remove hosted views whose session is gone.
        for (key, view) in coord.hosted where manager.sessions[key] == nil {
            view.setSurfaceVisible(false)
            view.removeFromSuperview()
            coord.hosted[key] = nil
            coord.hostedStateID[key] = nil
        }

        // (3) Toggle visibility + render loop; the selected surface is shown and
        //     rendering, every other is hidden and idled.
        for (key, view) in coord.hosted {
            let isSelected = key == selectedKey
            view.isHidden = !isSelected
            view.setSurfaceVisible(isSelected)
            view.frame = container.bounds
        }

        // (4) Focus lands in the visible terminal once it's in a window.
        if let selectedKey, let view = coord.hosted[selectedKey], view.window != nil {
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                if window.firstResponder !== view {
                    window.makeFirstResponder(view)
                }
            }
        }
    }

    /// Holds strong refs to the hosted surfaces — that's what keeps offscreen
    /// sessions (and their PTYs/processes) alive across a switch.
    @MainActor
    final class Coordinator {
        weak var container: NSView?
        var hosted: [SessionKey: TerminalView] = [:]
        /// Identity of the `viewState` each hosted view was built from, so a
        /// restart (same key, new `viewState`) is detected as remove+add (§4.2).
        var hostedStateID: [SessionKey: ObjectIdentifier] = [:]
    }
}
