import AppKit
import CoreGraphics

final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    private static var shared: SettingsWindowController?

    static func show() {
        if shared == nil { shared = SettingsWindowController() }
        NSApp.activate(ignoringOtherApps: true)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: – Outlets

    // Capture tab
    private var formatControl:     NSSegmentedControl!
    private var qualitySlider:     NSSlider!
    private var qualityValueLabel: NSTextField!
    private var qualityRowViews:   [NSView] = []
    private var delayPopup:        NSPopUpButton!
    private var soundCheck:        NSButton!
    private var saveFolderCheck:   NSButton!
    private var folderPathLabel:   NSTextField!
    private var folderRowViews:    [NSView] = []

    // Annotation tab
    private var annotClosePopup: NSPopUpButton!

    // Video tab
    private var videoCodecPopup:  NSPopUpButton!
    private var videoRegionPopup: NSPopUpButton!

    // Privacy tab
    private var autoDeletePopup: NSPopUpButton!

    // MARK: – Init

    init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
            styleMask:   [.titled, .closable, .miniaturizable],
            backing:     .buffered,
            defer:       false
        )
        win.title = "Screen Capture"
        win.setFrameAutosaveName("ScreenCaptureSettings")
        win.center()
        super.init(window: win)
        win.delegate = self
        buildUI()
        loadPreferences()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: – UI

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let tabView = NSTabView(frame: cv.bounds)
        tabView.autoresizingMask = [.width, .height]
        cv.addSubview(tabView)

        // Query content rect while tabView is in the view hierarchy but before
        // tab items are added — gives us the actual drawable area dimensions.
        let cr = tabView.contentRect

        tabView.addTabViewItem(tabItem("Capture",    view: makeCaptureTab(size: cr.size)))
        tabView.addTabViewItem(tabItem("Annotation", view: makeAnnotationTab(size: cr.size)))
        tabView.addTabViewItem(tabItem("Video",      view: makeVideoTab(size: cr.size)))
        tabView.addTabViewItem(tabItem("Privacy",    view: makePrivacyTab(size: cr.size)))
        tabView.addTabViewItem(tabItem("About",      view: makeAboutTab(size: cr.size)))
    }

    private func tabItem(_ title: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem()
        item.label = title
        item.view  = view
        return item
    }

    // MARK: – Capture tab

    private func makeCaptureTab(size: NSSize) -> NSView {
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        var y = size.height - 12

        formatControl = NSSegmentedControl(
            labels: Preferences.ImageFormat.allCases.map(\.label),
            trackingMode: .selectOne, target: self, action: #selector(formatChanged)
        )
        formatControl.segmentStyle = .rounded
        y = row(label("Format"), formatControl, y, v)

        // HEIF quality — hidden while PNG is selected
        qualitySlider = NSSlider(value: 90, minValue: 50, maxValue: 100,
                                 target: self, action: #selector(qualityChanged))
        qualitySlider.isContinuous = true
        qualityValueLabel = trailingLabel("90%")
        let qRow = hstack([
            (qualitySlider,     NSRect(x: 0,   y: 0, width: 152, height: 20)),
            (qualityValueLabel, NSRect(x: 158, y: 1, width:  38, height: 18)),
        ])
        let qLabel = label("HEIF quality")
        y = row(qLabel, qRow, y, v)
        qualityRowViews = [qLabel, qRow]

        delayPopup = popup([("None", 0), ("3 s", 3), ("5 s", 5), ("10 s", 10)],
                           #selector(delayChanged))
        y = row(label("Capture delay"), delayPopup, y, v)

        soundCheck = checkBox("Play shutter sound", #selector(soundChanged))
        y = row(label(""), soundCheck, y, v)

        y -= 10; separator(y, v); y -= 14

        // Save-to-folder toggle
        saveFolderCheck = checkBox("Save copy to folder", #selector(saveFolderToggled))
        y = row(label(""), saveFolderCheck, y, v)

        // Path display + Choose button (visible only when toggle is on)
        folderPathLabel = NSTextField(labelWithString: "Not set")
        folderPathLabel.font          = .systemFont(ofSize: 11)
        folderPathLabel.textColor     = .secondaryLabelColor
        folderPathLabel.lineBreakMode = .byTruncatingMiddle

        let chooseBtn = NSButton(title: "Choose…", target: self,
                                 action: #selector(chooseFolderClicked))
        chooseBtn.bezelStyle = .rounded
        chooseBtn.font       = .systemFont(ofSize: 11)

        let pathRow = hstack([
            (folderPathLabel, NSRect(x: 0,   y: 3, width: 178, height: 16)),
            (chooseBtn,       NSRect(x: 184, y: 0, width:  76, height: 22)),
        ])
        let folderLbl = label("Folder")
        y = row(folderLbl, pathRow, y, v)
        folderRowViews = [folderLbl, pathRow]

        return v
    }

    // MARK: – Annotation tab

    private func makeAnnotationTab(size: NSSize) -> NSView {
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        var y = size.height - 12

        annotClosePopup = popup(
            [("Off — manual close", 0), ("2 s", 2), ("5 s", 5),
             ("10 s", 10), ("30 s", 30), ("60 s", 60)],
            #selector(annotCloseChanged)
        )
        y = row(label("Auto-close"), annotClosePopup, y, v)

        let note = NSTextField(labelWithString:
            "Default tool and colour settings coming in a future update.")
        note.frame     = NSRect(x: 20, y: y - 20, width: 420, height: 16)
        note.font      = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        v.addSubview(note)

        return v
    }

    // MARK: – Video tab

    private func makeVideoTab(size: NSSize) -> NSView {
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        var y = size.height - 12

        videoCodecPopup = NSPopUpButton()
        videoCodecPopup.target = self
        videoCodecPopup.action = #selector(videoCodecChanged)
        for c in Preferences.VideoCodec.allCases {
            videoCodecPopup.addItem(withTitle: c.menuLabel)
            videoCodecPopup.lastItem?.representedObject = c.rawValue
        }
        y = row(label("Codec"), videoCodecPopup, y, v)

        videoRegionPopup = NSPopUpButton()
        videoRegionPopup.target = self
        videoRegionPopup.action = #selector(videoRegionChanged)
        for r in Preferences.VideoRegion.allCases {
            videoRegionPopup.addItem(withTitle: r.label)
            videoRegionPopup.lastItem?.representedObject = r.rawValue
        }
        y = row(label("Recording region"), videoRegionPopup, y, v)

        let note = NSTextField(labelWithString:
            "“Selected area” shows a crosshair after pressing ⌃⇧R so you can drag a region.\n“Full screen” starts recording immediately on the main display.")
        note.frame     = NSRect(x: 20, y: y - 38, width: 420, height: 34)
        note.font      = .systemFont(ofSize: 11)
        note.textColor = .tertiaryLabelColor
        note.maximumNumberOfLines = 2
        v.addSubview(note)

        return v
    }

    // MARK: – Privacy tab

    private func makePrivacyTab(size: NSSize) -> NSView {
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        var y = size.height - 12

        autoDeletePopup = popup(
            [("Off", 0), ("30 s", 30), ("1 min", 60), ("5 min", 300), ("30 min", 1800)],
            #selector(autoDeleteChanged)
        )
        y = row(label("Clear clipboard"), autoDeletePopup, y, v)

        return v
    }

    // MARK: – About tab

    private func makeAboutTab(size: NSSize) -> NSView {
        let v = NSView(frame: NSRect(origin: .zero, size: size))
        var y = size.height - 12

        y = sectionHead("Permissions", y, v)

        permissionRow(title:   "Screen Recording",
                      detail:  "Required for screenshots and video",
                      granted: CGPreflightScreenCaptureAccess(),
                      url:     "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                      y:       &y, in: v)
        y -= 8
        permissionRow(title:   "Accessibility",
                      detail:  "Required for global hotkeys",
                      granted: AXIsProcessTrusted(),
                      url:     "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                      y:       &y, in: v)

        y -= 10; separator(y, v); y -= 14

        y = sectionHead("Shortcuts", y, v)

        for (name, key) in [("Capture Area", "⌃⇧S"), ("Capture Fullscreen", "⌃⇧F"),
                             ("Record Video", "⌃⇧R"), ("Quit", "⌃⇧Q")] {
            let nameLbl = NSTextField(labelWithString: name)
            nameLbl.frame     = NSRect(x: 20, y: y - 18, width: 220, height: 18)
            nameLbl.font      = .systemFont(ofSize: 13)
            nameLbl.textColor = .labelColor
            v.addSubview(nameLbl)

            let keyLbl = NSTextField(labelWithString: key)
            keyLbl.frame     = NSRect(x: 310, y: y - 18, width: 120, height: 18)
            keyLbl.font      = .monospacedSystemFont(ofSize: 12, weight: .regular)
            keyLbl.textColor = .secondaryLabelColor
            keyLbl.alignment = .right
            v.addSubview(keyLbl)

            y -= 22
        }

        return v
    }

    // MARK: – Load / sync

    private func loadPreferences() {
        let p = Preferences.shared

        formatControl.selectedSegment = p.imageFormat == .heif ? 1 : 0
        qualitySlider.integerValue    = Int(p.heifQuality * 100)
        qualityValueLabel.stringValue = "\(Int(p.heifQuality * 100))%"
        updateQualityVisibility()

        selectPopup(delayPopup,      value: p.captureDelaySeconds)
        soundCheck.state             = p.captureSound  ? .on : .off
        saveFolderCheck.state        = p.saveToFolder  ? .on : .off
        refreshFolderPath()
        updateFolderVisibility()

        selectPopup(annotClosePopup, value: p.annotationCloseSeconds)
        selectPopup(autoDeletePopup, value: p.autoDeleteSeconds)
        selectStringPopup(videoCodecPopup,  rawValue: p.videoCodec.rawValue)
        selectStringPopup(videoRegionPopup, rawValue: p.videoRegion.rawValue)
    }

    private func selectStringPopup(_ p: NSPopUpButton, rawValue: String) {
        for item in p.itemArray where (item.representedObject as? String) == rawValue {
            p.select(item); return
        }
        p.selectItem(at: 0)
    }

    private func updateQualityVisibility() {
        let show = Preferences.shared.imageFormat == .heif
        qualityRowViews.forEach { $0.isHidden = !show }
    }

    private func updateFolderVisibility() {
        let show = Preferences.shared.saveToFolder
        folderRowViews.forEach { $0.isHidden = !show }
    }

    private func refreshFolderPath() {
        if let path = Preferences.shared.saveFolderPath {
            folderPathLabel.stringValue = URL(fileURLWithPath: path).lastPathComponent
            folderPathLabel.toolTip     = path
        } else {
            folderPathLabel.stringValue = "Not set"
            folderPathLabel.toolTip     = nil
        }
    }

    // MARK: – Actions

    @objc private func formatChanged() {
        Preferences.shared.imageFormat = formatControl.selectedSegment == 1 ? .heif : .png
        updateQualityVisibility()
    }

    @objc private func qualityChanged() {
        let v = qualitySlider.integerValue
        qualityValueLabel.stringValue  = "\(v)%"
        Preferences.shared.heifQuality = Double(v) / 100
    }

    @objc private func delayChanged()      { Preferences.shared.captureDelaySeconds    = popupValue(delayPopup) }
    @objc private func soundChanged()      { Preferences.shared.captureSound           = soundCheck.state == .on }
    @objc private func annotCloseChanged() { Preferences.shared.annotationCloseSeconds = popupValue(annotClosePopup) }
    @objc private func autoDeleteChanged() { Preferences.shared.autoDeleteSeconds      = popupValue(autoDeletePopup) }

    @objc private func videoCodecChanged() {
        if let raw = videoCodecPopup.selectedItem?.representedObject as? String,
           let c   = Preferences.VideoCodec(rawValue: raw) {
            Preferences.shared.videoCodec = c
        }
    }
    @objc private func videoRegionChanged() {
        if let raw = videoRegionPopup.selectedItem?.representedObject as? String,
           let r   = Preferences.VideoRegion(rawValue: raw) {
            Preferences.shared.videoRegion = r
        }
    }

    @objc private func saveFolderToggled() {
        Preferences.shared.saveToFolder = saveFolderCheck.state == .on
        updateFolderVisibility()
    }

    @objc private func chooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles          = false
        panel.canChooseDirectories    = true
        panel.canCreateDirectories    = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder where screenshot copies will be saved."
        panel.prompt  = "Choose"
        panel.directoryURL = Preferences.shared.saveFolderPath
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Preferences.shared.saveFolderPath = url.path
        Preferences.shared.saveToFolder   = true
        saveFolderCheck.state = .on
        refreshFolderPath()
        updateFolderVisibility()
    }

    @objc private func openSystemSettings(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: – Layout helpers

    /// Left-column label + right-column control; returns next y.
    @discardableResult
    private func row(_ lbl: NSTextField, _ ctrl: NSView,
                     _ y: CGFloat, _ parent: NSView) -> CGFloat {
        lbl.frame  = NSRect(x: 20,  y: y - 22, width: 130, height: 18)
        ctrl.frame = NSRect(x: 158, y: y - 26, width: 260, height: 26)
        parent.addSubview(lbl)
        parent.addSubview(ctrl)
        return y - 34
    }

    private func label(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font      = .systemFont(ofSize: 13)
        f.textColor = .labelColor
        return f
    }

    private func trailingLabel(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font      = .monospacedSystemFont(ofSize: 11, weight: .regular)
        f.textColor = .secondaryLabelColor
        f.alignment = .right
        return f
    }

    private func checkBox(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.font = .systemFont(ofSize: 13)
        return b
    }

    /// Container view sized to hold the given (subview, frame) pairs.
    private func hstack(_ items: [(NSView, NSRect)]) -> NSView {
        var w: CGFloat = 0, h: CGFloat = 0
        for (_, r) in items { w = max(w, r.maxX); h = max(h, r.maxY) }
        let c = NSView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        for (sv, r) in items { sv.frame = r; c.addSubview(sv) }
        return c
    }

    private func popup(_ options: [(String, Int)], _ action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton()
        p.target = self; p.action = action
        for (title, val) in options {
            p.addItem(withTitle: title)
            p.lastItem?.representedObject = val as NSNumber
        }
        return p
    }

    private func selectPopup(_ p: NSPopUpButton, value: Int) {
        for item in p.itemArray where (item.representedObject as? NSNumber)?.intValue == value {
            p.select(item); return
        }
        p.selectItem(at: 0)
    }

    private func popupValue(_ p: NSPopUpButton) -> Int {
        (p.selectedItem?.representedObject as? NSNumber)?.intValue ?? 0
    }

    @discardableResult
    private func sectionHead(_ text: String, _ y: CGFloat, _ parent: NSView) -> CGFloat {
        let lbl = NSTextField(labelWithString: text.uppercased())
        lbl.frame     = NSRect(x: 20, y: y - 16, width: 420, height: 14)
        lbl.font      = .systemFont(ofSize: 10, weight: .semibold)
        lbl.textColor = .secondaryLabelColor
        parent.addSubview(lbl)
        return y - 22
    }

    private func separator(_ y: CGFloat, _ parent: NSView) {
        let sep = NSBox(); sep.boxType = .separator
        sep.frame = NSRect(x: 20, y: y, width: 420, height: 1)
        parent.addSubview(sep)
    }

    private func permissionRow(title: String, detail: String, granted: Bool,
                                url: String, y: inout CGFloat, in parent: NSView) {
        let dot = NSView(frame: NSRect(x: 20, y: y - 14, width: 10, height: 10))
        dot.wantsLayer = true
        dot.layer?.cornerRadius  = 5
        dot.layer?.backgroundColor = (granted ? NSColor.systemGreen : NSColor.systemOrange).cgColor
        parent.addSubview(dot)

        let titleLbl = NSTextField(labelWithString: title)
        titleLbl.frame = NSRect(x: 38, y: y - 14, width: 220, height: 16)
        titleLbl.font  = .systemFont(ofSize: 13, weight: .medium)
        titleLbl.textColor = .labelColor
        parent.addSubview(titleLbl)

        let statusLbl = NSTextField(labelWithString: granted ? "Granted" : "Not granted")
        statusLbl.frame     = NSRect(x: 38, y: y - 30, width: 220, height: 14)
        statusLbl.font      = .systemFont(ofSize: 11)
        statusLbl.textColor = granted ? .systemGreen : .systemOrange
        parent.addSubview(statusLbl)

        let detailLbl = NSTextField(labelWithString: detail)
        detailLbl.frame     = NSRect(x: 38, y: y - 44, width: 220, height: 14)
        detailLbl.font      = .systemFont(ofSize: 11)
        detailLbl.textColor = .tertiaryLabelColor
        parent.addSubview(detailLbl)

        let btn = NSButton(title: "Open Settings", target: self,
                           action: #selector(openSystemSettings(_:)))
        btn.bezelStyle = .rounded
        btn.font       = .systemFont(ofSize: 11)
        btn.frame      = NSRect(x: 314, y: y - 36, width: 116, height: 24)
        btn.identifier = NSUserInterfaceItemIdentifier(url)
        parent.addSubview(btn)

        y -= 54
    }

    // MARK: – NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        SettingsWindowController.shared = nil
    }
}
