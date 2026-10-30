import ActivityKit
import Foundation

/// The Live Activity for a test call. Compiled into the app and the widget extension.
struct ProbeCallAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var startedAt: Date
    }

    var line: String
}
