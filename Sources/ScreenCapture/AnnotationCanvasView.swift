import AppKit

// MARK: - Tool / style model

enum DrawingTool { case pen, highlight, arrow, line, rect, ellipse, text, blur }

struct DrawingStyle {
    var tool:  DrawingTool = .pen
    var color: NSColor     = .systemRed
    var size:  CGFloat     = 4
}

// MARK: - Delegate

protocol AnnotationCanvasDelegate: AnyObject {
    func canvasDidStartEditing()
    func canvasDidFinishStroke()
}

// MARK: - Text annotation model

/// Persistent text annotation. Stored outside the bitmap so clicks can re-enter
/// edit mode (the bitmap is one-way once flattened).
struct TextAnnotation {
    var id: UUID = UUID()
    var text: String
    var origin: CGPoint   // bottom-left in image pixel coords
    var fontSize: CGFloat
    var color: NSColor
}

// MARK: - Canvas view

final class AnnotationCanvasView: NSView {

    weak var delegate: AnnotationCanvasDelegate?
    var style = DrawingStyle()

    // Images
    private let baseImage: CGImage
    private let annotCtx:  CGContext          // same pixel size as baseImage
    private(set) var history: [Snapshot] = [] // immutable snapshots for undo

    // Per-stroke state
    private var drawing    = false
    private var startPt    = CGPoint.zero
    private var strokeBase: CGImage?          // annotation snapshot before current stroke

    // Text annotations — kept as model objects so clicks can re-enter edit mode.
    // They render on top of the strokes bitmap; only flattened into the final
    // exported image in `exportComposite()`.
    private var texts: [TextAnnotation] = []
    private var editingTextID: UUID?          // id of text currently being edited
    private var textField: NSTextField?       // overlay editor

    // Combined undo snapshot — both the stroke bitmap AND the text array must be
    // captured together so undo restores both layers consistently.
    struct Snapshot {
        let strokes: CGImage
        let texts: [TextAnnotation]
    }

    // MARK: Init

    /// Failable initializer — returns nil if the annotation bitmap context cannot
    /// be allocated (e.g. image dimensions exceed CGContext limits or memory is
    /// exhausted). Caller is responsible for handling nil and refusing to open
    /// the annotation window rather than crashing.
    init?(image: CGImage) {
        // Sanity-check dimensions before asking CG for a context. CGContext rejects
        // zero/negative sizes and silently fails on absurd ones.
        guard image.width > 0, image.height > 0,
              image.width < 32_768, image.height < 32_768 else {
            NSLog("[AnnotationCanvasView] Refusing image with bad size: \(image.width)x\(image.height)")
            return nil
        }

        let cs = image.colorSpace
            ?? CGColorSpace(name: CGColorSpace.displayP3)
            ?? CGColorSpaceCreateDeviceRGB()

        guard let ctx = CGContext(
            data: nil,
            width:  image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            NSLog("[AnnotationCanvasView] CGContext allocation failed for \(image.width)x\(image.height)")
            return nil
        }

        self.baseImage = image
        self.annotCtx  = ctx
        super.init(frame: .zero)
        saveHistory()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout / display

    // Rect within view bounds where the image is drawn (centered, aspect-fit)
    var imageRect: CGRect {
        let iw = CGFloat(baseImage.width)
        let ih = CGFloat(baseImage.height)
        let scale = min(bounds.width / iw, bounds.height / ih)
        let dw = iw * scale, dh = ih * scale
        return CGRect(x: (bounds.width - dw) / 2, y: (bounds.height - dh) / 2, width: dw, height: dh)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        ctx.fill(bounds)

        let r = imageRect

        // Base image — NSImage handles orientation correctly across CGImage sources
        let nsBase = NSImage(cgImage: baseImage, size: NSSize(width: baseImage.width, height: baseImage.height))
        nsBase.draw(in: r)

        // Stroke overlay
        if let annotImg = annotCtx.makeImage() {
            let nsAnnot = NSImage(cgImage: annotImg, size: NSSize(width: annotImg.width, height: annotImg.height))
            nsAnnot.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
        }

        // Text annotations — drawn last so they sit on top of strokes. Skip the
        // one currently being edited (its NSTextField overlay shows live).
        let scale = imageScale
        for t in texts where t.id != editingTextID {
            let font = NSFont.systemFont(ofSize: t.fontSize * scale)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: t.color,
            ]
            let str = NSAttributedString(string: t.text, attributes: attrs)
            let viewPt = imagePointToView(t.origin)
            str.draw(at: viewPt)
        }
    }

    /// Convert image-pixel coords back to view-space coords (for rendering and
    /// for placing the NSTextField editor on top of an existing annotation).
    private func imagePointToView(_ pt: CGPoint) -> NSPoint {
        let r  = imageRect
        let iw = CGFloat(baseImage.width)
        let ih = CGFloat(baseImage.height)
        return NSPoint(
            x: r.minX + pt.x / iw * r.width,
            y: r.minY + pt.y / ih * r.height
        )
    }

    /// Returns the bounding rect of a text annotation in view-space coords.
    /// Used for hit-testing on mouseDown so clicks on existing text open the editor.
    private func textViewRect(_ t: TextAnnotation) -> NSRect {
        let scale = imageScale
        let font  = NSFont.systemFont(ofSize: t.fontSize * scale)
        let size  = (t.text as NSString).size(withAttributes: [.font: font])
        let origin = imagePointToView(t.origin)
        return NSRect(x: origin.x, y: origin.y, width: max(size.width, 20), height: max(size.height, 16))
    }

    // MARK: Coordinate conversion (view → image pixel space)

    private func toImagePoint(_ viewPt: NSPoint) -> CGPoint {
        let r  = imageRect
        let iw = CGFloat(baseImage.width)
        let ih = CGFloat(baseImage.height)
        // NSView default: y=0 at bottom. CGContext: y=0 at bottom. Same orientation — just scale.
        return CGPoint(
            x: (viewPt.x - r.minX) / r.width  * iw,
            y: (viewPt.y - r.minY) / r.height * ih
        )
    }

    private var imageScale: CGFloat {
        let r = imageRect
        return r.width / CGFloat(baseImage.width)
    }

    // MARK: History

    func saveHistory() {
        let strokes = annotCtx.makeImage() ?? emptyImage()
        history.append(Snapshot(strokes: strokes, texts: texts))
        if history.count > 60 { history.removeFirst() }
    }

    func undo() {
        guard history.count > 1 else { return }
        history.removeLast()
        if let last = history.last {
            restoreAnnotation(last.strokes)
            texts = last.texts
        }
        needsDisplay = true
    }

    func clearAnnotations() {
        annotCtx.clear(CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
        texts = []
        history = []
        saveHistory()
        needsDisplay = true
    }

    // MARK: Export

    func exportComposite() -> CGImage? {
        let w  = baseImage.width, h = baseImage.height
        let cs = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        guard let out = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // Draw base — CGImage in CGContext uses y-up, same as our source
        out.draw(baseImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        if let annot = annotCtx.makeImage() {
            out.draw(annot, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        // Flatten text annotations onto the export at full image resolution.
        let nsCtx = NSGraphicsContext(cgContext: out, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        for t in texts {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: t.fontSize),
                .foregroundColor: t.color,
            ]
            NSAttributedString(string: t.text, attributes: attrs).draw(at: t.origin)
        }
        NSGraphicsContext.restoreGraphicsState()
        return out.makeImage()
    }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) {
        let viewPt  = convert(event.locationInWindow, from: nil)
        let imagePt = toImagePoint(viewPt)

        // Hit-test existing text first — clicking inside a text annotation always
        // re-opens it for editing, regardless of which tool is selected. This is
        // the discoverable behavior: text is the only annotation type that can
        // be re-edited, and the cursor lands on it directly.
        if let hit = texts.last(where: { textViewRect($0).contains(viewPt) }) {
            beginEditingText(hit)
            drawing = true
            return
        }

        if style.tool == .text {
            drawing = true  // keep drag events on this responder; mouseDragged no-ops for .text
            createNewTextAnnotation(at: imagePt, viewPt: viewPt)
            return
        }

        delegate?.canvasDidStartEditing()
        drawing   = true
        startPt   = imagePt
        strokeBase = annotCtx.makeImage()

        if style.tool == .pen || style.tool == .highlight {
            beginPath(at: imagePt)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard drawing else { return }
        if style.tool == .text { return }
        let pt = toImagePoint(convert(event.locationInWindow, from: nil))

        switch style.tool {
        case .pen, .highlight:
            extendPath(to: pt)
        default:
            // Shape preview: restore snapshot then draw shape
            if let base = strokeBase { restoreAnnotation(base) }
            drawShape(from: startPt, to: pt)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard drawing else { return }
        drawing = false
        if style.tool == .text { return }  // text commits via Return; commitText handles history
        let pt = toImagePoint(convert(event.locationInWindow, from: nil))

        if style.tool == .blur {
            applyBlur(from: startPt, to: pt)
        }

        saveHistory()
        needsDisplay = true
        delegate?.canvasDidFinishStroke()
    }

    // MARK: Drawing primitives

    private func beginPath(at pt: CGPoint) {
        applyStyle()
        annotCtx.beginPath()
        annotCtx.move(to: pt)
    }

    private func extendPath(to pt: CGPoint) {
        annotCtx.addLine(to: pt)
        annotCtx.strokePath()
        // Re-start path at current point so next drag segment continues cleanly
        annotCtx.beginPath()
        annotCtx.move(to: pt)
    }

    private func drawShape(from s: CGPoint, to e: CGPoint) {
        applyStyle()
        switch style.tool {
        case .arrow:  drawArrow(s, e)
        case .line:   drawLine(s, e)
        case .rect:   drawRect(s, e)
        case .ellipse: drawEllipse(s, e)
        default: break
        }
    }

    private func applyStyle() {
        let alpha: CGFloat = style.tool == .highlight ? 0.4 : 1.0
        let lw: CGFloat    = style.tool == .highlight ? max(style.size * 4, 20) : style.size

        annotCtx.setAlpha(alpha)
        annotCtx.setStrokeColor(style.color.cgColor)
        annotCtx.setFillColor(style.color.cgColor)
        annotCtx.setLineWidth(lw)
        annotCtx.setLineCap(.round)
        annotCtx.setLineJoin(.round)
    }

    private func drawLine(_ s: CGPoint, _ e: CGPoint) {
        annotCtx.beginPath(); annotCtx.move(to: s); annotCtx.addLine(to: e); annotCtx.strokePath()
    }

    private func drawRect(_ s: CGPoint, _ e: CGPoint) {
        annotCtx.stroke(CGRect(x: min(s.x,e.x), y: min(s.y,e.y),
                               width: abs(e.x-s.x), height: abs(e.y-s.y)))
    }

    private func drawEllipse(_ s: CGPoint, _ e: CGPoint) {
        annotCtx.strokeEllipse(in: CGRect(x: min(s.x,e.x), y: min(s.y,e.y),
                                          width: abs(e.x-s.x), height: abs(e.y-s.y)))
    }

    private func drawArrow(_ s: CGPoint, _ e: CGPoint) {
        let angle   = atan2(e.y - s.y, e.x - s.x)
        let headLen = max(16, style.size * 4)
        annotCtx.beginPath(); annotCtx.move(to: s); annotCtx.addLine(to: e); annotCtx.strokePath()
        // Arrowhead
        let p1 = CGPoint(x: e.x - headLen * cos(angle - .pi/7),
                         y: e.y - headLen * sin(angle - .pi/7))
        let p2 = CGPoint(x: e.x - headLen * cos(angle + .pi/7),
                         y: e.y - headLen * sin(angle + .pi/7))
        annotCtx.beginPath()
        annotCtx.move(to: e); annotCtx.addLine(to: p1); annotCtx.addLine(to: p2)
        annotCtx.closePath(); annotCtx.fillPath()
    }

    // MARK: Blur / redact

    private func applyBlur(from s: CGPoint, to e: CGPoint) {
        let rx = min(s.x, e.x), ry = min(s.y, e.y)
        let rw = abs(e.x - s.x), rh = abs(e.y - s.y)
        guard rw > 2, rh > 2 else { return }

        let blockSize = max(8, min(24, min(rw, rh) / 6))
        let region    = CGRect(x: rx, y: ry, width: rw, height: rh)

        // Sample pixels from base image in this region
        guard let cropped = baseImage.cropping(to: region) else { return }

        // Scale down, then back up for pixelation
        let sw = max(1, Int(rw / blockSize))
        let sh = max(1, Int(rh / blockSize))
        let cs = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.displayP3)!
        guard let small = CGContext(data: nil, width: sw, height: sh,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let smallImg = { small.draw(cropped, in: CGRect(x:0, y:0, width:sw, height:sh)); return small.makeImage() }()
        else { return }

        annotCtx.interpolationQuality = .none
        annotCtx.draw(smallImg, in: region)
        annotCtx.interpolationQuality = .default
    }

    // MARK: Text input — editable model

    /// Insert a new text annotation and open the editor on it.
    private func createNewTextAnnotation(at imagePt: CGPoint, viewPt: NSPoint) {
        delegate?.canvasDidStartEditing()
        // Font size: scale.size * 3 reads decently against typical screenshots.
        let newText = TextAnnotation(
            text: "",
            origin: imagePt,
            fontSize: max(14, style.size * 3),
            color: style.color
        )
        texts.append(newText)
        beginEditingText(newText)
    }

    /// Show an inline NSTextField positioned over an existing text annotation so
    /// the user can edit its content in place. On commit the annotation is
    /// updated (or removed if emptied).
    private func beginEditingText(_ annotation: TextAnnotation) {
        delegate?.canvasDidStartEditing()

        // Place the field over the annotation's rendered position. Field tracks
        // the text's view-space rect with extra width so longer text fits.
        let rect = textViewRect(annotation)
        let field = NSTextField(frame: NSRect(
            x: rect.minX - 2, y: rect.minY - 2,
            width: max(rect.width + 80, 160),
            height: rect.height + 8
        ))
        field.placeholderString = "Type text, press Return"
        field.stringValue       = annotation.text
        field.font              = .systemFont(ofSize: annotation.fontSize * imageScale)
        field.textColor         = annotation.color
        field.backgroundColor   = NSColor(white: 0, alpha: 0.55)
        field.isBordered        = false
        field.focusRingType     = .none
        field.drawsBackground   = true
        addSubview(field)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)

        editingTextID = annotation.id
        textField     = field
        needsDisplay  = true  // hide the bitmap-rendered text while editing

        NotificationCenter.default.addObserver(
            forName: NSControl.textDidEndEditingNotification,
            object: field, queue: .main
        ) { [weak self] _ in
            self?.commitTextField()
        }
    }

    /// Called when the text editor resigns first responder (Tab, Return, click-out).
    private func commitTextField() {
        guard let field = textField, let id = editingTextID else { return }
        NotificationCenter.default.removeObserver(self,
            name: NSControl.textDidEndEditingNotification, object: field)
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        field.removeFromSuperview()
        textField     = nil
        editingTextID = nil

        if let idx = texts.firstIndex(where: { $0.id == id }) {
            if trimmed.isEmpty {
                texts.remove(at: idx)         // empty text → drop annotation
            } else {
                texts[idx].text = trimmed     // update in place
            }
        }
        saveHistory()
        needsDisplay = true
        delegate?.canvasDidFinishStroke()
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { true }

    // Critical: AppKit's default for NSView is false, but certain layer-backed /
    // borderless-window combinations cause mouseDown events to be interpreted as
    // window-drag intents. Explicitly refusing here guarantees drawing strokes
    // never move the annotation window.
    override var mouseDownCanMoveWindow: Bool { false }

    override func keyDown(with event: NSEvent) {
        let map: [UInt16: DrawingTool] = [
            35: .pen, 4: .highlight, 0: .arrow, 37: .line,
            15: .rect, 14: .ellipse, 17: .text, 11: .blur,
        ]
        if let tool = map[event.keyCode] { style.tool = tool; return }
        if (event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control)),
           event.charactersIgnoringModifiers == "z" { undo(); return }
        super.keyDown(with: event)
    }

    // MARK: Helpers

    private func restoreAnnotation(_ img: CGImage) {
        annotCtx.clear(CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
        annotCtx.draw(img, in: CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
    }

    private func emptyImage() -> CGImage {
        // Tiny 1x1 transparent fallback. Force-unwraps replaced with safe path:
        // if CG ever can't allocate a 1px context something is truly broken, but
        // we'd rather return a sentinel image (re-use annotCtx) than crash here.
        let cs = CGColorSpaceCreateDeviceRGB()
        if let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8,
                               bytesPerRow: 0, space: cs,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
           let img = ctx.makeImage() {
            return img
        }
        // Last resort — return whatever the annotation context currently holds.
        return annotCtx.makeImage() ?? baseImage
    }
}
