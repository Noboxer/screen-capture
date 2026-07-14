import AppKit

final class Preferences {
    static let shared = Preferences()
    private let ud = UserDefaults.standard

    private init() {
        // registerDefaults sets the value returned by ud.xxx(forKey:) when the user
        // has never written to that key — it does not overwrite any stored value.
        ud.register(defaults: [
            Keys.imageFormat:            ImageFormat.png.rawValue,
            Keys.heifQuality:            0.9,
            Keys.autoDeleteSeconds:      0,
            Keys.annotationCloseSeconds: 0,
            Keys.captureDelaySeconds:    0,
            Keys.captureSound:           true,
            Keys.saveToFolder:           false,
            Keys.videoCodec:             VideoCodec.hevc.rawValue,
            Keys.videoRegion:            VideoRegion.selection.rawValue,
            Keys.historyRetention:       86_400,   // keep captures 1 day by default
        ])
    }

    // MARK: – UserDefaults key strings

    private enum Keys {
        static let imageFormat            = "imageFormat"
        static let heifQuality            = "heifQuality"
        static let autoDeleteSeconds      = "autoDeleteSeconds"
        static let annotationCloseSeconds = "annotationCloseSeconds"
        static let captureDelaySeconds    = "captureDelaySeconds"
        static let captureSound           = "captureSound"
        static let saveToFolder           = "saveToFolder"
        static let saveFolderPath         = "saveFolderPath"
        static let videoCodec             = "videoCodec"
        static let videoRegion            = "videoRegion"
        static let launchAtLogin          = "launchAtLogin"
        static let historyRetention       = "historyRetentionSeconds"
    }

    // MARK: – Image format type

    enum ImageFormat: String, CaseIterable {
        case png, heif
        var label: String { rawValue.uppercased() }
        var menuLabel: String {
            switch self {
            case .png:  return "PNG — lossless"
            case .heif: return "HEIF — lossy, ~50% smaller"
            }
        }
    }

    // MARK: – Video format types

    enum VideoCodec: String, CaseIterable {
        case hevc, h264
        var label: String {
            switch self {
            case .hevc: return "HEVC (H.265)"
            case .h264: return "H.264"
            }
        }
        var menuLabel: String {
            switch self {
            case .hevc: return "HEVC — smaller files, modern (default)"
            case .h264: return "H.264 — universal compatibility, larger files"
            }
        }
    }

    enum VideoRegion: String, CaseIterable {
        case selection, fullscreen
        var label: String {
            switch self {
            case .selection:  return "Selected area"
            case .fullscreen: return "Full screen"
            }
        }
    }

    // MARK: – Settings

    var imageFormat: ImageFormat {
        get { ImageFormat(rawValue: ud.string(forKey: Keys.imageFormat) ?? "") ?? .png }
        set { ud.set(newValue.rawValue, forKey: Keys.imageFormat); post() }
    }

    var heifQuality: Double {
        get { ud.double(forKey: Keys.heifQuality) }
        set { ud.set(newValue, forKey: Keys.heifQuality); post() }
    }

    // Seconds after copy before clipboard is cleared; 0 = disabled.
    var autoDeleteSeconds: Int {
        get { ud.integer(forKey: Keys.autoDeleteSeconds) }
        set { ud.set(newValue, forKey: Keys.autoDeleteSeconds); post() }
    }

    // Seconds of inactivity before annotation window auto-closes; 0 = manual only.
    var annotationCloseSeconds: Int {
        get { ud.integer(forKey: Keys.annotationCloseSeconds) }
        set { ud.set(newValue, forKey: Keys.annotationCloseSeconds); post() }
    }

    var captureDelaySeconds: Int {
        get { ud.integer(forKey: Keys.captureDelaySeconds) }
        set { ud.set(newValue, forKey: Keys.captureDelaySeconds); post() }
    }

    var captureSound: Bool {
        get { ud.bool(forKey: Keys.captureSound) }
        set { ud.set(newValue, forKey: Keys.captureSound); post() }
    }

    // When true, captured images are also written to saveFolderPath alongside the clipboard.
    var saveToFolder: Bool {
        get { ud.bool(forKey: Keys.saveToFolder) }
        set { ud.set(newValue, forKey: Keys.saveToFolder); post() }
    }

    // Absolute POSIX path of the user-chosen output folder (no sandbox, plain string is fine).
    var saveFolderPath: String? {
        get { ud.string(forKey: Keys.saveFolderPath) }
        set { ud.set(newValue, forKey: Keys.saveFolderPath); post() }
    }

    var videoCodec: VideoCodec {
        get { VideoCodec(rawValue: ud.string(forKey: Keys.videoCodec) ?? "") ?? .hevc }
        set { ud.set(newValue.rawValue, forKey: Keys.videoCodec); post() }
    }

    var videoRegion: VideoRegion {
        get { VideoRegion(rawValue: ud.string(forKey: Keys.videoRegion) ?? "") ?? .selection }
        set { ud.set(newValue.rawValue, forKey: Keys.videoRegion); post() }
    }

    // Whether the app launches automatically at login (#6). Default on.
    var launchAtLogin: Bool {
        get { ud.object(forKey: Keys.launchAtLogin) as? Bool ?? true }
        set { ud.set(newValue, forKey: Keys.launchAtLogin); post() }
    }

    // How long finished captures are kept in the history folder; 0 = don't keep (#8).
    var historyRetentionSeconds: Int {
        get { ud.integer(forKey: Keys.historyRetention) }
        set { ud.set(newValue, forKey: Keys.historyRetention); post() }
    }

    // MARK: – Global hotkeys (#1)

    enum ShortcutAction: String, CaseIterable {
        case captureArea, captureFullscreen, recordVideo, quit

        var title: String {
            switch self {
            case .captureArea:       return "Capture Area"
            case .captureFullscreen: return "Capture Fullscreen"
            case .recordVideo:       return "Record Video"
            case .quit:              return "Quit"
            }
        }

        // US-layout key codes: S=1, F=3, R=15, Q=12. Defaults match the original
        // hardcoded ⌃⇧ combinations.
        var defaultShortcut: Shortcut {
            switch self {
            case .captureArea:       return Shortcut(keyCode: 1,  modifiers: [.control, .shift])
            case .captureFullscreen: return Shortcut(keyCode: 3,  modifiers: [.control, .shift])
            case .recordVideo:       return Shortcut(keyCode: 15, modifiers: [.control, .shift])
            case .quit:              return Shortcut(keyCode: 12, modifiers: [.control, .shift])
            }
        }
    }

    struct Shortcut: Equatable {
        var keyCode: UInt16
        var modifiers: NSEvent.ModifierFlags
    }

    func shortcut(for action: ShortcutAction) -> Shortcut {
        let kc  = ud.object(forKey: "shortcut.\(action.rawValue).keyCode")   as? Int
        let mod = ud.object(forKey: "shortcut.\(action.rawValue).modifiers") as? Int
        if let kc, let mod {
            return Shortcut(keyCode: UInt16(kc), modifiers: NSEvent.ModifierFlags(rawValue: UInt(mod)))
        }
        return action.defaultShortcut
    }

    func setShortcut(_ s: Shortcut, for action: ShortcutAction) {
        ud.set(Int(s.keyCode),           forKey: "shortcut.\(action.rawValue).keyCode")
        ud.set(Int(s.modifiers.rawValue), forKey: "shortcut.\(action.rawValue).modifiers")
        post()
    }

    /// Human-readable label for a hardware key code (US layout). Falls back to a
    /// generic label for keys outside the common table.
    static func keyName(for keyCode: UInt16) -> String {
        keyCodeNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyCodeNames: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J",
        39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        50: "`",
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    // MARK: – Change notification

    static let changed = Notification.Name("PreferencesChanged")
    private func post() { NotificationCenter.default.post(name: Preferences.changed, object: self) }
}

extension Preferences.Shortcut {
    /// Menu-style rendering, e.g. "⌃⇧S". Modifier order follows Apple convention.
    var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        s += Preferences.keyName(for: keyCode)
        return s
    }
}
