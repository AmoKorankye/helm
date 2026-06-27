import AppKit

/// Thin wrapper over `NSOpenPanel` for choosing a directory. Behind a helper so
/// the sheets/inspector stay declarative and AppKit-free (HANDOVER §9, dec 11).
enum DirectoryPicker {
    /// Presents a modal directory chooser. Returns the chosen path, or nil if the
    /// user cancelled.
    @MainActor
    static func pickDirectory(startingAt path: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if let path, !path.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}
