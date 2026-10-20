import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// The player on the lock screen and in the Dynamic Island: picture, song, artist, how far, and
/// previous, play/pause and next. Copied from the podcasts app's `EpisodeLiveActivity`.
struct TrackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackActivityAttributes.self) { context in
            LockScreenView(state: context.state)
                .activityBackgroundTint(Color(light: 0xF7F7F8, dark: 0x0C0C0E))
                .widgetURL(URL(string: "\(WidgetSnapshot.scheme)://player"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Cover(url: TrackActivityAttributes.coverURL(file: context.state.coverFile), size: 52)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(Remaining.text(context.state)).font(.caption).foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text(context.state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        ProgressBar(state: context.state)
                        Controls(state: context.state)
                    }
                }
            } compactLeading: {
                Cover(url: TrackActivityAttributes.coverURL(file: context.state.coverFile), size: 22)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill").foregroundStyle(accent)
            } minimal: {
                Image(systemName: "music.note").foregroundStyle(accent)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: TrackActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Cover(url: TrackActivityAttributes.coverURL(file: state.coverFile), size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                ProgressBar(state: state)
                HStack {
                    Text(Remaining.text(state)).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Controls(state: state)
                }
            }
        }
        .padding(14)
    }
}

/// Previous, play/pause and next; each runs an intent in the app without opening it.
private struct Controls: View {
    let state: TrackActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 18) {
            Button(intent: PlaybackControlIntent(.previous)) { Image(systemName: "backward.fill") }
                .accessibilityLabel("Previous")
            Button(intent: PlaybackControlIntent(.toggle)) { Image(systemName: state.isPlaying ? "pause.fill" : "play.fill").font(.title3) }
                .accessibilityLabel(state.isPlaying ? "Pause" : "Play")
            Button(intent: PlaybackControlIntent(.next)) { Image(systemName: "forward.fill") }
                .accessibilityLabel("Next")
                .disabled(!state.hasNext)
        }
        .buttonStyle(.plain)
        .foregroundStyle(accent)
    }
}

private struct ProgressBar: View {
    let state: TrackActivityAttributes.ContentState

    var body: some View {
        let fraction = state.durationSecs > 0 ? min(max(state.positionSecs / state.durationSecs, 0), 1) : 0
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(accent.opacity(0.2))
                Capsule().fill(accent).frame(width: max(geometry.size.width * fraction, 3))
            }
        }
        .frame(height: 4)
    }
}

private struct Cover: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        if let url, let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size / 6))
        } else {
            RoundedRectangle(cornerRadius: size / 6).fill(accent.opacity(0.15)).frame(width: size, height: size)
                .overlay { Image(systemName: "music.note").font(.system(size: size / 2.5)).foregroundStyle(accent) }
        }
    }
}

private enum Remaining {
    static func text(_ state: TrackActivityAttributes.ContentState) -> String {
        let secs = Int(max(state.durationSecs - state.positionSecs, 0).rounded())
        return "-\(secs / 60):" + String(format: "%02d", secs % 60)
    }
}
