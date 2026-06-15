import Foundation
import Combine

/// Observable bridge between the background monitor and SwiftUI. Updated on the
/// main queue after each snapshot.
final class MonitorState: ObservableObject {
    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var recommendations: [Recommendation] = []

    var pressure: PressureLevel { snapshot?.pressure ?? .normal }

    func update(snapshot: Snapshot, recommendations: [Recommendation]) {
        self.snapshot = snapshot
        self.recommendations = recommendations
    }
}
