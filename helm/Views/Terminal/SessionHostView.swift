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

        // (1) Add a hosted view for any session we aren't yet hosting.
        for (key, session) in manager.sessions where coord.hosted[key] == nil {
            let view = TerminalView(frame: container.bounds)
            view.autoresizingMask = [.width, .height]
            // Replicate the library representable's wiring order exactly:
            // delegate (the TerminalViewState) → controller → configuration.
            view.delegate = session.viewState
            view.controller = session.viewState.controller
            view.configuration = session.viewState.configuration
            view.isHidden = true
            view.setSurfaceVisible(false)
            container.addSubview(view)
            coord.hosted[key] = view
        }

        // (2) Remove hosted views whose session is gone.
        for (key, view) in coord.hosted where manager.sessions[key] == nil {
            view.setSurfaceVisible(false)
            view.removeFromSuperview()
            coord.hosted[key] = nil
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
    }
}
