import AppKit

// MARK: - Public entry point

@MainActor
enum SelectionOverlay {
    /// Shows a fullscreen crosshair overlay and returns the selected rect in
    /// AppKit screen coordinates (bottom-left origin), or nil if cancelled.
    static func selectRect() async -> CGRect? {
        await withCheckedContinuation { cont in
            let win = SelectionWindow()
            win.onCommit = { rect in
                cont.resume(returning: rect)
            }
            win.onCancel = {
                cont.resume(returning: nil)
            }
            win.makeKeyAndOrderFront(nil)
        }
    }
}

// MARK: - Overlay window

private final class SelectionWindow: NSWindow {

    var onCommit: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    init() {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        super.init(
            contentRect: screen.frame,
            styleMask:   .borderless,
            backing:     .buffered,
            defer:       false
        )
        backgroundColor     = .clear
        isOpaque            = false
        hasShadow           = false
        level               = .screenSaver
        ignoresMouseEvents  = false
        collectionBehavior  = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let view        = SelectionView()
        view.onCommit   = { [weak self] rect in self?.dismiss(); self?.onCommit?(rect) }
        view.onCancel   = { [weak self] in     self?.dismiss(); self?.onCancel?() }
        contentView     = view
    }

    private func dismiss() { orderOut(nil) }
}

// MARK: - Overlay view

private final class SelectionView: NSView {

    var onCommit: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var selectionRect: NSRect = .zero

    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dark overlay over the whole screen
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.45))
        ctx.fill(bounds)

        guard startPoint != nil, !selectionRect.isEmpty else { return }

        // Punch the selection rect clear — user sees the actual screen content
        ctx.clear(selectionRect)

        // Selection border
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
        ctx.setLineWidth(1.5)
        ctx.stroke(selectionRect)

        // Show physical pixel dimensions so the user sees the actual output resolution.
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let label = "\(Int(selectionRect.width * scale)) × \(Int(selectionRect.height * scale)) px"
        drawLabel(label, near: selectionRect, in: ctx)
    }

    private func drawLabel(_ text: String, near rect: NSRect, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let str  = NSAttributedString(string: text, attributes: attrs)
        let size = str.size()
        let pad: CGFloat = 4
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6)
        if origin.y < 0 { origin.y = rect.maxY + 4 }

        // Background pill
        let bg = CGRect(x: origin.x - pad, y: origin.y - pad / 2,
                        width: size.width + pad * 2, height: size.height + pad)
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6))
        ctx.fillEllipse(in: bg.insetBy(dx: -2, dy: 0))
        ctx.fill(bg)

        str.draw(at: origin)
    }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) {
        startPoint   = convert(event.locationInWindow, from: nil)
        selectionRect = .zero
        needsDisplay  = true
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let cur = convert(event.locationInWindow, from: nil)
        selectionRect = NSRect(
            x:      min(start.x, cur.x),
            y:      min(start.y, cur.y),
            width:  abs(cur.x - start.x),
            height: abs(cur.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard selectionRect.width > 4, selectionRect.height > 4 else {
            onCancel?(); return
        }
        onCommit?(selectionRect)
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } // Escape
    }
}
