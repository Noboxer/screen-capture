import AppKit
import CoreGraphics

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var hotkeyManager: HotkeyManager?
    var statusItem: NSStatusItem?

    // Refs to the four dynamic menu items so menuNeedsUpdate can patch them in-place
    // without rebuilding the whole menu on every open.
    private var formatItem:       NSMenuItem?
    private var autoDelItem:      NSMenuItem?
    private var annotCloseItem:   NSMenuItem?
    private var captureDelayItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        CrashReporter.install()
        NSApp.setActivationPolicy(.accessory)
        NSApp.applicationIconImage = makeAppIcon()
        setupStatusItem()
        // Hotkeys must always be installed — they're how the user discovers that
        // Screen Recording is missing (the capture callback shows an alert).
        // Previously this was gated behind requestScreenRecordingIfNeeded which
        // left users with no hotkeys AND no obvious next step.
        startHotkeyManager()
        requestScreenRecordingIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeyManager = nil
    }

    // MARK: – Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        setRecording(false)
        let menu = buildMenu()
        menu.delegate = self
        statusItem?.menu = menu
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // ── Capture actions ─────────────────────────────────────────────────
        let captureItem = NSMenuItem(title: "Capture Area",
                                     action: #selector(menuCaptureArea),
                                     keyEquivalent: "s")
        captureItem.target = self
        captureItem.image  = menuIcon("rectangle.dashed.badge.record")
        captureItem.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(captureItem)

        let fullItem = NSMenuItem(title: "Capture Fullscreen",
                                  action: #selector(menuCaptureFullscreen),
                                  keyEquivalent: "f")
        fullItem.target = self
        fullItem.image  = menuIcon("macwindow.on.rectangle")
        fullItem.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(fullItem)

        menu.addItem(.separator())

        let videoItem = NSMenuItem(title: "Record Video",
                                   action: #selector(menuRecordVideo),
                                   keyEquivalent: "r")
        videoItem.target = self
        videoItem.image  = menuIcon("record.circle")
        videoItem.keyEquivalentModifierMask = [.control, .shift]
        menu.addItem(videoItem)

        menu.addItem(.separator())

        // ── Quick-access settings submenus (refs saved for in-place updates) ─
        formatItem = formatMenuItem();       menu.addItem(formatItem!)
        autoDelItem = autoDeleteMenuItem();  menu.addItem(autoDelItem!)
        annotCloseItem = annotationCloseMenuItem(); menu.addItem(annotCloseItem!)
        captureDelayItem = captureDelayMenuItem();  menu.addItem(captureDelayItem!)

        menu.addItem(.separator())

        // ── Settings & quit ─────────────────────────────────────────────────
        let settingsItem = NSMenuItem(title: "Settings…",
                                      action: #selector(menuSettings),
                                      keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image  = menuIcon("gearshape")
        settingsItem.keyEquivalentModifierMask = .command
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Screen Capture",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        return menu
    }

    // MARK: – Submenu builders

    private func formatMenuItem() -> NSMenuItem {
        let pref  = Preferences.shared.imageFormat
        let title = "Format: \(pref.label)"
        let item  = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = menuIcon("photo")
        let sub = NSMenu()
        for fmt in Preferences.ImageFormat.allCases {
            let si = NSMenuItem(title: fmt.menuLabel,
                                action: #selector(menuSetFormat(_:)),
                                keyEquivalent: "")
            si.target = self
            si.representedObject = fmt.rawValue
            si.state  = (fmt == pref) ? .on : .off
            sub.addItem(si)
        }
        item.submenu = sub
        return item
    }

    private func autoDeleteMenuItem() -> NSMenuItem {
        let secs  = Preferences.shared.autoDeleteSeconds
        let label = autoDeleteLabel(secs)
        let item  = NSMenuItem(title: "Auto-delete: \(label)", action: nil, keyEquivalent: "")
        item.image = menuIcon("clock.badge.xmark")
        let options: [(String, Int)] = [("Off", 0), ("30 s", 30), ("1 min", 60),
                                        ("5 min", 300), ("30 min", 1800)]
        let sub = NSMenu()
        for (name, val) in options {
            let si = NSMenuItem(title: name, action: #selector(menuSetAutoDelete(_:)), keyEquivalent: "")
            si.target = self
            si.representedObject = val as NSNumber
            si.state = (val == secs) ? .on : .off
            sub.addItem(si)
        }
        item.submenu = sub
        return item
    }

    private func annotationCloseMenuItem() -> NSMenuItem {
        let secs  = Preferences.shared.annotationCloseSeconds
        let label = secondsLabel(secs, offLabel: "Off")
        let item  = NSMenuItem(title: "Annotation closes: \(label)", action: nil, keyEquivalent: "")
        item.image = menuIcon("xmark.rectangle")
        let options: [(String, Int)] = [("Off", 0), ("2 s", 2), ("5 s", 5),
                                        ("10 s", 10), ("30 s", 30), ("60 s", 60)]
        let sub = NSMenu()
        for (name, val) in options {
            let si = NSMenuItem(title: name, action: #selector(menuSetAnnotationClose(_:)), keyEquivalent: "")
            si.target = self
            si.representedObject = val as NSNumber
            si.state = (val == secs) ? .on : .off
            sub.addItem(si)
        }
        item.submenu = sub
        return item
    }

    private func captureDelayMenuItem() -> NSMenuItem {
        let secs  = Preferences.shared.captureDelaySeconds
        let label = secondsLabel(secs, offLabel: "None")
        let item  = NSMenuItem(title: "Capture delay: \(label)", action: nil, keyEquivalent: "")
        item.image = menuIcon("timer")
        let options: [(String, Int)] = [("None", 0), ("3 s", 3), ("5 s", 5), ("10 s", 10)]
        let sub = NSMenu()
        for (name, val) in options {
            let si = NSMenuItem(title: name, action: #selector(menuSetCaptureDelay(_:)), keyEquivalent: "")
            si.target = self
            si.representedObject = val as NSNumber
            si.state = (val == secs) ? .on : .off
            sub.addItem(si)
        }
        item.submenu = sub
        return item
    }

    // MARK: – NSMenuDelegate

    // Called once per tracking session before the menu is shown. Patch only the
    // four dynamic items (title + submenu checkmarks) so the menu is always fresh
    // without rebuilding and re-copying the entire item tree.
    func menuNeedsUpdate(_ menu: NSMenu) {
        let p = Preferences.shared

        let fmt = p.imageFormat
        formatItem?.title = "Format: \(fmt.label)"
        formatItem?.submenu?.items.forEach { si in
            guard let raw = si.representedObject as? String,
                  let f = Preferences.ImageFormat(rawValue: raw) else { return }
            si.state = f == fmt ? .on : .off
        }

        let del = p.autoDeleteSeconds
        autoDelItem?.title = "Auto-delete: \(autoDeleteLabel(del))"
        autoDelItem?.submenu?.items.forEach { si in
            si.state = (si.representedObject as? NSNumber)?.intValue == del ? .on : .off
        }

        let ann = p.annotationCloseSeconds
        annotCloseItem?.title = "Annotation closes: \(secondsLabel(ann, offLabel: "Off"))"
        annotCloseItem?.submenu?.items.forEach { si in
            si.state = (si.representedObject as? NSNumber)?.intValue == ann ? .on : .off
        }

        let delay = p.captureDelaySeconds
        captureDelayItem?.title = "Capture delay: \(secondsLabel(delay, offLabel: "None"))"
        captureDelayItem?.submenu?.items.forEach { si in
            si.state = (si.representedObject as? NSNumber)?.intValue == delay ? .on : .off
        }
    }

    // MARK: – Menu icons (small, template-rendered)

    private func menuIcon(_ symbol: String) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        return NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
    }

    // MARK: – Recording indicator

    func setRecording(_ recording: Bool) {
        let cfg  = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        let name = recording ? "record.circle.fill" : "camera.viewfinder"
        let img  = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        statusItem?.button?.image = img
        statusItem?.button?.contentTintColor = recording ? .systemRed : .labelColor
    }

    // MARK: – Menu actions

    @objc private func menuCaptureArea()       { CaptureManager.shared.captureArea() }
    @objc private func menuCaptureFullscreen() { CaptureManager.shared.captureFullscreen() }
    @objc private func menuRecordVideo()       { CaptureManager.shared.toggleVideo() }
    @objc private func menuSettings()          { SettingsWindowController.show() }

    @objc private func menuSetFormat(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let fmt = Preferences.ImageFormat(rawValue: raw) else { return }
        Preferences.shared.imageFormat = fmt
    }

    @objc private func menuSetAutoDelete(_ sender: NSMenuItem) {
        guard let val = (sender.representedObject as? NSNumber)?.intValue else { return }
        Preferences.shared.autoDeleteSeconds = val
    }

    @objc private func menuSetAnnotationClose(_ sender: NSMenuItem) {
        guard let val = (sender.representedObject as? NSNumber)?.intValue else { return }
        Preferences.shared.annotationCloseSeconds = val
    }

    @objc private func menuSetCaptureDelay(_ sender: NSMenuItem) {
        guard let val = (sender.representedObject as? NSNumber)?.intValue else { return }
        Preferences.shared.captureDelaySeconds = val
    }

    // MARK: – Label helpers

    private func autoDeleteLabel(_ secs: Int) -> String {
        switch secs {
        case 0:    return "Off"
        case 30:   return "30 s"
        case 60:   return "1 min"
        case 300:  return "5 min"
        case 1800: return "30 min"
        default:   return "\(secs) s"
        }
    }

    private func secondsLabel(_ secs: Int, offLabel: String) -> String {
        secs == 0 ? offLabel : "\(secs) s"
    }

    // MARK: – App icon

    private func makeAppIcon() -> NSImage {
        let side: CGFloat = 256
        let img = NSImage(size: NSSize(width: side, height: side))
        img.lockFocus()
        defer { img.unlockFocus() }

        let path = NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: img.size),
            xRadius: side * 0.225, yRadius: side * 0.225
        )
        NSGradient(colors: [
            NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.95, alpha: 1),
            NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.62, alpha: 1),
        ])!.draw(in: path, angle: -50)

        let cfg = NSImage.SymbolConfiguration(pointSize: side * 0.46, weight: .medium)
        if let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let tinted = NSImage(size: icon.size)
            tinted.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: icon.size))
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.setBlendMode(.sourceAtop)
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
                ctx.fill(CGRect(origin: .zero, size: icon.size))
                ctx.setBlendMode(.normal)
            }
            tinted.unlockFocus()
            let iw = tinted.size.width, ih = tinted.size.height
            tinted.draw(in: NSRect(x: (side - iw) / 2, y: (side - ih) / 2, width: iw, height: ih),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
        return img
    }

    // MARK: – Screen Recording permission

    private func requestScreenRecordingIfNeeded() {
        if CGPreflightScreenCaptureAccess() { return }
        // Trigger the OS-level permission prompt so ScreenCapture appears in
        // System Settings → Privacy & Security → Screen Recording. The actual
        // grant has to be done manually; we don't block hotkey setup on it.
        CGRequestScreenCaptureAccess()
        NSLog("[AppDelegate] Screen Recording not granted — hotkeys will work but capture will alert the user")
    }

    private func startHotkeyManager() {
        hotkeyManager = HotkeyManager()
    }
}
