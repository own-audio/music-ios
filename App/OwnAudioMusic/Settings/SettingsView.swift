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
                if model.household != nil {
                    NavigationLink {
                        HouseholdView()
                    } label: {
                        Label("Family", systemImage: "person.2")
                    }
                    .accessibilityIdentifier("settings.household")
                }
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
                Toggle("Whole Library When Offline", isOn: Binding(
                    get: { model.offlineShowsWholeLibrary },
                    set: { model.offlineShowsWholeLibrary = $0 }
                ))
                .accessibilityIdentifier("settings.offlineWholeLibrary")
            } footer: {
                Text("Offline Mode shows and plays only what is on this iPhone, as it does on its own with no network. Saves mobile data.\n\nWith Whole Library, the offline screens list everything on the server, from a copy of its catalogue kept on this iPhone; what isn't downloaded is greyed out. Albums open offline either way.")
            }

            Section {
                Picker("On Mobile Data", selection: Binding(
                    get: { model.mobileData },
                    set: { model.mobileData = $0 }
                )) {
                    Text("Original").tag(AppModel.MobileData.original)
                    Text("Saver").tag(AppModel.MobileData.saver)
                    Text("Downloaded Only").tag(AppModel.MobileData.downloadedOnly)
                }
                .accessibilityIdentifier("settings.mobileData")
                if model.mobileData == .saver {
                    Picker("Saver Quality", selection: Binding(
                        get: { model.saverBitrate },
                        set: { model.saverBitrate = $0 }
                    )) {
                        ForEach(AppModel.saverBitrateChoices, id: \.self) { bitrate in
                            Text("\(bitrate / 1000) kbps").tag(bitrate)
                        }
                    }
                    .accessibilityIdentifier("settings.saverBitrate")
                }
            } header: {
                Text("Streaming")
            } footer: {
                Text("Saver asks the server for a smaller MP3 of each song as it plays; servers that can't make one send the original. Downloaded Only plays just what's on this iPhone while on mobile data. With iOS Low Data Mode on, streams are kept at 128 kbps. Wi-Fi and downloads always get the original file.")
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
                Text("Tells the server what's playing and counts plays: on Subsonic servers once you've heard half a song or four minutes, on Jellyfin by its own rules. Plays made offline are sent later. The server can pass them on to Last.fm or ListenBrainz.")
            }

            Section("About") {
                LabeledContent("Version", value: version)
                Link(destination: URL(string: "https://github.com/own-audio/music-ios")!) {
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
