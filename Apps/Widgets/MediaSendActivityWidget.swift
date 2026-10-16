import ActivityKit
import IskraCore
import IskraDesign
import SwiftUI
import WidgetKit

/// A video, an album or a big file going up, on iOS 18–25 — from 26 the system draws its own
/// indicator for the background task, and this one is not started (`MediaSendBackground`).
///
/// A tap opens the chat it is going to: on "Not sent" that is where "Send again" is.
struct MediaSendActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MediaSendAttributes.self) { context in
            MediaSendBanner(attributes: context.attributes, state: context.state)
                .padding(Theme.Spacing.roomy)
                .widgetURL(AppEnvironment.openChatURL(roomID: context.attributes.roomID,
                                                      accountID: context.attributes.accountID))
        } dynamicIsland: { context in
            let state = context.state
            let attributes = context.attributes
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    WidgetFace(file: WidgetFace.file(named: attributes.faceFile), seed: attributes.avatarSeed,
                               name: attributes.roomName,
                               size: Theme.Size.activityFace)
                }
                DynamicIslandExpandedRegion(.center) {
                    MediaSendTitle(attributes: attributes, state: state)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    MediaSendProgress(state: state)
                }
            } compactLeading: {
                Image(systemName: MediaSendStyle.symbol(for: attributes.what))
                    .foregroundStyle(.tint)
            } compactTrailing: {
                MediaSendGauge(state: state)
            } minimal: {
                MediaSendGauge(state: state)
            }
            .widgetURL(AppEnvironment.openChatURL(roomID: attributes.roomID, accountID: attributes.accountID))
        }
    }
}

private enum MediaSendStyle {
    static func symbol(for what: MediaSendJobs.What) -> String {
        switch what {
        case .video: "video.fill"
        case .photos(1): "photo.fill"
        case .photos, .media: "photo.on.rectangle.angled"
        case .file: "doc.fill"
        }
    }

    static func title(for what: MediaSendJobs.What) -> LocalizedStringResource {
        switch what {
        case .video: CoreStrings.LiveActivity.sendingVideo
        case .photos(1): CoreStrings.LiveActivity.sendingPhoto
        case .photos, .media: CoreStrings.LiveActivity.sendingAlbum
        case .file: CoreStrings.LiveActivity.sendingFile
        }
    }
}

private struct MediaSendBanner: View {
    let attributes: MediaSendAttributes
    let state: MediaSendAttributes.ContentState

    var body: some View {
        HStack(spacing: Theme.Spacing.normal) {
            WidgetFace(file: WidgetFace.file(named: attributes.faceFile), seed: attributes.avatarSeed,
                       name: attributes.roomName,
                       size: Theme.Size.activityFace)
            VStack(alignment: .leading, spacing: Theme.Spacing.close) {
                MediaSendTitle(attributes: attributes, state: state)
                MediaSendProgress(state: state)
            }
        }
    }
}

private struct MediaSendTitle: View {
    let attributes: MediaSendAttributes
    let state: MediaSendAttributes.ContentState

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.withinRun) {
            Text(MediaSendStyle.title(for: attributes.what))
                .font(.headline)
                .lineLimit(1)
            if !attributes.roomName.isEmpty {
                Text(verbatim: attributes.roomName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The bar, or — once there is nothing left to measure — the words for how it ended.
private struct MediaSendProgress: View {
    let state: MediaSendAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .preparing, .uploading:
            ProgressView(value: state.progress) {
                if state.phase == .preparing {
                    Text(CoreStrings.LiveActivity.mediaPreparing).font(.caption)
                }
            }
            .tint(.accentColor)
        case .sent:
            Label { Text(CoreStrings.LiveActivity.mediaSent) } icon: { Image(systemName: "checkmark.circle.fill") }
                .font(.subheadline)
                .foregroundStyle(.green)
        case .failed:
            Label { Text(CoreStrings.LiveActivity.mediaFailed) } icon: { Image(systemName: "exclamationmark.circle.fill") }
                .font(.subheadline)
                .foregroundStyle(.red)
        case .waitingForApp:
            Label { Text(CoreStrings.LiveActivity.mediaWaiting) } icon: { Image(systemName: "pause.circle.fill") }
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// The compact form: a ring that fills.
private struct MediaSendGauge: View {
    let state: MediaSendAttributes.ContentState

    var body: some View {
        switch state.phase {
        case .sent: Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark").foregroundStyle(.red)
        case .waitingForApp: Image(systemName: "pause.fill")
        case .preparing, .uploading:
            ProgressView(value: state.progress)
                .progressViewStyle(.circular)
                .tint(.accentColor)
        }
    }
}
