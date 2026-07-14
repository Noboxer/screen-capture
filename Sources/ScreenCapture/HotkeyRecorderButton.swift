import AppKit

/// A click-to-record shortcut field used in the Settings → Shortcuts tab (#1).
/// Clicking arms recording; the next key combination (with at least one modifier)
/// is captured and reported via `onChange`. Escape cancels.
final class HotkeyRecorderButton: NSButton {

    private let action_: Preferences.ShortcutAction
    var onChange: ((Preferences.Shortcut) -> Void)?

    private var recording = false
    private var monitor: Any?

    init(action: Preferences.ShortcutAction) {
        self.action_ = action
        super.init(frame: .zero)
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        target = self
        self.action = #selector(toggleRecording)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { removeMonitor() }

    private func refreshTitle() {
        title = Preferences.shared.shortcut(for: action_).displayString
    }

    @objc private func toggleRecording() {
        recording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        recording = true
        title = "Press keys… (⎋ to cancel)"
        highlight(true)

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.recording else { return event }

            if event.keyCode == 53 { self.stopRecording(); return nil }  // Escape

            let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
            guard !mods.isEmpty else { NSSound.beep(); return nil }       // require a modifier

            let shortcut = Preferences.Shortcut(keyCode: event.keyCode, modifiers: mods)
            self.onChange?(shortcut)
            self.stopRecording()
            return nil   // consume — don't let the combo do anything else
        }
    }

    private func stopRecording() {
        recording = false
        highlight(false)
        removeMonitor()
        refreshTitle()
    }

    private func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
