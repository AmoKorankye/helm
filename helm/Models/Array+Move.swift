import Foundation

extension Array {
    /// Foundation-only reimplementation of SwiftUI's `Array.move(fromOffsets:toOffset:)`
    /// so the model layer needn't import SwiftUI (keeps it view-free). Matches
    /// SwiftUI's semantics: `toOffset` is an index in the *original* array (the
    /// position the moved block is inserted before).
    mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moved = source.map { self[$0] }
        // Remove from the back so earlier indices stay valid.
        for index in source.sorted(by: >) {
            remove(at: index)
        }
        // Adjust the insertion point for elements removed before it.
        let removedBefore = source.filter { $0 < destination }.count
        insert(contentsOf: moved, at: destination - removedBefore)
    }
}
