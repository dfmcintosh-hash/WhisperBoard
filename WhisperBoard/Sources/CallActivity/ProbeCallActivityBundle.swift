import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen card for a test call. iOS stops an AudioRecordingIntent's recording
/// unless a Live Activity starts with it.
@main
struct ProbeCallActivityBundle: WidgetBundle {
    var body: some Widget {
        ProbeCallActivityWidget()
    }
}

struct ProbeCallActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ProbeCallAttributes.self) { context in
            Label("\(context.attributes.line): \(context.state.status)", systemImage: "phone.fill")
                .padding()
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) { Text(context.state.status) }
            } compactLeading: {
                Image(systemName: "phone.fill")
            } compactTrailing: {
                Text(context.state.startedAt, style: .timer).monospacedDigit().frame(maxWidth: 44)
            } minimal: {
                Image(systemName: "phone.fill")
            }
        }
    }
}
