import SwiftUI
import CoreText

// MARK: – Typography
//
// One typeface for the whole app: Inter at 12pt. The Regular/Medium/SemiBold
// faces are bundled (helm/Resources/Fonts) and registered at launch via
// `HelmFont.registerBundledFonts()`, so no Info.plist font declaration is needed.

enum HelmFont {
    /// The single app typeface: Inter, 12pt. Weight modifiers (`.weight(.medium)`,
    /// `.weight(.semibold)`) resolve to the matching bundled face.
    static let app = Font.custom("Inter", size: 12)

    /// Registers the bundled Inter faces with CoreText (process scope) so
    /// `Font.custom("Inter", …)` resolves. Safe to call once at launch.
    static func registerBundledFonts() {
        let faces = ["Inter-Regular", "Inter-Medium", "Inter-SemiBold"]
        let urls = faces.compactMap { name in
            Bundle.main.url(forResource: name, withExtension: "ttf")
                ?? Bundle.main.url(forResource: name, withExtension: "ttf", subdirectory: "Fonts")
        }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }
}

// MARK: – Layout constants

enum HelmLayout {
    static let listFadeHeight: CGFloat = 22

    // Sidebar row leading columns — shared by the project row and service row so a
    // service name lines up exactly under its project name. A service's leading
    // block (chevron column + icon column + their gaps) equals the project's.
    static let rowChevronColumn: CGFloat = 12
    static let rowChevronGap: CGFloat = 6
    static let rowIconColumn: CGFloat = 20
    static let rowIconGap: CGFloat = 8
}

// MARK: – Adaptive solid background

extension Color {
    // White in light mode, near-black in dark mode – for the main content area.
    static var helmSurface: Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.07, alpha: 1)
                : .white
        })
    }
}
