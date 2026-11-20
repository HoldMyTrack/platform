import ActivityKit
import AppIntents
import HoldMyTrackCore
import SwiftUI
import WidgetKit

/// The recording on the Lock Screen and in the Dynamic Island (apps/ios/docs/SPEC.md FR-5.1), in
/// place of Android's notification: the clock and distance, Pause or Resume, and Stop, which opens
/// the app to ask first. Every word and number comes from the app (RecordingActivityState).
@main
struct HoldMyTrackWidgets: WidgetBundle {
    var body: some Widget { RecordingLiveActivity() }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .padding(16)
                .activityBackgroundTint(Color(.systemBackground).opacity(0.9))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(context.state.title, systemImage: context.state.paused ? "pause.circle.fill" : "record.circle")
                        .foregroundStyle(.red)
                        .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Clock(state: context.state).font(.headline.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(context.state.distance).font(.subheadline)
                        Spacer()
                        Buttons(state: context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.paused ? "pause.circle.fill" : "record.circle").foregroundStyle(.red)
            } compactTrailing: {
                // Wide enough for H:MM:SS past an hour.
                Clock(state: context.state).monospacedDigit().multilineTextAlignment(.trailing).frame(minWidth: 44)
            } minimal: {
                Image(systemName: context.state.paused ? "pause.circle.fill" : "record.circle").foregroundStyle(.red)
            }
            .widgetURL(nil)
        }
    }
}

/// The moving time: ticked by the system while recording, standing still while paused.
private struct Clock: View {
    let state: RecordingActivityState

    var body: some View {
        if state.paused {
            Text(state.clock)
        } else {
            Text(state.clockStart, style: .timer)
        }
    }
}

private struct Buttons: View {
    let state: RecordingActivityState

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: ToggleRecordingIntent()) {
                Label(state.toggle, systemImage: state.paused ? "play.fill" : "pause.fill")
            }
            .tint(.red)
            Link(destination: RecordingLink.stop) {
                Label(state.stop, systemImage: "stop.fill")
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.quaternary, in: Capsule())
            }
        }
        .font(.subheadline.weight(.semibold))
    }
}

private struct LockScreenView: View {
    let state: RecordingActivityState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(state.title, systemImage: state.paused ? "pause.circle.fill" : "record.circle")
                    .foregroundStyle(.red)
                    .font(.headline)
                Spacer()
                Text("HoldMyTrack").font(.caption).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline) {
                Clock(state: state).font(.title2.monospacedDigit().weight(.semibold))
                Text(state.distance).font(.title3).foregroundStyle(.secondary)
                Spacer()
            }
            Buttons(state: state)
        }
    }
}