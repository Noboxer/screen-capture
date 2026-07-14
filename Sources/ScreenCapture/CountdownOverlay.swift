import AppKit

// Floating countdown window shown before a delayed capture.
// - Does not steal focus (orderFrontRegardless + canBecomeKey = false + ignoresMouseEvents).
// - Escape cancels via local + global key monitors so it works regardless of which
//   app or window currently has keyboard focus.
// - onFire / onCancel are guaranteed to be called exactly once.
final class CountdownOverlay: NSWindow {

    private var remaining:     Int
    private var countTimer:    Timer?
    private var localMonitor:  Any?
    private var globalMonitor: Any?
    private let onFire:        () -> Void
    private let onCancel:      () -> Void
    private var countLabel:    NSTextField!
    private var cancelled      = false  // guard against double-fire in race conditions

    // MARK: – Factory

    /// Shows the overlay and returns immediately. Exactly one of onFire / onCancel will be
    /// called once the countdown finishes or the user presses Escape.
    @discardableResult
    static func show(seconds:  Int,
                     onFire:   @escaping () -> Void,
                     onCancel: @escaping () -> Void = {}) -> CountdownOverlay {
        let w = CountdownOverlay(seconds: seconds, onFire: onFire, onCancel: onCancel)
        // orderFrontRegardless makes the window visible without changing key focus or
        // activating our app — user can keep interacting with whatever they're in.
        w.orderFrontRegardless()
        return w
    }

    // MARK: – Init

    init(seconds:  Int,
         onFire:   @escaping () -> Void,
         onCancel: @escaping () -> Void) {
        self.remaining = seconds
        self.onFire    = onFire
        self.onCancel  = onCancel

        let side: CGFloat = 110
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let origin = CGPoint(x: screen.frame.midX - side / 2,
                             y: screen.frame.midY - side / 2)

        super.init(
            contentRect: NSRect(origin: origin, size: NSSize(width: side, height: side)),
            styleMask:   [.borderless],
            backing:     .buffered,
            defer:       false
        )
        level                = .screenSaver
        isOpaque             = false
        backgroundColor      = .clear
        isReleasedWhenClosed = false
        collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Click-through so the user can interact with windows beneath the overlay
        // without needing to click away first.
        ignoresMouseEvents   = true

        let bg = NSView(frame: contentView!.bounds)
        bg.wantsLayer             = true
        bg.layer?.cornerRadius    = 18
        bg.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.88).cgColor
        bg.autoresizingMask       = [.width, .height]
        contentView?.addSubview(bg)

        countLabel                  = NSTextField(labelWithString: "\(seconds)")
        countLabel.font             = .systemFont(ofSize: 52, weight: .bold)
        countLabel.textColor        = .white
        countLabel.alignment        = .center
        countLabel.frame            = bg.bounds
        countLabel.autoresizingMask = [.width, .height]
        bg.addSubview(countLabel)

        installEscapeMonitors()
        startTick()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: – Countdown

    private func startTick() {
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            remaining -= 1
            if remaining <= 0 {
                countTimer?.invalidate()
                countLabel.stringValue = "✓"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.finish()
                }
            } else {
                countLabel.stringValue = "\(remaining)"
            }
        }
        RunLoop.main.add(t, forMode: .common)
        countTimer = t
    }

    private func finish() {
        guard !cancelled else { return }
        cancelled = true
        removeEscapeMonitors()
        close()
        onFire()
    }

    private func cancel() {
        guard !cancelled else { return }
        cancelled = true
        countTimer?.invalidate()
        removeEscapeMonitors()
        close()
        onCancel()
    }

    // MARK: – Escape detection

    // Local monitor: fires when our app is active (or overlay is key).
    // Global monitor: fires when user has switched to another app.
    //   Requires Accessibility — already needed by HotkeyManager; if not granted,
    //   local monitor still handles the common case.
    private func installEscapeMonitors() {
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.cancel(); return nil }  // consume Escape
            return event
        }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                DispatchQueue.main.async { self?.cancel() }
            }
        }
    }

    private func removeEscapeMonitors() {
        if let m = localMonitor  { NSEvent.removeMonitor(m);  localMonitor  = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
    }

    // MARK: – Window policy

    // Not key, not main: the overlay never hijacks focus.
    override var canBecomeKey:  Bool { false }
    override var canBecomeMain: Bool { false }

    deinit {
        countTimer?.invalidate()
        removeEscapeMonitors()
    }
}
