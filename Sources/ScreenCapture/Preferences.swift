import Foundation

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

    // MARK: – Change notification

    static let changed = Notification.Name("PreferencesChanged")
    private func post() { NotificationCenter.default.post(name: Preferences.changed, object: self) }
}
