import Combine
import MusicEngine
import SwiftUI

extension View {
    /// Space plays and pauses, ⌘→ and ⌘← skip, and with `close` Esc closes: for a hardware
    /// keyboard on an iPad and for the app on a Mac, where there is no swipe to lean on.
    func playerKeyboardShortcuts(close: (() -> Void)? = nil) -> some View {
        background { PlayerKeyboardShortcuts(close: close) }
    }
}

/// Invisible buttons that only carry the shortcuts, so they work wherever the transport buttons
/// are hidden or not drawn (the mini player hides play/pause while loading, and every tab has
/// its own).
private struct PlayerKeyboardShortcuts: View {
    @Environment(AppModel.self) private var model
    let close: (() -> Void)?
    /// While a text field has the keyboard, Space types a space, ⌘← moves the cursor and Esc
    /// ends the search: the shortcuts step aside.
    @State private var isTyping = false

    private var engine: PlaybackEngine { model.engine }

    var body: some View {
        Group {
            Button("Play or Pause") { engine.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(engine.currentTrack == nil)
            Button("Next") { engine.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!engine.canSkipForward)
            Button("Previous") { engine.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!engine.canGoBack)
            if let close {
                Button("Close Player", action: close)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .disabled(isTyping)
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { _ in isTyping = true }
        .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)) { _ in isTyping = false }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification)) { _ in isTyping = true }
        .onReceive(NotificationCenter.default.publisher(for: UITextView.textDidEndEditingNotification)) { _ in isTyping = false }
    }
}
