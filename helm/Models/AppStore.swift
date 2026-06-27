import Foundation
import SwiftUI
import Combine

@MainActor
final class AppStore: ObservableObject {
    @Published var projects: [Project] = []

    private var configURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Helm", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("projects.json")
    }

    init() {
        load()
        if projects.isEmpty {
            seedDefaults()
        }
    }

    func addProject(_ project: Project) {
        projects.append(project)
        save()
    }

    func deleteProjects(at offsets: IndexSet) {
        projects.remove(atOffsets: offsets)
        save()
    }

    func addService(_ service: Service, to projectID: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[i].services.append(service)
        save()
    }

    func save() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        try? data.write(to: configURL)
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: configURL),
            let decoded = try? JSONDecoder().decode([Project].self, from: data)
        else { return }
        projects = decoded
    }

    private func seedDefaults() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        projects = [
            Project(
                name: "helm",
                directory: "\(home)/Desktop/amokorankye/dev/helm/helm",
                services: [
                    Service(name: "claude", command: "claude"),
                    Service(name: "shell", command: "")
                ]
            )
        ]
        save()
    }
}
