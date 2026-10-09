// Apps import MusicEngine alone and get the shared pieces with it.
@_exported import PlayerCore

import Foundation
import OSLog

/// Strings shown to the listener. The app's catalog translates them.
func loc(_ key: String.LocalizationValue) -> String {
    String(localized: key)
}

extension Logger {
    /// The reason a track "did not play" has to live somewhere; this is where.
    static let playback = Logger(subsystem: "audio.own.player", category: "playback")
}
