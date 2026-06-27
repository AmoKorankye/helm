import SwiftUI
import GhosttyTerminal

struct HelmTerminalPane: View {
    let project: Project
    let service: Service

    @StateObject private var viewState: TerminalViewState
    @FocusState private var terminalFocused: Bool

    init(project: Project, service: Service) {
        self.project = project
        self.service = service

        var config = TerminalConfiguration()
        if !service.command.isEmpty {
            // Launch the command as the surface's process via ghostty's native
            // `command` config — no keystroke simulation. Wrap it in a login +
            // interactive zsh so it inherits the user's full PATH (homebrew,
            // node, etc.), exactly as if typed by hand.
            let wrapped = "/bin/zsh -lic \"\(service.command)\""
            config = config.custom("command", wrapped)
        }

        let state = TerminalViewState(
            configSource: .none,
            theme: .default,
            terminalConfiguration: config
        )
        // Spawn directly in the project directory (native ghostty cwd).
        state.configuration = TerminalSurfaceOptions(workingDirectory: project.directory)
        _viewState = StateObject(wrappedValue: state)
    }

    var body: some View {
        TerminalSurfaceView(context: viewState)
            .terminalFocused($terminalFocused)
            .onAppear { terminalFocused = true }
    }
}
