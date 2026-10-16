import ActivityKit
import AppIntents
import IskraCore
import IskraDesign
import SwiftUI
import WidgetKit

/// A live location share, on the lock screen and in the Dynamic Island: who it goes to, how long is
/// left, and "Stop".
///
/// The clock counts down by itself (`Text(timerInterval:)`) — the app updates the activity only
/// when something else changes, never once a minute to move a number. "Stop" runs
/// `StopLiveLocationIntent` in the app, which ends the share, which ends this.
struct LiveLocationActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LiveLocationAttributes.self) { context in
            LiveLocationBanner(state: context.state)
                .padding(Theme.Spacing.roomy)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetFace(file: WidgetFace.file(named: state.faceFile), seed: state.avatarSeed,
                               name: state.chats.first ?? "",
                               size: Theme.Size.activityFace)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if !state.ended {
                        Countdown(until: state.until)
                            .font(.title3.monospacedDigit().weight(.semibold))
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    LiveLocationTitle(state: state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if !state.ended { StopButton() }
                }
            } compactLeading: {
                Image(systemName: "location.fill")
                    .foregroundStyle(.tint)
            } compactTrailing: {
                if state.ended {
                    Image(systemName: "checkmark")
                } else {
                    Countdown(until: state.until)
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: 48)
                }
            } minimal: {
                Image(systemName: "location.fill")
                    .foregroundStyle(.tint)
            }
        }
    }
}

private struct LiveLocationBanner: View {
    let state: LiveLocationAttributes.ContentState

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            WidgetFace(file: WidgetFace.file(named: state.faceFile), seed: state.avatarSeed,
                       name: state.chats.first ?? "",
                       size: Theme.Size.activityFace)
            LiveLocationTitle(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
            if !state.ended {
                VStack(alignment: .trailing, spacing: Theme.Spacing.tight) {
                    Countdown(until: state.until)
                        .font(.headline.monospacedDigit())
                    StopButton()
                }
            }
        }
    }
}

private struct LiveLocationTitle: View {
    let state: LiveLocationAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.withinRun) {
            Text(state.ended ? CoreStrings.LiveActivity.locationEnded : CoreStrings.LiveActivity.locationSharing)
                .font(.headline)
                .lineLimit(1)
            if state.ended && state.stopFailed {
                Text(CoreStrings.LiveActivity.locationStopFailed)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            } else if !state.ended && !state.hasSentPoint {
                Text(CoreStrings.LiveActivity.locationFinding)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if !state.chats.isEmpty {
                Text(verbatim: state.chats.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// The time left, counting itself down. A range that has already closed is drawn as nothing rather
/// than handed to `Text(timerInterval:)`, which does not take a backwards range kindly.
private struct Countdown: View {
    let until: Date

    var body: some View {
        if until > .now {
            Text(timerInterval: Date.now...until, countsDown: true)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct StopButton: View {
    var body: some View {
        Button(intent: StopLiveLocationIntent()) {
            Label { Text(CoreStrings.LiveActivity.locationStop) } icon: { Image(systemName: "stop.fill") }
                .font(.subheadline.weight(.semibold))
        }
        .tint(.red)
    }
}
