import MusicLibrary
import MusicEngine
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var removingServer: ServerRecord?
    @State private var isAddingServer = false

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
            ServersSection(isAdding: $isAddingServer, removing: $removingServer)

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
                Toggle("Download on Wi-Fi Only", isOn: Binding(
                    get: { model.downloadsWifiOnly },
                    set: { model.downloadsWifiOnly = $0 }
                ))
                .accessibilityIdentifier("settings.wifiOnly")
                Picker("Keep at Most", selection: Binding(
                    get: { model.downloadsCapBytes },
                    set: { model.downloadsCapBytes = $0 }
                )) {
                    ForEach(AppModel.downloadsCapChoices, id: \.self) { cap in
                        Text(cap.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? String(localized: "No Limit")).tag(cap)
                    }
                }
                .accessibilityIdentifier("settings.storageCap")
                Toggle("Whole Library When Offline", isOn: Binding(
                    get: { model.offlineShowsWholeLibrary },
                    set: { model.offlineShowsWholeLibrary = $0 }
                ))
                .accessibilityIdentifier("settings.offlineWholeLibrary")
            } footer: {
                Text("Offline Mode shows and plays only what is on this iPhone, as it does on its own with no network. Saves mobile data.\n\nWith Whole Library, the offline screens list everything on the server, from a copy of its catalogue kept on this iPhone; what isn't downloaded is greyed out. Albums open offline either way.\n\nOver the limit, the songs not played for longest go first; never the one playing.")
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

            Section {
                LabeledContent("Version", value: version)
                Link("Source Code and Licence", destination: URL(string: "https://github.com/own-audio/music-ios")!)
                Link("Privacy", destination: URL(string: "https://github.com/own-audio/music-ios/blob/main/PRIVACY.md")!)
                    .accessibilityIdentifier("settings.privacy")
                // Tinted like the links above it.
                NavigationLink { LogsView() } label: { Text("Logs").foregroundStyle(.tint) }
                    .accessibilityIdentifier("settings.logs")
            } header: {
                Text("About")
            } footer: {
                Text("own.audio Music is free and open source (MPL-2.0). It talks only to the servers you add.")
            }
        }
        .sheet(isPresented: $isAddingServer) { NavigationStack { AddServerView() } }
        .confirmationDialog(
            "Remove \(removingServer?.displayName ?? "")?",
            isPresented: Binding(get: { removingServer != nil }, set: { if !$0 { removingServer = nil } }),
            titleVisibility: .visible, presenting: removingServer
        ) { server in
            Button("Remove", role: .destructive) { model.perform { try await model.removeServer(id: server.id) } }
        } message: { _ in
            Text("Its downloads leave this iPhone. Nothing changes on the server.")
        }
        .navigationTitle("Settings")
    }
}
