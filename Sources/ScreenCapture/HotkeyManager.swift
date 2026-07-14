import AppKit
import CoreGraphics

/// Self-healing global hotkey manager.
///
/// macOS will silently disable a CGEvent tap under several conditions:
///   • Heavy keyboard input that exceeds the callback time budget (`tapDisabledByTimeout`)
///   • Programmatic disable by another process (`tapDisabledByUserInput`)
///   • System sleep / display sleep (tap may survive, may not)
///   • TCC silently revoking Accessibility (rare, but happens after major updates)
///
/// Without recovery, the daemon stays alive but its hotkeys appear "dead" — the user
/// thinks the app crashed. This class:
///   1. Handles the disable events inside the callback and re-enables the tap inline.
///   2. Polls every 30 s and rebuilds the tap if it has been invalidated.
///   3. Listens for system wake notifications and rebuilds on wake.
///   4. Re-prompts for Accessibility if it gets revoked.
final class HotkeyManager {

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthCheckTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    init() {
        if AXIsProcessTrusted() {
            startTap()
        } else {
            promptAccessibility()
        }
        installWakeObserver()
        startHealthCheck()
    }

    deinit {
        stopTap()
        healthCheckTimer?.invalidate()
        if let obs = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(obs)
        }
    }

    // MARK: - Setup

    private func startTap() {
        // If a tap already exists, tear it down before creating a new one so we
        // don't leak Mach ports across recreations.
        stopTap()

        // We register for the four keyDown bits AND the two "tap was disabled"
        // notifications. The disable bits arrive as a CGEventType with a value
        // outside the normal range; we must check for them in the callback and
        // re-enable inline, otherwise the tap stays dead forever.
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << UInt32(0xFFFFFFFE)) | // kCGEventTapDisabledByTimeout
            (1 << UInt32(0xFFFFFFFF))   // kCGEventTapDisabledByUserInput

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return mgr.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: selfPtr
        ) else {
            NSLog("[HotkeyManager] CGEvent tap creation failed — Accessibility likely revoked")
            // Don't give up: re-prompt and let the health check retry.
            if !AXIsProcessTrusted() { promptAccessibility() }
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[HotkeyManager] Hotkeys active")
    }

    private func stopTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
    }

    private func promptAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(opts as CFDictionary)
        // Poll until granted, then start the tap on the main thread.
        DispatchQueue.global().async { [weak self] in
            while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 1) }
            DispatchQueue.main.async { self?.startTap() }
        }
    }

    // MARK: - Self-healing

    /// Re-enables the tap if macOS has disabled it, recreates it if it's been
    /// invalidated entirely (e.g. revoked permission). Cheap to run — ~one syscall.
    private func startHealthCheck() {
        healthCheckTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.verifyTapHealth()
        }
    }

    private func verifyTapHealth() {
        // No tap at all — Accessibility was probably revoked. Retry if it's back.
        guard let tap = eventTap else {
            if AXIsProcessTrusted() {
                NSLog("[HotkeyManager] Tap missing but Accessibility OK — recreating")
                startTap()
            }
            return
        }
        // Tap exists but macOS paused it for some reason — re-enable it.
        if !CGEvent.tapIsEnabled(tap: tap) {
            NSLog("[HotkeyManager] Tap was disabled — re-enabling")
            CGEvent.tapEnable(tap: tap, enable: true)
            // If re-enabling didn't stick, rebuild from scratch.
            if !CGEvent.tapIsEnabled(tap: tap) {
                NSLog("[HotkeyManager] Re-enable didn't stick — recreating tap")
                startTap()
            }
        }
    }

    private func installWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            NSLog("[HotkeyManager] System woke — verifying tap")
            // Wait a beat for the runloop / Accessibility framework to settle.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self?.verifyTapHealth()
            }
        }
    }

    // MARK: - Event handling

    private func handleEvent(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        // The disable events are delivered with these raw type values.
        // They are NOT members of the CGEventType enum so we compare by rawValue.
        if type.rawValue == 0xFFFFFFFE /* tapDisabledByTimeout */
        || type.rawValue == 0xFFFFFFFF /* tapDisabledByUserInput */ {
            NSLog("[HotkeyManager] Tap disabled by system (type=\(type.rawValue)) — re-enabling inline")
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let mods    = pressedModifiers(event.flags)

        // Ignore plain keystrokes so we never hijack normal typing — a shortcut
        // must carry at least one modifier.
        guard !mods.isEmpty else { return Unmanaged.passUnretained(event) }

        // Preferences are read live on every keyDown, so rebinding a shortcut in
        // Settings takes effect immediately with no re-registration (#1).
        for action in Preferences.ShortcutAction.allCases {
            let sc = Preferences.shared.shortcut(for: action)
            if sc.keyCode == keyCode, sc.modifiers == mods {
                DispatchQueue.main.async { HotkeyManager.perform(action) }
                return nil   // consume event
            }
        }
        return Unmanaged.passUnretained(event)
    }

    /// Translate CGEvent flags into device-independent modifier flags for comparison
    /// against stored shortcuts.
    private func pressedModifiers(_ flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var m = NSEvent.ModifierFlags()
        if flags.contains(.maskControl)   { m.insert(.control) }
        if flags.contains(.maskShift)     { m.insert(.shift) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskCommand)   { m.insert(.command) }
        return m
    }

    private static func perform(_ action: Preferences.ShortcutAction) {
        switch action {
        case .captureArea:       CaptureManager.shared.captureArea()
        case .captureFullscreen: CaptureManager.shared.captureFullscreen()
        case .recordVideo:       CaptureManager.shared.toggleVideo()
        case .quit:              NSApp.terminate(nil)
        }
    }
}
