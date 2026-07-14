import AppKit

/// Persistent capture history (#8). Finished screenshots are archived as PNGs in
/// an app-managed folder and pruned once they exceed the configured retention
/// window. The menu bar lists recent entries so they can be reopened.
final class HistoryStore {

    static let shared = HistoryStore()

    let directory: URL

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("ScreenCapture/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    struct Entry {
        let url: URL
        let date: Date
    }

    private static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss.SSS"
        return f
    }()

    private static let labelFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    // MARK: - Writing

    /// Archive a finished screenshot. No-op when retention is disabled.
    func saveScreenshot(_ image: CGImage, scale: CGFloat) {
        guard Preferences.shared.historyRetentionSeconds > 0 else { return }
        let dpi = 72.0 * (scale > 0 ? scale : 2.0)
        guard let png = CaptureManager.shared.pngData(from: image, dpi: dpi) else { return }
        let url = directory.appendingPathComponent("Screenshot \(Self.nameFormatter.string(from: Date())).png")
        do {
            try png.write(to: url)
        } catch {
            NSLog("[HistoryStore] Failed to write \(url.lastPathComponent): \(error)")
        }
        prune()
    }

    // MARK: - Reading

    private static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "mov", "mp4"]

    func entries() -> [Entry] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        return items
            .filter { Self.allowedExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return Entry(url: url, date: date)
            }
            .sorted { $0.date > $1.date }
    }

    func label(for entry: Entry) -> String {
        Self.labelFormatter.string(from: entry.date)
    }

    /// Small thumbnail for a menu item, or nil.
    func thumbnail(for url: URL, maxDim: CGFloat = 20) -> NSImage? {
        guard let img = NSImage(contentsOf: url) else { return nil }
        let s = img.size
        guard s.width > 0, s.height > 0 else { return nil }
        let scale = min(maxDim / s.width, maxDim / s.height, 1)
        let target = NSSize(width: s.width * scale, height: s.height * scale)
        let thumb = NSImage(size: target)
        thumb.lockFocus()
        img.draw(in: NSRect(origin: .zero, size: target),
                 from: NSRect(origin: .zero, size: s),
                 operation: .copy, fraction: 1)
        thumb.unlockFocus()
        return thumb
    }

    // MARK: - Pruning / clearing

    /// Delete entries older than the retention window. When retention is disabled
    /// (0) everything is removed.
    func prune() {
        let secs = Preferences.shared.historyRetentionSeconds
        guard secs > 0 else { clearAll(); return }
        let cutoff = Date().addingTimeInterval(-Double(secs))
        for e in entries() where e.date < cutoff {
            try? FileManager.default.removeItem(at: e.url)
        }
    }

    func clearAll() {
        for e in entries() { try? FileManager.default.removeItem(at: e.url) }
    }
}
