import AppKit

private var openControllers: Set<AnnotationWindowController> = []

// Borderless window that can still become key (borderless NSWindow.canBecomeKey returns false by default).
private final class AnnotationWindow: NSWindow {
    override var canBecomeKey:  Bool { true }
    override var canBecomeMain: Bool { true }
}

final class AnnotationWindowController: NSWindowController, NSWindowDelegate,
                                         AnnotationCanvasDelegate {

    private var canvasView: AnnotationCanvasView!
    private var statusLabel: NSTextField!
    private var toolButtonRow: [NSButton] = []

    private var idleTimer:       Timer?
    private var autoCopyTimer:   Timer?
    private var editingStarted   = false

    // Inactivity auto-close countdown
    private var countdownTimer:    Timer?
    private var countdownSecsLeft: Int = 0
    private var countdownTotal:    Int = 0
    private var countdownBar:      NSView!   // thin accent bar at bottom edge
    private var prefsObserver:     NSObjectProtocol?
    private var eventMonitor:      Any?

    // Scale of the display the image was captured from. Stored so copyToClipboard
    // always uses source-display DPI rather than the annotation window's screen.
    private let captureScale: CGFloat

    static func open(image: CGImage, captureScale: CGFloat) {
        guard let controller = AnnotationWindowController(image: image, captureScale: captureScale) else {
            // Canvas allocation failed (e.g. weird image dims). Don't show a broken
            // window — just put the raw screenshot on the clipboard so the capture
            // isn't lost, and log it so we know it happened.
            NSLog("[AnnotationWindowController] Canvas init failed — skipping annotation, copying raw image")
            CaptureManager.shared.copyToClipboard(image, scale: captureScale)
            return
        }
        openControllers.insert(controller)
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }

    // MARK: – Init

    init?(image: CGImage, captureScale: CGFloat) {
        // Build the canvas first so we can bail before window allocation if it fails.
        guard let canvas = AnnotationCanvasView(image: image) else { return nil }

        self.captureScale = captureScale
        let screen   = NSScreen.main ?? NSScreen.screens[0]
        let scale    = captureScale  // use source-display scale for correct logical size
        let logicalW = CGFloat(image.width)  / scale
        let logicalH = CGFloat(image.height) / scale
        let toolbarH: CGFloat = 52
        let statusH:  CGFloat = 28

        // Minimum width required for the toolbar to render every control without
        // overlap. Sum of: 8 tools (32px each) + group gap + 7 colors (24px each) +
        // gap + size slider group (~100px) + center gap + 4 action buttons (~240px)
        // + edge padding. Keep this in sync with makeToolbar's layout math.
        let minToolbarW: CGFloat = 900

        let maxW  = screen.visibleFrame.width  * 0.92
        let maxH  = screen.visibleFrame.height * 0.92 - toolbarH - statusH
        let fit   = min(1.0, min(maxW / logicalW, maxH / logicalH))
        let canvasW  = logicalW * fit
        let canvasH  = logicalH * fit
        // Window width is whichever is larger: the scaled image, or the toolbar
        // minimum. When the image is narrower than the toolbar, the image is
        // centered horizontally inside a wider canvas area (AnnotationCanvasView's
        // imageRect already aspect-fits and centers the bitmap, so no extra
        // positioning logic is needed here).
        let windowW = min(maxW, max(canvasW, minToolbarW))
        let totalH  = canvasH + toolbarH + statusH
        let origin  = NSPoint(
            x: screen.visibleFrame.midX - windowW / 2,
            y: screen.visibleFrame.midY - totalH  / 2
        )

        // Borderless window eliminates the title-bar drag region.
        // .resizable is intentionally OMITTED — on a borderless window it adds an
        // invisible resize ring around the edges that intercepts mouseDown events
        // intended for drawing, causing the window to shift when the user draws
        // near a canvas edge. Size is computed once and never needs to change.
        let win = AnnotationWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: windowW, height: totalH)),
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false
        )
        // Transparent window + rounded layer-backed content view yields a
        // proper rounded-rect window with shadow tracking the rounded shape.
        win.backgroundColor             = .clear
        win.isOpaque                    = false
        win.isMovable                   = false
        win.isMovableByWindowBackground = false
        win.hasShadow                   = true
        win.level                       = .floating
        win.appearance                  = NSAppearance(named: .darkAqua)

        super.init(window: win)
        win.delegate = self

        // Round the content view's layer. masksToBounds clips all subviews
        // (toolbar, canvas, status bar) to the rounded rectangle.
        if let contentView = win.contentView {
            contentView.wantsLayer = true
            contentView.layer?.cornerRadius  = 12
            contentView.layer?.masksToBounds = true
            contentView.layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
            contentView.layer?.borderColor   = NSColor.white.withAlphaComponent(0.08).cgColor
            contentView.layer?.borderWidth   = 1
        }

        canvasView = canvas
        canvasView.delegate     = self
        canvasView.frame        = NSRect(x: 0, y: statusH, width: windowW, height: canvasH)
        canvasView.autoresizingMask = [.width, .height]

        let toolbar = makeToolbar(width: windowW, toolbarH: toolbarH, canvasY: statusH + canvasH)

        statusLabel = NSTextField(labelWithString: "Copied  ·  Start drawing to annotate  ·  Closes in 3 s")
        statusLabel.frame        = NSRect(x: 12, y: 7, width: windowW - 24, height: 16)
        statusLabel.font         = .systemFont(ofSize: 11)
        statusLabel.textColor    = .secondaryLabelColor
        statusLabel.autoresizingMask = .width

        // 2-px accent bar anchored to the bottom edge of the content view.
        // Width drains from full → 0 over the countdown period.
        countdownBar = NSView(frame: NSRect(x: 0, y: 0, width: windowW, height: 2))
        countdownBar.wantsLayer = true
        countdownBar.layer?.backgroundColor =
            NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        countdownBar.isHidden = true

        win.contentView?.addSubview(canvasView)
        win.contentView?.addSubview(toolbar)
        win.contentView?.addSubview(statusLabel)
        win.contentView?.addSubview(countdownBar)

        // Restart / cancel countdown whenever Preferences.annotationCloseSeconds changes.
        prefsObserver = NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in self?.startOrResetCountdown() }

        // Any click, key press, or scroll in this window resets the inactivity clock.
        // Cmd+Q / Cmd+W are intercepted here (not via menu) because the daemon is
        // an accessory app — it has no app menu, so the standard quit-via-menu
        // shortcut never fires. The monitor runs before the text-field editor
        // sees the event, so the shortcut still works while editing text.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp,
                       .rightMouseDown, .keyDown, .scrollWheel]
        ) { [weak self] event in
            guard event.window === self?.window else { return event }

            if event.type == .keyDown,
               event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers?.lowercased(),
               chars == "q" || chars == "w" {
                self?.commitAndClose()
                return nil   // consume so NSBeep / text-field don't react
            }

            self?.startOrResetCountdown()
            return event
        }

        copyCurrentToClipboard()
        // If auto-close is configured the countdown timer handles dismissal;
        // the 3-second idle timer is only needed when it is disabled.
        if Preferences.shared.annotationCloseSeconds == 0 {
            scheduleIdleTimer()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: – Toolbar

    private func makeToolbar(width: CGFloat, toolbarH: CGFloat, canvasY: CGFloat) -> NSView {
        let bar = NSView(frame: NSRect(x: 0, y: canvasY, width: width, height: toolbarH))
        bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        bar.autoresizingMask = [.width, .minYMargin]

        // 1-px hairline between toolbar bottom and canvas top
        let sep = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        sep.autoresizingMask = .width
        bar.addSubview(sep)

        // ── Left group: tool icons ───────────────────────────────────────────
        var x: CGFloat = 14

        let tools: [(String, DrawingTool)] = [
            ("pencil",      .pen),
            ("highlighter", .highlight),
            ("arrow.right", .arrow),
            ("minus",       .line),
            ("rectangle",   .rect),
            ("circle",      .ellipse),
            ("textformat",  .text),
            ("eye.slash",   .blur),
        ]

        toolButtonRow = []
        for (symbol, drawTool) in tools {
            let btn = makeIconButton(symbol: symbol)
            btn.frame  = NSRect(x: x, y: (toolbarH - 30) / 2, width: 30, height: 30)
            btn.tag    = toolTag(drawTool)
            btn.target = self
            btn.action = #selector(toolSelected(_:))
            bar.addSubview(btn)
            toolButtonRow.append(btn)
            x += 32
        }
        setToolHighlight(toolButtonRow.first)

        // Vertical group divider
        x += 8
        addGroupDivider(at: x, toolbarH: toolbarH, in: bar)
        x += 12

        // ── Color swatches ───────────────────────────────────────────────────
        let colors: [NSColor] = [.systemRed, .systemOrange, .systemYellow,
                                  .systemGreen, .systemCyan, .white, .black]
        for c in colors {
            let sw = ColorSwatchButton(color: c, size: 20)
            sw.frame   = NSRect(x: x, y: (toolbarH - 20) / 2, width: 20, height: 20)
            sw.target  = self
            sw.action  = #selector(colorSelected(_:))
            bar.addSubview(sw)
            x += 26
        }

        x += 6
        addGroupDivider(at: x, toolbarH: toolbarH, in: bar)
        x += 12

        // ── Stroke-size slider ───────────────────────────────────────────────
        let sizeIconCfg = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        let sizeIcon = NSImageView()
        sizeIcon.image = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle",
                                 accessibilityDescription: "Stroke size")?
            .withSymbolConfiguration(sizeIconCfg)
        sizeIcon.contentTintColor = NSColor(white: 0.65, alpha: 1)
        sizeIcon.frame = NSRect(x: x, y: (toolbarH - 16) / 2, width: 16, height: 16)
        bar.addSubview(sizeIcon)
        x += 20

        let slider = NSSlider(value: 4, minValue: 1, maxValue: 20,
                              target: self, action: #selector(sizeChanged(_:)))
        slider.frame = NSRect(x: x, y: (toolbarH - 20) / 2, width: 90, height: 20)
        bar.addSubview(slider)

        // ── Right group: action buttons (placed right-to-left) ───────────────
        // Each button is uniform width so the row reads cleanly. Buttons use a
        // hand-rolled style so accent / cancel / default visually differentiate.
        let btnW: CGFloat = 72
        let btnH: CGFloat = 28
        let btnGap: CGFloat = 8
        let btnY  = (toolbarH - btnH) / 2

        var rx = width - 14

        let doneBtn = makeActionButton("Done", action: #selector(done), style: .accent)
        doneBtn.frame = NSRect(x: rx - btnW, y: btnY, width: btnW, height: btnH)
        bar.addSubview(doneBtn)
        rx -= (btnW + btnGap)

        let cancelBtn = makeActionButton("Cancel", action: #selector(cancel), style: .secondary)
        cancelBtn.frame = NSRect(x: rx - btnW, y: btnY, width: btnW, height: btnH)
        bar.addSubview(cancelBtn)
        rx -= (btnW + btnGap)

        addGroupDivider(at: rx - 4, toolbarH: toolbarH, in: bar)
        rx -= 16

        let clearBtn = makeActionButton("Clear", action: #selector(clearAll), style: .ghost)
        clearBtn.frame = NSRect(x: rx - btnW, y: btnY, width: btnW, height: btnH)
        bar.addSubview(clearBtn)
        rx -= (btnW + btnGap)

        let undoBtn = makeActionButton("Undo", action: #selector(undoStroke), style: .ghost)
        undoBtn.frame = NSRect(x: rx - btnW, y: btnY, width: btnW, height: btnH)
        bar.addSubview(undoBtn)

        return bar
    }

    /// Thin vertical line between toolbar sections — same color as the bottom hairline.
    private func addGroupDivider(at x: CGFloat, toolbarH: CGFloat, in bar: NSView) {
        let h: CGFloat = toolbarH - 20
        let d = NSView(frame: NSRect(x: x, y: (toolbarH - h) / 2, width: 1, height: h))
        d.wantsLayer = true
        d.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        bar.addSubview(d)
    }

    private func makeIconButton(symbol: String) -> NSButton {
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        let btn = NSButton()
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        btn.bezelStyle       = .smallSquare
        btn.isBordered       = false
        btn.wantsLayer       = true
        btn.layer?.cornerRadius  = 6
        btn.contentTintColor = NSColor(white: 0.85, alpha: 1)
        return btn
    }

    /// Hand-rolled button style so we control color/state across all action buttons
    /// uniformly. NSButton's .rounded bezel adopts the window's appearance and
    /// produces inconsistent results inside a dark borderless window.
    enum ActionButtonStyle { case accent, secondary, ghost }

    private final class ActionButton: NSButton {
        var styleKind: ActionButtonStyle = .ghost
        override func updateLayer() {
            guard let layer else { return }
            switch styleKind {
            case .accent:
                layer.backgroundColor = NSColor.controlAccentColor.cgColor
                layer.borderColor     = NSColor.white.withAlphaComponent(0.15).cgColor
                layer.borderWidth     = 1
            case .secondary:
                layer.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
                layer.borderColor     = NSColor.white.withAlphaComponent(0.18).cgColor
                layer.borderWidth     = 1
            case .ghost:
                layer.backgroundColor = NSColor.clear.cgColor
                layer.borderColor     = NSColor.white.withAlphaComponent(0.18).cgColor
                layer.borderWidth     = 1
            }
        }
    }

    private func makeActionButton(_ title: String,
                                  action: Selector,
                                  style: ActionButtonStyle) -> NSButton {
        let btn = ActionButton(title: "", target: self, action: action)
        btn.isBordered      = false
        btn.bezelStyle      = .smallSquare
        btn.styleKind       = style
        btn.wantsLayer      = true
        btn.layer?.cornerRadius = 6
        btn.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.white,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            ]
        )
        return btn
    }

    private func setToolHighlight(_ selected: NSButton?) {
        for btn in toolButtonRow {
            let isSelected = btn === selected
            btn.layer?.backgroundColor = (isSelected
                ? NSColor.controlAccentColor.withAlphaComponent(0.55)
                : NSColor.clear).cgColor
            btn.layer?.borderColor = NSColor.white.withAlphaComponent(0.50).cgColor
            btn.layer?.borderWidth = isSelected ? 1 : 0
            btn.contentTintColor = isSelected ? .white : NSColor(white: 0.85, alpha: 1)
        }
    }

    // MARK: – Toolbar actions

    @objc private func toolSelected(_ sender: NSButton) {
        canvasView.style.tool = toolFromTag(sender.tag)
        setToolHighlight(sender)
    }

    @objc private func colorSelected(_ sender: ColorSwatchButton) {
        canvasView.style.color = sender.swatchColor
    }

    @objc private func sizeChanged(_ sender: NSSlider) {
        canvasView.style.size = CGFloat(sender.integerValue)
    }

    @objc private func undoStroke() { canvasView.undo();              scheduleAutoCopy() }
    @objc private func clearAll()   { canvasView.clearAnnotations();  scheduleAutoCopy() }
    @objc private func done()       { commitAndClose() }
    @objc private func cancel()     { NSPasteboard.general.clearContents(); window?.close() }

    // MARK: – AnnotationCanvasDelegate

    func canvasDidStartEditing() {
        guard !editingStarted else { return }
        editingStarted = true
        cancelIdleTimer()
        setStatus("Annotating  ·  Clipboard updates automatically")
    }

    func canvasDidFinishStroke() {
        scheduleAutoCopy()
    }

    // MARK: – Clipboard

    private func copyCurrentToClipboard() {
        guard let img = canvasView?.exportComposite() else { return }
        CaptureManager.shared.copyToClipboard(img, scale: captureScale)
    }

    private func scheduleAutoCopy() {
        autoCopyTimer?.invalidate()
        autoCopyTimer = makeTimer(interval: 0.3) { [weak self] in
            self?.copyCurrentToClipboard()
            self?.setStatus("Clipboard updated  ·  Paste anywhere")
        }
    }

    // MARK: – Timers

    private func scheduleIdleTimer() {
        var remaining = 3
        idleTimer = makeTimer(interval: 1, repeats: true) { [weak self] in
            guard let self else { return }
            remaining -= 1
            if remaining > 0 {
                setStatus("Copied  ·  Start drawing or closes in \(remaining) s")
            } else {
                cancelIdleTimer()
                commitAndClose()
            }
        }
    }

    private func cancelIdleTimer() { idleTimer?.invalidate(); idleTimer = nil }

    // Starts (or restarts) the inactivity countdown from the full configured duration.
    // Called from windowDidBecomeKey and by the local event monitor on every user action.
    private func startOrResetCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil

        let secs = Preferences.shared.annotationCloseSeconds
        guard secs > 0 else {
            countdownBar.isHidden = true
            return
        }

        countdownSecsLeft = secs
        countdownTotal    = secs

        // Snap bar back to full width instantly (jump communicates "timer reset").
        let fullWidth = window?.contentView?.bounds.width ?? countdownBar.superview?.bounds.width ?? 0
        countdownBar.frame    = NSRect(x: 0, y: 0, width: fullWidth, height: 2)
        countdownBar.isHidden = false

        countdownTimer = makeTimer(interval: 1, repeats: true) { [weak self] in
            guard let self else { return }
            countdownSecsLeft -= 1
            updateCountdownBar(animated: true)
            if countdownSecsLeft <= 5, countdownSecsLeft > 0 {
                setStatus("Closing in \(countdownSecsLeft) s  ·  Click or draw to cancel")
            }
            if countdownSecsLeft <= 0 { commitAndClose() }
        }
    }

    private func updateCountdownBar(animated: Bool) {
        guard countdownTotal > 0,
              let superview = countdownBar.superview else { return }
        let fraction    = CGFloat(max(0, countdownSecsLeft)) / CGFloat(countdownTotal)
        let targetWidth = superview.bounds.width * fraction
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.85  // slightly under 1 s so bar reaches target before next tick
                countdownBar.animator().frame =
                    NSRect(x: 0, y: 0, width: targetWidth, height: countdownBar.frame.height)
            }
        } else {
            countdownBar.frame = NSRect(x: 0, y: 0, width: targetWidth,
                                        height: countdownBar.frame.height)
        }
    }

    // Use .common run-loop mode so the timer fires even during mouse-event-tracking loops.
    @discardableResult
    private func makeTimer(interval: TimeInterval, repeats: Bool = false,
                           block: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: repeats) { _ in block() }
        RunLoop.main.add(t, forMode: .common)
        return t
    }

    private func commitAndClose() {
        autoCopyTimer?.invalidate()
        copyCurrentToClipboard()
        window?.close()
    }

    private func setStatus(_ msg: String) { statusLabel?.stringValue = msg }

    // MARK: – NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        idleTimer?.invalidate()
        autoCopyTimer?.invalidate()
        countdownTimer?.invalidate()
        if let obs = prefsObserver { NotificationCenter.default.removeObserver(obs) }
        if let mon = eventMonitor  { NSEvent.removeMonitor(mon) }
        openControllers.remove(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(canvasView)
        startOrResetCountdown()
    }

    // MARK: – Tag helpers

    private func toolTag(_ t: DrawingTool) -> Int {
        [.pen, .highlight, .arrow, .line, .rect, .ellipse, .text, .blur].firstIndex(of: t) ?? 0
    }

    private func toolFromTag(_ tag: Int) -> DrawingTool {
        let all: [DrawingTool] = [.pen, .highlight, .arrow, .line, .rect, .ellipse, .text, .blur]
        return tag < all.count ? all[tag] : .pen
    }
}

// MARK: – Color swatch button

final class ColorSwatchButton: NSButton {
    let swatchColor: NSColor
    init(color: NSColor, size: CGFloat) {
        self.swatchColor = color
        super.init(frame: .zero)
        wantsLayer = true
        isBordered = false
        layer?.backgroundColor = color.cgColor
        layer?.cornerRadius    = size / 2
        layer?.borderWidth     = 1.5
        layer?.borderColor     = NSColor.white.withAlphaComponent(0.25).cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
}
