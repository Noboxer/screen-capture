import AppKit

/// Persistent overlay shown while recording a selected region (#11): dims the whole
/// screen except the recorded area and draws a red "recording" border around it.
///
/// All drawing stays OUTSIDE the recorded rect (the region is punched clear and the
/// border sits just outside it), and the recorder only captures `sourceRect`, so the
/// overlay never appears in the video. The window is click-through so the user can
/// keep working while recording.
final class RecordingOverlay {

    static let shared = RecordingOverlay()
    private init() {}

    private var window: NSWindow?

    /// `region` is in AppKit screen coordinates (y-up) on `screen`.
    func show(region: CGRect, on screen: NSScreen) {
        hide()

        let win = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                           backing: .buffered, defer: false)
        win.isOpaque             = false
        win.backgroundColor      = .clear
        win.level                = .screenSaver          // above app windows and the menu bar
        win.ignoresMouseEvents   = true                  // click-through
        win.hasShadow            = false
        win.collectionBehavior   = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Convert the region to window-local coordinates (window frame == screen frame).
        let local = CGRect(x: region.origin.x - screen.frame.origin.x,
                           y: region.origin.y - screen.frame.origin.y,
                           width: region.width, height: region.height)
        let view = RecordingOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.region = local
        win.contentView = view
        win.orderFrontRegardless()
        window = win
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }
}

private final class RecordingOverlayView: NSView {
    var region: CGRect = .zero { didSet { needsDisplay = true } }

    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dim the whole screen, then punch a fully-transparent hole over the
        // recorded region so it shows through at full brightness.
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.32))
        ctx.fill(bounds)
        ctx.clear(region)

        // Red border just OUTSIDE the region (inset negative) so no border pixels
        // fall inside the recorded rect.
        let border = region.insetBy(dx: -2, dy: -2)
        ctx.setStrokeColor(NSColor.systemRed.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(border)
    }
}
