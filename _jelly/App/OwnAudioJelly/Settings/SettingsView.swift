import MusicEngine
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    private var equalizerSummary: String {
        guard model.equalizer.enabled else { return String(localized: "Off") }
        let preset = EqPreset.all.first { $0.name == model.equalizer.presetName }
        return preset?.title ?? String(localized: "Custom")
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ServersView()
                } label: {
                    LabeledContent("Servers", value: model.activeServer?.displayName ?? "")
                }
                .accessibilityIdentifier("settings.servers")
            }

            Section {
                NavigationLink {
                    DownloadsView()
                } label: {
                    LabeledContent("Downloads", value: ByteCountFormatter.string(fromByteCount: model.downloads.totalBytes, countStyle: .file))
                }
                Toggle("Offline Mode", isOn: Binding(
                    get: { model.downloadedOnly },
                    set: { model.downloadedOnly = $0 }
                ))
                .accessibilityIdentifier("settings.downloadedOnly")
            } footer: {
                Text("Shows and plays only what is on this iPhone, as it does on its own with no network. Saves mobile data.")
            }

            Section {
                Picker("On Mobile Data", selection: Binding(
                    get: { model.mobileBitrate },
                    set: { model.mobileBitrate = $0 }
                )) {
                    ForEach(AppModel.mobileBitrateChoices, id: \.self) { bitrate in
                        Text(bitrate.map { String(localized: "\($0 / 1000) kbps") } ?? String(localized: "Original")).tag(bitrate)
                    }
                }
                .accessibilityIdentifier("settings.mobileBitrate")
            } header: {
                Text("Streaming")
            } footer: {
                Text("On mobile data the server can make a smaller MP3 of each song as it plays. On Wi-Fi, and for downloads, it's always the original file.")
            }

            CrossfadeSettings(settings: model.playbackSettings)

            ReplayGainSettings(settings: model.playbackSettings)

            Section {
                NavigationLink {
                    EqualizerView(store: model.equalizer)
                } label: {
                    LabeledContent("Equalizer", value: equalizerSummary)
                }
            }

            Section {
                Toggle("Report Plays to the Server", isOn: Binding(
                    get: { model.scrobblingEnabled },
                    set: { model.scrobblingEnabled = $0 }
                ))
                .accessibilityIdentifier("settings.scrobble")
            } footer: {
                Text("Shows on the server what's playing on this phone, and counts plays the way Jellyfin does. Plays made offline are sent later. A server plugin can pass them on to Last.fm or ListenBrainz.")
            }

            Section("About") {
                LabeledContent("Version", value: version)
                Link(destination: URL(string: "https://github.com/own-audio/jelly-ios")!) {
                    Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Link(destination: URL(string: "https://www.mozilla.org/MPL/2.0/")!) {
                    Label("License: MPL 2.0", systemImage: "doc.text")
                }
                Link(destination: URL(string: "https://www.own.audio/")!) {
                    Label("Made by own.audio", systemImage: "heart")
                }
            }
        }
        .navigationTitle("Settings")
    }
}
