import SwiftUI
import AppKit

/// Bridges `NSVisualEffectView` so SwiftUI views can use a real macOS vibrancy
/// material (e.g. the `.sidebar` blur) rather than an approximated `Material`.
/// `.behindWindow` blends with whatever is behind the *window* — the classic
/// translucent-sidebar look.
///
/// IMPORTANT: behind-window vibrancy only reveals the blurred desktop if the
/// host window is NON-opaque. SwiftUI windows are opaque by default, which makes
/// the material render as a flat fill (no visible blur), so we mark the window
/// non-opaque with a clear background. The detail area stays solid because
/// `ContentView` paints its own opaque background behind the terminal.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blendingMode
        // The window isn't attached during makeNSView; configure it once it is.
        DispatchQueue.main.async {
            guard let window = view.window, window.isOpaque else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }
}
