import SwiftUI
import WidgetKit

@main
struct OwnAudioMusicWidgets: WidgetBundle {
    var body: some Widget {
        RecentlyPlayedWidget()
    }
}

/// Where you left off and the albums and playlists played last, a tap away: one on the small
/// widget, three on the medium. Everything comes from the snapshot the app keeps in the App
/// Group; a tap opens the app and plays it. Copied from the podcasts app's Up Next widget.
struct RecentlyPlayedWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "audio.own.musicplayer.recent", provider: Provider()) { entry in
            RecentlyPlayedView(entry: entry)
                .containerBackground(for: .widget) { Color(light: 0xF7F7F8, dark: 0x0C0C0E) }
        }
        .configurationDisplayName("Recently Played")
        .description("Where you left off, and the albums and playlists you played last.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let items: [WidgetSnapshot.Entry]
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, items: [.init(id: "placeholder", kind: .album, title: "An Album", subtitle: "An Artist", cover: nil)])
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: .now, items: WidgetSnapshot.load()?.entries ?? placeholder(in: context).items))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        // The app reloads the timeline itself when something changes; nothing to schedule.
        completion(Timeline(entries: [Entry(date: .now, items: WidgetSnapshot.load()?.entries ?? [])], policy: .never))
    }
}

let accent = Color(light: 0xD63A6A, dark: 0xFF6482)
private let muted = Color(light: 0x6E6E73, dark: 0x98989D)

struct RecentlyPlayedView: View {
    @Environment(\.widgetFamily) private var family
    let entry: Entry

    var body: some View {
        if entry.items.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "music.note").font(.title2).foregroundStyle(accent)
                Text("Nothing played yet").font(.caption).foregroundStyle(muted).multilineTextAlignment(.center)
            }
        } else if family == .systemSmall, let item = entry.items.first {
            small(item).widgetURL(item.url)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entry.items.prefix(3)) { item in
                    Link(destination: item.url ?? URL(string: "\(WidgetSnapshot.scheme)://")!) { row(item) }
                }
            }
        }
    }

    private func small(_ item: WidgetSnapshot.Entry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            cover(item, size: 56)
            Spacer(minLength: 0)
            Text(item.title).font(.caption.weight(.semibold)).lineLimit(2)
            Text(label(item)).font(.caption2).foregroundStyle(muted).lineLimit(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    private func row(_ item: WidgetSnapshot.Entry) -> some View {
        HStack(spacing: 10) {
            cover(item, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.caption.weight(.semibold)).lineLimit(1)
                Text(label(item)).font(.caption2).foregroundStyle(muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.fill").font(.caption).foregroundStyle(accent)
        }
    }

    private func label(_ item: WidgetSnapshot.Entry) -> String {
        item.kind == .resume ? String(localized: "Continue · \(item.subtitle)") : item.subtitle
    }

    @ViewBuilder
    private func cover(_ item: WidgetSnapshot.Entry, size: CGFloat) -> some View {
        if let data = item.cover, let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            RoundedRectangle(cornerRadius: 8).fill(accent.opacity(0.15)).frame(width: size, height: size)
                .overlay { Image(systemName: item.kind == .playlist ? "music.note.list" : "music.note").foregroundStyle(accent) }
        }
    }
}

extension Color {
    /// One colour for each appearance, as the app's theme has them.
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}
