import AppKit

// MARK: - Tool / style model

enum DrawingTool { case pen, highlight, arrow, line, rect, ellipse, text, blur }

struct DrawingStyle {
    var tool:  DrawingTool = .pen
    var color: NSColor     = .systemRed
    var size:  CGFloat     = 4
    var textBoxed: Bool    = false   // default for new text: plain, no background box (#9)
}

// MARK: - Delegate

protocol AnnotationCanvasDelegate: AnyObject {
    func canvasDidStartEditing()
    func canvasDidFinishStroke()
    /// Fired when an inline text editor opens (true) or commits/closes (false).
    /// The window controller uses this to suspend auto-close while typing (#3).
    func canvasEditingTextChanged(isEditing: Bool)
    /// Fired when the selected annotation changes so the toolbar can reflect its
    /// style (e.g. move the size slider to the selected annotation's size).
    func canvasSelectionChanged(style: DrawingStyle?)
}

// MARK: - Vector annotation model

/// A single editable annotation. All geometry is stored in image-pixel space
/// (y-up, matching CoreGraphics) so annotations are resolution-independent:
/// rendering scales them into whatever target context we draw into (the on-screen
/// view or the full-resolution export bitmap). Because annotations are retained
/// as objects rather than flattened into a bitmap, their colour and size can be
/// changed after the fact (#4).
struct Annotation {
    var id = UUID()
    var tool: DrawingTool
    var color: NSColor
    var size: CGFloat
    var points: [CGPoint] = []   // pen / highlight freehand path
    var start: CGPoint = .zero   // shapes / line / arrow / blur — and text origin
    var end: CGPoint = .zero
    var text: String = ""        // text tool
    var fontSize: CGFloat = 24   // text tool (derived from size on creation)
    var boxed: Bool = false      // text tool: draw a background box behind the text (#9)
}

// MARK: - Canvas view

final class AnnotationCanvasView: NSView {

    weak var delegate: AnnotationCanvasDelegate?
    var style = DrawingStyle()

    private let baseImage: CGImage

    // Retained vector model + undo history (snapshots of the whole array).
    private var annotations: [Annotation] = []
    private var history: [[Annotation]] = [[]]

    // Drawing / manipulation state
    private enum DragMode { case none, drawing, moving, resizing }
    private var dragMode: DragMode = .none
    private var draft: Annotation?
    private var dragStartImg = CGPoint.zero
    private var dragOrig: Annotation?      // snapshot of the dragged annotation at gesture start
    private var didDragMove = false

    // Selection — the annotation colour/size/move/resize edits target.
    private(set) var selectedID: UUID?

    private let handleSize: CGFloat = 11

    // Inline text editing
    private var editingTextID: UUID?
    private var textField: NSTextField?
    private var textEndObserver: NSObjectProtocol?

    // MARK: Init

    /// Failable initializer — returns nil for image dimensions CGContext would reject.
    init?(image: CGImage) {
        guard image.width > 0, image.height > 0,
              image.width < 32_768, image.height < 32_768 else {
            NSLog("[AnnotationCanvasView] Refusing image with bad size: \(image.width)x\(image.height)")
            return nil
        }
        self.baseImage = image
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout / coordinate conversion

    /// Rect within view bounds where the image is drawn (centered, aspect-fit).
    var imageRect: CGRect {
        let iw = CGFloat(baseImage.width)
        let ih = CGFloat(baseImage.height)
        let scale = min(bounds.width / iw, bounds.height / ih)
        let dw = iw * scale, dh = ih * scale
        return CGRect(x: (bounds.width - dw) / 2, y: (bounds.height - dh) / 2, width: dw, height: dh)
    }

    private var imageScale: CGFloat {
        imageRect.width / CGFloat(baseImage.width)
    }

    private func toImagePoint(_ viewPt: NSPoint) -> CGPoint {
        let r  = imageRect
        let iw = CGFloat(baseImage.width)
        let ih = CGFloat(baseImage.height)
        // NSView and CGContext both use y-up; just translate + scale.
        return CGPoint(x: (viewPt.x - r.minX) / r.width  * iw,
                       y: (viewPt.y - r.minY) / r.height * ih)
    }

    private func imagePointToView(_ pt: CGPoint) -> NSPoint {
        let r  = imageRect
        let iw = CGFloat(baseImage.width)
        let ih = CGFloat(baseImage.height)
        return NSPoint(x: r.minX + pt.x / iw * r.width,
                       y: r.minY + pt.y / ih * r.height)
    }

    // MARK: Rendering

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(bounds)

        let r = imageRect
        NSImage(cgImage: baseImage, size: NSSize(width: baseImage.width, height: baseImage.height)).draw(in: r)

        // Committed annotations + the in-progress draft, in creation order.
        // Skip the one being text-edited (its live NSTextField shows instead).
        let all = annotations + (draft.map { [$0] } ?? [])
        for a in all where a.id != editingTextID {
            render(a, into: ctx, map: imagePointToView, scale: imageScale)
        }

        // Selection chrome (view only — never exported).
        if let sid = selectedID, let sel = annotations.first(where: { $0.id == sid }) {
            drawSelectionChrome(sel, in: ctx)
        }
    }

    /// Coordinate-agnostic annotation renderer. `map` converts an image-space point
    /// into the target context's space; `scale` converts image-space lengths (line
    /// width, font size) into the target. Used for both on-screen draw (scaled) and
    /// export (identity / full-resolution).
    private func render(_ a: Annotation, into ctx: CGContext,
                        map: (CGPoint) -> NSPoint, scale: CGFloat) {
        ctx.saveGState()
        defer { ctx.restoreGState() }

        let lw    = (a.tool == .highlight ? max(a.size * 4, 20) : a.size) * scale
        let alpha: CGFloat = a.tool == .highlight ? 0.4 : 1.0
        ctx.setAlpha(alpha)
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(lw)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        switch a.tool {
        case .pen, .highlight:
            guard let first = a.points.first else { break }
            ctx.beginPath()
            ctx.move(to: map(first))
            for p in a.points.dropFirst() { ctx.addLine(to: map(p)) }
            ctx.strokePath()

        case .line:
            ctx.beginPath(); ctx.move(to: map(a.start)); ctx.addLine(to: map(a.end)); ctx.strokePath()

        case .arrow:
            drawArrow(map(a.start), map(a.end), headLen: max(16, a.size * 4) * scale, ctx: ctx)

        case .rect:
            ctx.stroke(rectBetween(map(a.start), map(a.end)))

        case .ellipse:
            ctx.strokeEllipse(in: rectBetween(map(a.start), map(a.end)))

        case .blur:
            drawBlur(a, into: ctx, map: map)

        case .text:
            let font = NSFont.systemFont(ofSize: a.fontSize * scale)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: a.color]
            let origin = map(a.start)
            if a.boxed {
                // Opt-in background box behind the text (#9).
                let sz  = (a.text as NSString).size(withAttributes: attrs)
                let pad = 4 * scale
                let box = CGRect(x: origin.x - pad, y: origin.y - pad,
                                 width: sz.width + pad * 2, height: sz.height + pad * 2)
                let path = CGPath(roundedRect: box, cornerWidth: 4 * scale, cornerHeight: 4 * scale, transform: nil)
                ctx.saveGState()
                ctx.setAlpha(1)
                ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
                ctx.addPath(path); ctx.fillPath()
                ctx.restoreGState()
            }
            NSAttributedString(string: a.text, attributes: attrs).draw(at: origin)
        }
    }

    private func rectBetween(_ a: NSPoint, _ b: NSPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    private func drawArrow(_ s: NSPoint, _ e: NSPoint, headLen: CGFloat, ctx: CGContext) {
        let angle = atan2(e.y - s.y, e.x - s.x)
        ctx.beginPath(); ctx.move(to: s); ctx.addLine(to: e); ctx.strokePath()
        let p1 = CGPoint(x: e.x - headLen * cos(angle - .pi / 7), y: e.y - headLen * sin(angle - .pi / 7))
        let p2 = CGPoint(x: e.x - headLen * cos(angle + .pi / 7), y: e.y - headLen * sin(angle + .pi / 7))
        ctx.beginPath(); ctx.move(to: e); ctx.addLine(to: p1); ctx.addLine(to: p2)
        ctx.closePath(); ctx.fillPath()
    }

    /// Pixelate the base-image region under the annotation. Recomputed each draw;
    /// blur regions are small so the cost is negligible.
    private func drawBlur(_ a: Annotation, into ctx: CGContext, map: (CGPoint) -> NSPoint) {
        let rx = min(a.start.x, a.end.x), ry = min(a.start.y, a.end.y)
        let rw = abs(a.end.x - a.start.x), rh = abs(a.end.y - a.start.y)
        guard rw > 2, rh > 2 else { return }

        let region = CGRect(x: rx, y: ry, width: rw, height: rh)
        guard let cropped = baseImage.cropping(to: region) else { return }

        let blockSize = max(8, min(24, min(rw, rh) / 6))
        let sw = max(1, Int(rw / blockSize)), sh = max(1, Int(rh / blockSize))
        let cs = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        guard let small = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8,
                                    bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        small.interpolationQuality = .medium
        small.draw(cropped, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        guard let smallImg = small.makeImage() else { return }

        let target = rectBetween(map(CGPoint(x: rx, y: ry)), map(CGPoint(x: rx + rw, y: ry + rh)))
        ctx.saveGState()
        ctx.interpolationQuality = .none
        ctx.draw(smallImg, in: target)
        ctx.restoreGState()
    }

    private func drawSelectionChrome(_ a: Annotation, in ctx: CGContext) {
        let r = boundingViewRect(a).insetBy(dx: -6, dy: -6)
        ctx.saveGState()
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [5, 3])
        ctx.stroke(r)
        ctx.setLineDash(phase: 0, lengths: [])
        // Resize handle (a small filled dot) for types that support resizing.
        if let hr = resizeHandleRect(a) {
            ctx.setFillColor(NSColor.controlAccentColor.cgColor)
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1.5)
            ctx.fillEllipse(in: hr)
            ctx.strokeEllipse(in: hr)
        }
        ctx.restoreGState()
    }

    /// View-space anchor of the resize handle, or nil for types we don't resize
    /// (freehand pen/highlight — just movable).
    private func resizeHandlePoint(_ a: Annotation) -> NSPoint? {
        switch a.tool {
        case .pen, .highlight:
            return nil
        case .text:
            let r = textViewRect(a); return NSPoint(x: r.maxX, y: r.maxY)   // far corner from origin
        default:
            return imagePointToView(a.end)
        }
    }

    private func resizeHandleRect(_ a: Annotation) -> CGRect? {
        guard let p = resizeHandlePoint(a) else { return nil }
        return CGRect(x: p.x - handleSize / 2, y: p.y - handleSize / 2, width: handleSize, height: handleSize)
    }

    private func translated(_ a: Annotation, dx: CGFloat, dy: CGFloat) -> Annotation {
        var c = a
        c.start  = CGPoint(x: a.start.x + dx, y: a.start.y + dy)
        c.end    = CGPoint(x: a.end.x + dx,   y: a.end.y + dy)
        c.points = a.points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return c
    }

    // MARK: Hit-testing & selection

    /// Bounding rect of an annotation in view space.
    private func boundingViewRect(_ a: Annotation) -> CGRect {
        switch a.tool {
        case .pen, .highlight:
            let pts = a.points.map(imagePointToView)
            guard let first = pts.first else { return .zero }
            var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
            for p in pts.dropFirst() {
                minX = min(minX, p.x); minY = min(minY, p.y)
                maxX = max(maxX, p.x); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .text:
            return textViewRect(a)
        default:
            return rectBetween(imagePointToView(a.start), imagePointToView(a.end))
        }
    }

    private func textViewRect(_ a: Annotation) -> CGRect {
        let font = NSFont.systemFont(ofSize: a.fontSize * imageScale)
        let text = a.text.isEmpty ? "Type text" : a.text
        let size = (text as NSString).size(withAttributes: [.font: font])
        let origin = imagePointToView(a.start)
        return CGRect(x: origin.x, y: origin.y, width: max(size.width, 20), height: max(size.height, 16))
    }

    /// Topmost annotation under a view-space point, if any.
    private func annotationHit(at viewPt: NSPoint) -> Annotation? {
        for a in annotations.reversed() where hitTest(a, viewPt) { return a }
        return nil
    }

    private func hitTest(_ a: Annotation, _ p: NSPoint) -> Bool {
        let tol = max(8, a.size * imageScale)
        switch a.tool {
        case .text:
            return textViewRect(a).insetBy(dx: -4, dy: -4).contains(p)
        case .rect, .ellipse, .blur:
            return boundingViewRect(a).insetBy(dx: -6, dy: -6).contains(p)
        case .line, .arrow:
            return distanceToSegment(p, imagePointToView(a.start), imagePointToView(a.end)) <= tol
        case .pen, .highlight:
            let pts = a.points.map(imagePointToView)
            if pts.count == 1 { return hypot(p.x - pts[0].x, p.y - pts[0].y) <= tol }
            for i in 0..<max(0, pts.count - 1) where distanceToSegment(p, pts[i], pts[i + 1]) <= tol {
                return true
            }
            return false
        }
    }

    private func distanceToSegment(_ p: NSPoint, _ a: NSPoint, _ b: NSPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        if dx == 0 && dy == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / (dx * dx + dy * dy)))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private func select(_ id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id
        needsDisplay = true
        let st = id
            .flatMap { sid in annotations.first { $0.id == sid } }
            .map { DrawingStyle(tool: $0.tool, color: $0.color, size: $0.size) }
        delegate?.canvasSelectionChanged(style: st)
    }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) {
        // Clicking anywhere commits any open text editor first.
        finishTextEditing()

        let viewPt  = convert(event.locationInWindow, from: nil)
        let imagePt = toImagePoint(viewPt)
        didDragMove = false

        // 1) Resize handle of the current selection wins over everything.
        if let sid = selectedID, let sel = annotations.first(where: { $0.id == sid }),
           let hr = resizeHandleRect(sel), hr.insetBy(dx: -4, dy: -4).contains(viewPt) {
            dragMode = .resizing
            dragStartImg = imagePt
            dragOrig = sel
            return
        }

        // 2) Clicking an existing annotation selects it. Double-click on text edits
        //    it; a single click arms a move-drag.
        if let hit = annotationHit(at: viewPt) {
            select(hit.id)
            if event.clickCount >= 2, hit.tool == .text {
                dragMode = .none
                beginEditingText(id: hit.id)
                return
            }
            dragMode = .moving
            dragStartImg = imagePt
            dragOrig = annotations.first(where: { $0.id == hit.id })
            return
        }

        // 3) Empty space — deselect and start a new annotation.
        select(nil)
        if style.tool == .text {
            dragMode = .none
            delegate?.canvasDidStartEditing()
            createNewText(at: imagePt)
            return
        }

        delegate?.canvasDidStartEditing()
        dragMode = .drawing
        var d = Annotation(tool: style.tool, color: style.color, size: style.size,
                           start: imagePt, end: imagePt)
        if style.tool == .pen || style.tool == .highlight { d.points = [imagePt] }
        draft = d
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = toImagePoint(convert(event.locationInWindow, from: nil))
        switch dragMode {
        case .drawing:
            guard var d = draft else { return }
            if d.tool == .pen || d.tool == .highlight { d.points.append(pt) }
            d.end = pt
            draft = d
            needsDisplay = true

        case .moving:
            guard let orig = dragOrig, let idx = annotations.firstIndex(where: { $0.id == orig.id }) else { return }
            let dx = pt.x - dragStartImg.x, dy = pt.y - dragStartImg.y
            if abs(dx) > 0.5 || abs(dy) > 0.5 { didDragMove = true }
            annotations[idx] = translated(orig, dx: dx, dy: dy)
            needsDisplay = true

        case .resizing:
            guard let orig = dragOrig, let idx = annotations.firstIndex(where: { $0.id == orig.id }) else { return }
            didDragMove = true
            resize(at: idx, orig: orig, to: pt)
            needsDisplay = true

        case .none:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        let mode = dragMode
        dragMode = .none
        defer { dragOrig = nil }

        switch mode {
        case .drawing:
            guard let d = draft else { return }
            draft = nil
            let degenerate: Bool = {
                switch d.tool {
                case .pen, .highlight: return d.points.count < 2
                default:               return hypot(d.end.x - d.start.x, d.end.y - d.start.y) < 3
                }
            }()
            if degenerate { needsDisplay = true; return }
            annotations.append(d)
            select(d.id)
            saveHistory()
            needsDisplay = true
            delegate?.canvasDidFinishStroke()

        case .moving, .resizing:
            if didDragMove { saveHistory(); delegate?.canvasDidFinishStroke() }

        case .none:
            break
        }
    }

    /// Resize the annotation at `idx` from its `orig` snapshot toward point `pt`.
    /// Text scales its font by distance-from-origin ratio; other shapes move their
    /// end point. Freehand strokes aren't resizable (no handle is shown).
    private func resize(at idx: Int, orig: Annotation, to pt: CGPoint) {
        switch orig.tool {
        case .text:
            let o = orig.start
            let startD = hypot(dragStartImg.x - o.x, dragStartImg.y - o.y)
            guard startD > 1 else { return }
            let ratio   = max(0.2, hypot(pt.x - o.x, pt.y - o.y) / startD)
            let newFont = max(8, orig.fontSize * ratio)
            annotations[idx].fontSize = newFont
            annotations[idx].size     = max(1, newFont / 3)
            delegate?.canvasSelectionChanged(style: DrawingStyle(tool: .text,
                                                                 color: orig.color,
                                                                 size: annotations[idx].size))
        case .pen, .highlight:
            break
        default:
            annotations[idx].end = pt
        }
    }

    // MARK: Text editing

    private func createNewText(at imagePt: CGPoint) {
        var a = Annotation(tool: .text, color: style.color, size: style.size, start: imagePt)
        a.fontSize = max(14, style.size * 3)
        a.boxed    = style.textBoxed
        annotations.append(a)
        beginEditingText(id: a.id)
    }

    /// Toggle the background box on the text annotation being edited (or, if none
    /// is being edited, the selected text). Also updates the default for new text
    /// so subsequent boxes match. Bound to ⌘B (#9).
    func toggleSelectedTextBox() {
        let id = editingTextID ?? selectedID
        guard let id, let idx = annotations.firstIndex(where: { $0.id == id }),
              annotations[idx].tool == .text else { return }
        annotations[idx].boxed.toggle()
        let boxed = annotations[idx].boxed
        style.textBoxed = boxed
        if id == editingTextID {
            textField?.drawsBackground = boxed
            textField?.backgroundColor = boxed ? NSColor(white: 0, alpha: 0.55) : .clear
        }
        needsDisplay = true
        delegate?.canvasDidFinishStroke()
    }

    private func beginEditingText(id: UUID) {
        guard let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        let a = annotations[idx]

        editingTextID = id
        select(id)
        delegate?.canvasDidStartEditing()
        delegate?.canvasEditingTextChanged(isEditing: true)

        let rect = textViewRect(a)
        let field = NSTextField(frame: NSRect(x: rect.minX - 2, y: rect.minY - 2,
                                              width: max(rect.width + 80, 160),
                                              height: rect.height + 8))
        field.placeholderString = "Type text, press Return"
        field.stringValue       = a.text
        field.font              = .systemFont(ofSize: a.fontSize * imageScale)
        field.textColor         = a.color
        // Plain text by default; only show a background while editing if this text
        // is explicitly boxed (⌘B), matching the rendered result (#9).
        field.drawsBackground   = a.boxed
        field.backgroundColor   = a.boxed ? NSColor(white: 0, alpha: 0.55) : .clear
        field.isBordered        = false
        field.focusRingType     = .none
        addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)

        textField    = field
        needsDisplay = true

        textEndObserver = NotificationCenter.default.addObserver(
            forName: NSControl.textDidEndEditingNotification, object: field, queue: .main
        ) { [weak self] _ in self?.finishTextEditing() }
    }

    /// Commit (or discard, if empty) the open text editor. Safe to call when not editing.
    private func finishTextEditing() {
        guard let field = textField, let id = editingTextID else { return }
        if let obs = textEndObserver { NotificationCenter.default.removeObserver(obs); textEndObserver = nil }

        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.removeFromSuperview()
        textField     = nil
        editingTextID = nil

        if let idx = annotations.firstIndex(where: { $0.id == id }) {
            if trimmed.isEmpty {
                annotations.remove(at: idx)
                if selectedID == id { select(nil) }
            } else {
                annotations[idx].text = trimmed
            }
        }
        saveHistory()
        needsDisplay = true
        delegate?.canvasEditingTextChanged(isEditing: false)
        delegate?.canvasDidFinishStroke()
    }

    // MARK: Restyle selection (#4)

    /// Apply a colour to the selected annotation (and the live editor if a text box
    /// is open). No-op when nothing is selected. Returns whether anything changed.
    @discardableResult
    func applySelectedColor(_ color: NSColor) -> Bool {
        guard let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) else { return false }
        annotations[idx].color = color
        if id == editingTextID { textField?.textColor = color }
        needsDisplay = true
        saveHistory()
        delegate?.canvasDidFinishStroke()
        return true
    }

    /// Apply a stroke/font size to the selected annotation. During a slider drag
    /// pass `commitHistory: false`; pass true on the final value so undo captures
    /// one step rather than every intermediate tick.
    @discardableResult
    func applySelectedSize(_ size: CGFloat, commitHistory: Bool) -> Bool {
        guard let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) else { return false }
        annotations[idx].size = size
        if annotations[idx].tool == .text {
            annotations[idx].fontSize = max(14, size * 3)
            if id == editingTextID { textField?.font = .systemFont(ofSize: annotations[idx].fontSize * imageScale) }
        }
        needsDisplay = true
        if commitHistory { saveHistory() }
        delegate?.canvasDidFinishStroke()
        return true
    }

    private func deleteSelected() {
        guard let id = selectedID, let idx = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations.remove(at: idx)
        select(nil)
        saveHistory()
        needsDisplay = true
        delegate?.canvasDidFinishStroke()
    }

    // MARK: History

    private func saveHistory() {
        history.append(annotations)
        if history.count > 60 { history.removeFirst() }
    }

    func undo() {
        finishTextEditing()
        guard history.count > 1 else { return }
        history.removeLast()
        annotations = history.last ?? []
        if let sid = selectedID, !annotations.contains(where: { $0.id == sid }) { select(nil) }
        needsDisplay = true
        delegate?.canvasDidFinishStroke()
    }

    func clearAnnotations() {
        finishTextEditing()
        annotations = []
        selectedID  = nil
        history     = [[]]
        needsDisplay = true
        delegate?.canvasSelectionChanged(style: nil)
    }

    // MARK: Export

    func exportComposite() -> CGImage? {
        let w  = baseImage.width, h = baseImage.height
        let cs = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        guard let out = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        out.draw(baseImage, in: CGRect(x: 0, y: 0, width: w, height: h))

        let nsCtx = NSGraphicsContext(cgContext: out, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        for a in annotations { render(a, into: out, map: { $0 }, scale: 1) }
        NSGraphicsContext.restoreGraphicsState()

        return out.makeImage()
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    // Guarantees drawing strokes never move the borderless window (see controller).
    override var mouseDownCanMoveWindow: Bool { false }

    override func keyDown(with event: NSEvent) {
        // While a text field is first responder this view doesn't receive keyDown,
        // so tool shortcuts / delete never fire mid-typing.
        let toolMap: [UInt16: DrawingTool] = [
            35: .pen, 4: .highlight, 0: .arrow, 37: .line,
            15: .rect, 14: .ellipse, 17: .text, 11: .blur,
        ]
        if let tool = toolMap[event.keyCode] { style.tool = tool; return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control),
           event.charactersIgnoringModifiers == "z" { undo(); return }
        if event.keyCode == 51 /* delete */ || event.keyCode == 117 /* fwd delete */ {
            deleteSelected(); return
        }
        super.keyDown(with: event)
    }
}
