import SwiftUI
import CoreText

// MARK: – Theme
//
// HelmTheme is the single dial for the app's look. Tokens below (colors,
// spacing, radii, typography) are the only place raw style values live — views
// reference these, never literals. Swapping the whole look (the three UI
// directions) is mostly a matter of changing values here.

// MARK: – Typography
//
// One typeface for the whole app: Inter. The Regular/Medium/SemiBold faces are
// bundled (helm/Resources/Fonts) and registered at launch via
// `HelmFont.registerBundledFonts()`, so no Info.plist font declaration is needed.

enum HelmFont {
    /// Body / default UI text: Inter 12. Weight modifiers (`.weight(.medium)`,
    /// `.weight(.semibold)`) resolve to the matching bundled face.
    static let body = Font.custom("Inter", size: 12)
    /// Dense secondary text (service rows, captions): Inter 10.
    static let small = Font.custom("Inter", size: 10)
    /// Section / sheet titles: Inter 16.
    static let title = Font.custom("Inter", size: 16)

    /// Back-compat alias for `body`; prefer `.body` at call sites.
    static let app = body

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

// MARK: – Spacing & radii scales

enum HelmSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 28
    /// Sidebar row vertical inset (kept distinct from the scale for row density).
    static let rowV: CGFloat = 5
}

enum HelmRadius {
    static let sm: CGFloat = 5    // small avatars / chips
    static let md: CGFloat = 6    // sidebar rows
    static let lg: CGFloat = 14   // overlay cards
    static let panel: CGFloat = 22 // sidebar background shape
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

// MARK: – Terminal appearance (ghostty config — not appearance-aware)

enum HelmTheme {
    static let terminalFontSize: Float = 10
    static let terminalPaddingX: Int = 12
    static let terminalPaddingY: Int = 8
}

// MARK: – Color tokens (appearance-aware)

extension Color {
    /// A dynamic color: `light` in Aqua, `dark` in Dark Aqua. Resolves per
    /// rendering context (no `@Environment` needed), so it works inside AppKit
    /// (VisualEffectView) and SwiftUI alike. Keep tokens as `Color` — never
    /// resolve to `CGColor` early, or appearance changes stop tracking.
    static func helmDynamic(light: NSColor, dark: NSColor) -> Color {
        Color(NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    private static func g(_ w: CGFloat) -> NSColor { NSColor(white: w, alpha: 1) }

    // Surfaces
    static let helmBg         = helmDynamic(light: .white,     dark: g(0.07)) // main content surface
    static let helmBgSelected = helmDynamic(light: g(0.87),    dark: g(0.20)) // selected row
    static let helmBgHover    = helmDynamic(light: g(0.91),    dark: g(0.16)) // hovered row

    // Text
    static let helmText          = helmDynamic(light: g(0.12), dark: g(0.88)) // primary
    static let helmTextSecondary = helmDynamic(light: g(0.38), dark: g(0.58)) // service rows
    static let helmTextSelected  = helmDynamic(light: g(0.08), dark: g(0.92)) // selected row text
    static let helmMeta          = helmDynamic(light: g(0.55), dark: g(0.36)) // meta / chevrons
    static let helmIcon          = helmDynamic(light: g(0.44), dark: g(0.46)) // footer icons

    // Accent + scrim
    static let helmAccent = helmDynamic(
        light: NSColor(srgbRed: 0.20, green: 0.51, blue: 0.96, alpha: 1),
        dark:  NSColor(srgbRed: 0.20, green: 0.51, blue: 0.96, alpha: 1))
    static let helmScrim = Color.black.opacity(0.45)

    // Status (semantic — single source for the scattered .green/.yellow/etc.)
    static let helmStatusRunning   = Color.green
    static let helmStatusStarting  = Color.yellow
    static let helmStatusExited    = Color.gray
    static let helmStatusCrashed   = Color.red
    static let helmStatusDetached  = Color.blue
    static let helmStatusAttention = Color.orange

    /// Back-compat alias for `helmBg`; prefer `.helmBg` at call sites.
    static var helmSurface: Color { helmBg }
}
