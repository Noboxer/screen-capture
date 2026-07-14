import AppKit

/// Overlay shown while recording (#11/#12). For a selected region it dims the rest
/// of the screen and outlines the recorded area; in all cases it shows a small HUD
/// with a blinking record dot, an elapsed timer, and a Stop button.
///
/// The overlay/HUD windows are handed to the recorder to exclude from the capture
/// (see CaptureManager → VideoRecorder), and for region recordings all drawing also
/// stays outside the recorded rect — so none of this appears in the video. The dim
/// window is click-through; the HUD accepts clicks for the Stop button.
final class RecordingOverlay {

    static let shared = RecordingOverlay()
    private init() {}

    private var dimWindow: NSWindow?
    private var hudWindow: NSWindow?
    private var hud: RecordingHUDView?
    private var timer: Timer?
    private var elapsed = 0

    /// Window numbers to exclude from the capture stream.
    func windowNumbers() -> [Int] {
        [dimWindow?.windowNumber, hudWindow?.windowNumber].compactMap { $0 }
    }

    /// Region recording: dim + outline + HUD. `region` is AppKit screen coords.
    func show(region: CGRect, on screen: NSScreen, onStop: @escaping () -> Void) {
        hide()
        makeDimWindow(region: region, on: screen)
        makeHUD(anchoredTo: region, on: screen, onStop: onStop)
        startTimer()
    }

    /// Fullscreen recording: HUD only (no dim), anchored near the top of the screen.
    func showControlsOnly(on screen: NSScreen, onStop: @escaping () -> Void) {
        hide()
        makeHUD(anchoredTo: nil, on: screen, onStop: onStop)
        startTimer()
    }

    func hide() {
        timer?.invalidate(); timer = nil
        elapsed = 0
        dimWindow?.orderOut(nil); dimWindow = nil
        hudWindow?.orderOut(nil); hudWindow = nil
        hud = nil
    }

    // MARK: - Windows

    private func makeDimWindow(region: CGRect, on screen: NSScreen) {
        let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isOpaque           = false
        win.backgroundColor    = .clear
        win.level              = .screenSaver
        win.ignoresMouseEvents = true
        win.hasShadow          = false
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let local = CGRect(x: region.origin.x - screen.frame.origin.x,
                           y: region.origin.y - screen.frame.origin.y,
                           width: region.width, height: region.height)
        let view = RecordingDimView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.region = local
        win.contentView = view
        win.orderFrontRegardless()
        dimWindow = win
    }

    private func makeHUD(anchoredTo region: CGRect?, on screen: NSScreen, onStop: @escaping () -> Void) {
        let size = NSSize(width: 188, height: 44)

        // Position: below the region (or above if no room); centered on it. For
        // fullscreen (no region) sit near the top-center of the screen.
        let origin: NSPoint
        if let region {
            let x = region.midX - size.width / 2
            let belowY = region.minY - size.height - 14
            let aboveY = region.maxY + 14
            let y = belowY >= screen.frame.minY + 8 ? belowY : aboveY
            origin = NSPoint(x: x, y: y)
        } else {
            origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.maxY - size.height - 24)
        }

        let win = NSWindow(contentRect: NSRect(origin: origin, size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        win.isOpaque           = false
        win.backgroundColor    = .clear
        win.level              = .screenSaver
        win.ignoresMouseEvents = false
        win.hasShadow          = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let view = RecordingHUDView(frame: NSRect(origin: .zero, size: size))
        view.onStop = onStop
        win.contentView = view
        win.orderFrontRegardless()
        hudWindow = win
        hud = view
    }

    // MARK: - Timer

    private func startTimer() {
        elapsed = 0
        hud?.update(elapsed: 0)
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed += 1
            self.hud?.update(elapsed: self.elapsed)
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

// MARK: - Dim / outline view

private final class RecordingDimView: NSView {
    var region: CGRect = .zero { didSet { needsDisplay = true } }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.32))
        ctx.fill(bounds)
        ctx.clear(region)                                  // recorded area shows through
        let border = region.insetBy(dx: -2, dy: -2)        // border sits just outside the rect
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(border)
    }
}

// MARK: - HUD view (record dot + timer + Stop)

private final class RecordingHUDView: NSView {
    var onStop: (() -> Void)?

    private let dot   = NSView()
    private let label = NSTextField(labelWithString: "0:00")
    private var blinkOn = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.11, alpha: 0.96).cgColor
        layer?.cornerRadius    = 12
        layer?.borderColor     = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.borderWidth     = 1

        dot.frame = NSRect(x: 16, y: bounds.midY - 5, width: 10, height: 10)
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius    = 5
        addSubview(dot)

        label.frame        = NSRect(x: 34, y: bounds.midY - 10, width: 74, height: 20)
        label.font         = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        label.textColor    = .white
        addSubview(label)

        let stop = NSButton(title: "Stop", target: self, action: #selector(stopClicked))
        stop.frame       = NSRect(x: bounds.maxX - 78, y: bounds.midY - 14, width: 62, height: 28)
        stop.bezelStyle  = .rounded
        stop.keyEquivalent = "\r"
        stop.contentTintColor = .systemRed
        stop.font        = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(stop)
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(elapsed: Int) {
        let h = elapsed / 3600, m = (elapsed % 3600) / 60, s = elapsed % 60
        label.stringValue = h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
        blinkOn.toggle()
        dot.layer?.opacity = blinkOn ? 1.0 : 0.25
    }

    @objc private func stopClicked() { onStop?() }
}
