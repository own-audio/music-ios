import Foundation
import UIKit

/// The iPad app also runs on Apple-silicon Macs ("Designed for iPad"), where `UIDevice` still
/// answers as an iPad. The few places that should say Mac, or hide what a Mac doesn't have such
/// as mobile data, ask here.
enum Platform {
    static let isMac = ProcessInfo.processInfo.isiOSAppOnMac

    /// The name in the server's list of signed-in devices. On iOS 16 and later `UIDevice.name`
    /// is the plain model ("iPhone") anyway; a Mac's host name would carry its owner's name, so
    /// it stays "Mac" too.
    @MainActor static var deviceName: String { isMac ? "Mac" : UIDevice.current.name }

    /// The model Jellyfin shows in its dashboard.
    @MainActor static var deviceModel: String { isMac ? "Mac" : UIDevice.current.model }

    /// own.audio's `device_kind`; the server accepts "macos" for a Mac.
    static let deviceKind = isMac ? "macos" : "ios"

    /// The system line in the logs. On a Mac the version the app can see is the iOS one macOS
    /// presents to iPad apps, so it is labelled as that.
    @MainActor static var systemDescription: String {
        let version = UIDevice.current.systemVersion
        return isMac ? "macOS (iOS \(version) compatible)" : "iOS \(version)"
    }
}
