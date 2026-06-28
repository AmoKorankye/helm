import Foundation
import Combine

/// The single source of truth for the project/service domain model. Renamed and
/// grown out of the retired `AppStore`: persistence is delegated to
/// `PersistenceStore`, and mutations return the `SessionKey`s of any sessions
/// that must be torn down so the *caller* (ContentView) can coordinate with
/// `SessionManager`.
///
/// Boundary (HANDOVER §9, decision 6): this file does NOT import GhosttyTerminal
/// and does NOT know `SessionManager` exists. It only deals in pure value types
/// (`SessionKey` is a GhosttyTerminal-free value type).
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [Project] = []

    private let persistence: PersistenceStore

    init(persistence: PersistenceStore = PersistenceStore()) {
        self.persistence = persistence
        projects = (try? persistence.load()) ?? []
        // No seeded defaults: a fresh install starts with an empty sidebar.
    }

    // MARK: - Project mutations

    func addProject(_ project: Project) {
        var project = project
        project.sortOrder = (projects.map(\.sortOrder).max() ?? -1) + 1
        projects.append(project)
        persist()
    }

    func updateProject(_ project: Project) {
        guard let i = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[i] = project
        persist()
    }

    /// Removes a project and reports the serviceIDs it contained, so the caller
    /// (ContentView) can enumerate the live session keys via `SessionManager` and
    /// close them. The store cannot know runtime worktree instances, so it returns
    /// serviceIDs and stays git/GhosttyTerminal-free (grill B1).
    @discardableResult
    func deleteProject(id: UUID) -> [UUID] {
        guard let i = projects.firstIndex(where: { $0.id == id }) else { return [] }
        let ids = projects[i].services.map(\.id)
        projects.remove(at: i)
        persist()
        return ids
    }

    func moveProjects(from offsets: IndexSet, to destination: Int) {
        var ordered = projects.sorted { $0.sortOrder < $1.sortOrder }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        for (idx, project) in ordered.enumerated() {
            if let i = projects.firstIndex(where: { $0.id == project.id }) {
                projects[i].sortOrder = idx
            }
        }
        persist()
    }

    // MARK: - Service mutations

    func addService(_ service: Service, to projectID: UUID) {
        guard let i = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var service = service
        service.sortOrder = (projects[i].services.map(\.sortOrder).max() ?? -1) + 1
        projects[i].services.append(service)
        persist()
    }

    func updateService(_ service: Service, in projectID: UUID) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        guard let si = projects[pi].services.firstIndex(where: { $0.id == service.id }) else { return }
        projects[pi].services[si] = service
        persist()
    }

    @discardableResult
    func deleteService(id serviceID: UUID, from projectID: UUID) -> [UUID] {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return [] }
        guard let si = projects[pi].services.firstIndex(where: { $0.id == serviceID }) else { return [] }
        projects[pi].services.remove(at: si)
        persist()
        return [serviceID]
    }

    func moveServices(in projectID: UUID, from offsets: IndexSet, to destination: Int) {
        guard let pi = projects.firstIndex(where: { $0.id == projectID }) else { return }
        var ordered = projects[pi].services.sorted { $0.sortOrder < $1.sortOrder }
        ordered.move(fromOffsets: offsets, toOffset: destination)
        for idx in ordered.indices {
            ordered[idx].sortOrder = idx
        }
        projects[pi].services = ordered
        persist()
    }

    // MARK: - Lookups

    func project(id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first { $0.id == id }
    }

    func service(id: UUID?) -> (service: Service, project: Project)? {
        guard let id else { return nil }
        for project in projects {
            if let service = project.services.first(where: { $0.id == id }) {
                return (service, project)
            }
        }
        return nil
    }

    /// Decide-time restart-policy lookup for `ProcessSupervisor` (m5): always read
    /// the *current* saved policy so live inspector edits take effect on the next
    /// exit without restarting. GhosttyTerminal-free; pure value lookup. Returns
    /// `.never` if the service was deleted out from under a pending exit event.
    func restartPolicy(forServiceID serviceID: UUID) -> RestartPolicy {
        service(id: serviceID)?.service.restartPolicy ?? .never
    }

    // MARK: - Internals

    private func persist() {
        try? persistence.save(projects)
    }
}
