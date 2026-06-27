import Foundation

struct Project: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var directory: String
    var services: [Service]
}

struct Service: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var command: String
    var autoStart = false
}
