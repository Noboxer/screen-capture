import Foundation
import ServiceManagement

/// Start-at-login management via the modern SMAppService API (#6). Replaces the
/// old KeepAlive LaunchAgent that install.sh used to write — that always started
/// the app at login with no way to turn it off, and its KeepAlive respawned the
/// process even after the user chose Quit.
enum LoginItem {

    /// Align the actual login-item registration with the stored preference.
    /// Called at launch and whenever the toggle changes.
    static func sync() { apply(Preferences.shared.launchAtLogin) }

    static func apply(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            switch (enabled, SMAppService.mainApp.status) {
            case (true, let s) where s != .enabled:
                try SMAppService.mainApp.register()
            case (false, .enabled):
                try SMAppService.mainApp.unregister()
            default:
                break
            }
        } catch {
            NSLog("[LoginItem] Failed to \(enabled ? "register" : "unregister"): \(error)")
        }
    }

    static var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }
}
