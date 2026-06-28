import SwiftUI

// MARK: – Typography
//
// Google Sans (UI chrome) + Geist Mono (content labels).
//
// To install the fonts:
//   1. Download GoogleSans-Medium.ttf from google/fonts (or AOSP)
//      and GeistMono-Light.ttf / GeistMono-Bold.ttf from vercel/geist-font.
//   2. Drag all three .ttf files into the helm target in Xcode (Add to target: helm ✓).
//   3. In Info.plist add "Fonts provided by application" with the three filenames.
//
// Until the fonts are installed SwiftUI silently falls back to the system font,
// so the app continues to build and run without them.

enum HelmFont {
    // Structural UI (section headers, toolbar labels, sheet titles): Google Sans 12pt
    static var ui: Font { .custom("GoogleSans-Medium", size: 12, relativeTo: .caption) }

    // Content text (service names, project names, commands): Geist Mono 10pt
    static var mono: Font     { .custom("GeistMono-Light", size: 10, relativeTo: .caption2) }
    static var monoBold: Font { .custom("GeistMono-Bold",  size: 10, relativeTo: .caption2) }
}

extension View {
    // Applies Geist Mono with the specified line-spacing and letter-spacing.
    func helmMono(bold: Bool = false) -> some View {
        self
            .font(bold ? HelmFont.monoBold : HelmFont.mono)
            .lineSpacing(2)      // 1.2 × 10pt → +2pt additional gap
            .tracking(1.0)
    }
}

// MARK: – Layout constants

enum HelmLayout {
    static let listFadeHeight: CGFloat = 22
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
