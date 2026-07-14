import AppKit
import ScreenCaptureKit
import CoreImage

enum CaptureError: Error {
    case noDisplay
    case noFrame
    case cropFailed
}

// macOS error returned when Screen Recording permission is missing or denied.
private let kSCStreamErrorUserDeclined: Int = -3801

@MainActor
private var lastPermissionAlertAt: Date = .distantPast

final class CaptureManager {

    static let shared = CaptureManager()
    private init() {}

    // Guard against rapid double-tap of the hotkey kicking off two overlapping
    // captures (which used to log `cannot run two interactive screen captures
    // at a time`). Set on the main actor before showing the selection overlay,
    // cleared in defer.
    @MainActor private var captureInFlight = false

    // MARK: - Capture delay

    // Returns true if the capture should proceed, false if the user cancelled.
    @MainActor
    private func waitForDelay() async -> Bool {
        let secs = Preferences.shared.captureDelaySeconds
        guard secs > 0 else { return true }
        return await withCheckedContinuation { cont in
            CountdownOverlay.show(
                seconds:  secs,
                onFire:   { cont.resume(returning: true)  },
                onCancel: { cont.resume(returning: false) }
            )
        }
    }

    // MARK: - Screenshot (area select)

    func captureArea() {
        Task { @MainActor in
            guard !captureInFlight else {
                NSLog("[CaptureManager] Area capture ignored — another capture is in flight")
                return
            }
            captureInFlight = true
            defer { captureInFlight = false }

            guard await waitForDelay() else { return }
            do {
                guard let selection = await SelectionOverlay.selectRect() else { return }

                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                   onScreenWindowsOnly: false)
                let screen  = NSScreen.main ?? NSScreen.screens[0]
                let display = try scDisplay(for: screen, in: content)
                let sourceRect = scRect(from: selection, screen: screen)

                let (image, scale) = try await captureRegion(display: display, sourceRect: sourceRect)
                AnnotationWindowController.open(image: image, captureScale: scale)
            } catch {
                NSLog("[CaptureManager] Area capture failed: \(error)")
                handleCaptureError(error)
            }
        }
    }

    // MARK: - Screenshot (fullscreen)

    func captureFullscreen() {
        Task { @MainActor in
            guard !captureInFlight else {
                NSLog("[CaptureManager] Fullscreen capture ignored — another capture is in flight")
                return
            }
            captureInFlight = true
            defer { captureInFlight = false }

            guard await waitForDelay() else { return }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                   onScreenWindowsOnly: false)
                let screen  = NSScreen.main ?? NSScreen.screens[0]
                let display = try scDisplay(for: screen, in: content)
                let (image, scale) = try await captureRegion(display: display, sourceRect: nil)
                AnnotationWindowController.open(image: image, captureScale: scale)
            } catch {
                NSLog("[CaptureManager] Fullscreen capture failed: \(error)")
                handleCaptureError(error)
            }
        }
    }

    // MARK: - User-visible error surface

    /// When ScreenCaptureKit returns -3801 ("user declined TCCs"), surface a single
    /// alert with a direct link to System Settings. Throttled to once per 30 s so
    /// rapid hotkey mashing doesn't spam alerts.
    @MainActor
    private func handleCaptureError(_ error: Error) {
        let ns = error as NSError
        guard ns.code == kSCStreamErrorUserDeclined else { return }

        if Date().timeIntervalSince(lastPermissionAlertAt) < 30 { return }
        lastPermissionAlertAt = Date()

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText     = "Screen Recording permission needed"
        alert.informativeText = "ScreenCapture can receive hotkeys but cannot read the screen until you grant Screen Recording.\n\nOpen Privacy & Security → Screen Recording, enable ScreenCapture, then press the hotkey again."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - ScreenCaptureKit frame grab

    // Returns the captured image and the display's backingScaleFactor so callers
    // can attach correct DPI metadata without querying the annotation window's screen.
    private func captureRegion(display: SCDisplay, sourceRect: CGRect?) async throws -> (CGImage, CGFloat) {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()

        let screen     = nsScreen(for: display)
        let scale      = screen.backingScaleFactor
        let colorSpace = screen.colorSpace?.cgColorSpace
            ?? CGColorSpace(name: CGColorSpace.displayP3)!

        if let sourceRect {
            // sourceRect is in logical points; physical pixels = points × scale.
            config.sourceRect = sourceRect
            config.width  = Int((sourceRect.width  * scale).rounded())
            config.height = Int((sourceRect.height * scale).rounded())
        } else {
            // NSScreen.frame is unambiguously in logical points; multiply by scale for pixels.
            let sz = screen.frame.size
            config.width  = Int((sz.width  * scale).rounded())
            config.height = Int((sz.height * scale).rounded())
        }

        config.pixelFormat = kCVPixelFormatType_32BGRA
        // scalesToFit = false: prevents SCKit from interpolating down to logical-point
        // dimensions, preserving the full HiDPI pixel count we requested above.
        config.scalesToFit = false
        config.showsCursor = false
        if let csName = colorSpace.name {
            config.colorSpaceName = csName
        }

        // SCScreenshotManager (macOS 14+) is the correct one-shot capture API.
        // It avoids the overhead of a persistent SCStream and the timing risks of
        // waiting for the first frame from a stream delegate.
        let raw = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)

        // Re-render through CIContext to guarantee the output CGImage is tagged
        // with the display color space, regardless of what captureImage embeds.
        let ci  = CIImage(cgImage: raw)
        let ctx = CIContext(options: [
            .workingColorSpace: colorSpace,
            .outputColorSpace:  colorSpace,
            .useSoftwareRenderer: false,
        ])
        guard let result = ctx.createCGImage(ci, from: ci.extent,
                                              format: .RGBA8,
                                              colorSpace: colorSpace) else {
            throw CaptureError.noFrame
        }
        return (result, scale)
    }

    // MARK: - Display helpers

    /// Returns the SCDisplay whose CGDirectDisplayID matches the given NSScreen.
    private func scDisplay(for screen: NSScreen, in content: SCShareableContent) throws -> SCDisplay {
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        if let id, let match = content.displays.first(where: { $0.displayID == id }) { return match }
        guard let fallback = content.displays.first else { throw CaptureError.noDisplay }
        return fallback
    }

    /// Returns the NSScreen whose CGDirectDisplayID matches the given SCDisplay.
    private func nsScreen(for display: SCDisplay) -> NSScreen {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
        } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: - Coordinate helper (AppKit screen coords → SCStream top-left origin)

    private func scRect(from selection: CGRect, screen: NSScreen) -> CGRect {
        let screenH = screen.frame.height
        return CGRect(
            x: selection.origin.x,
            y: screenH - selection.origin.y - selection.height,
            width:  selection.width,
            height: selection.height
        )
    }

    // MARK: - Clipboard

    private var autoDeleteWorkItem: DispatchWorkItem?

    func copyToClipboard(_ image: CGImage, scale: CGFloat = 0) {
        let resolvedScale = scale > 0 ? scale : (NSScreen.main?.backingScaleFactor ?? 2.0)
        let logicalSize = NSSize(width:  CGFloat(image.width)  / resolvedScale,
                                 height: CGFloat(image.height) / resolvedScale)
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = logicalSize
        let dpi = 72.0 * resolvedScale

        let pb = NSPasteboard.general
        pb.clearContents()

        switch Preferences.shared.imageFormat {
        case .heif:
            // NSPasteboardItem lets us offer HEIC, PNG fallback, and TIFF in one item.
            // Receiving apps pick the first type they support; ICC profile is embedded
            // automatically because the CGImage carries its display color space.
            let item = NSPasteboardItem()
            let heicData = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(heicData, "public.heic" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, image, [
                    kCGImageDestinationLossyCompressionQuality: Preferences.shared.heifQuality,
                    kCGImagePropertyDPIWidth:  dpi,
                    kCGImagePropertyDPIHeight: dpi,
                ] as CFDictionary)
                if CGImageDestinationFinalize(dest) {
                    item.setData(heicData as Data, forType: NSPasteboard.PasteboardType("public.heic"))
                }
            }
            // PNG fallback so apps that don't accept HEIC (e.g. older Slack) still work.
            if let png = pngData(from: image, dpi: dpi) {
                item.setData(png, forType: .png)
            }
            if let tiff = rep.tiffRepresentation {
                item.setData(tiff, forType: .tiff)
            }
            pb.writeObjects([item])

        case .png:
            let nsImg = NSImage(size: logicalSize)
            nsImg.addRepresentation(rep)
            pb.writeObjects([nsImg])   // TIFF for legacy app compat
            if let png = pngData(from: image, dpi: dpi) {
                pb.addTypes([.png], owner: nil)
                pb.setData(png, forType: .png)
            }
        }

        scheduleAutoDelete()
    }

    /// Encodes a CGImage as PNG with embedded ICC profile and DPI metadata.
    func pngData(from image: CGImage, dpi: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [
            kCGImagePropertyDPIWidth:  dpi,
            kCGImagePropertyDPIHeight: dpi,
        ] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? (data as Data) : nil
    }

    func scheduleAutoDelete() {
        autoDeleteWorkItem?.cancel()
        autoDeleteWorkItem = nil
        let secs = Preferences.shared.autoDeleteSeconds
        guard secs > 0 else { return }
        // Snapshot the changeCount immediately after our write so we can detect
        // whether the user has copied something else before the timer fires.
        let snapshot = NSPasteboard.general.changeCount
        let item = DispatchWorkItem {
            let pb = NSPasteboard.general
            // Abort if anything wrote to the pasteboard after our capture —
            // that means the user pasted something of their own in the meantime.
            guard pb.changeCount == snapshot else { return }
            pb.clearContents()
        }
        autoDeleteWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(secs), execute: item)
    }

    // MARK: - Video

    private let recorder = VideoRecorder()

    func toggleVideo() {
        Task { @MainActor in
            if recorder.active {
                setRecordingIndicator(false)
                RecordingOverlay.shared.hide()
                guard let tempURL = await recorder.stop() else { return }
                saveVideoWithPanel(tempURL: tempURL)
                return
            }

            // Determine recording region from preferences. The hotkey is the same
            // whether the user wants fullscreen or area — they pick once in Settings.
            let sourceRect: CGRect?
            var overlayRegion: CGRect?          // AppKit screen coords, for the recording overlay
            var overlayScreen: NSScreen?
            switch Preferences.shared.videoRegion {
            case .fullscreen:
                sourceRect = nil
            case .selection:
                guard let selection = await SelectionOverlay.selectRect() else { return }
                let screen = NSScreen.main ?? NSScreen.screens[0]
                sourceRect    = scRect(from: selection, screen: screen)
                overlayRegion = selection
                overlayScreen = screen
            }

            do {
                try await recorder.start(sourceRect: sourceRect)
                setRecordingIndicator(true)
                // Show the "what's being recorded" overlay for area recordings (#11).
                if let region = overlayRegion, let screen = overlayScreen {
                    RecordingOverlay.shared.show(region: region, on: screen)
                }
            } catch {
                NSLog("[CaptureManager] Video start failed: \(error)")
                RecordingOverlay.shared.hide()
                handleCaptureError(error)
            }
        }
    }

    private func setRecordingIndicator(_ recording: Bool) {
        (NSApp.delegate as? AppDelegate)?.setRecording(recording)
    }

    private func saveVideoWithPanel(tempURL: URL) {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        panel.nameFieldStringValue = "Screen Recording \(formatter.string(from: Date())).mov"
        panel.directoryURL = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.canCreateDirectories = true

        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()

        if response == .OK, let dest = panel.url {
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: tempURL, to: dest)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(dest.path, forType: .string)
                NSLog("[CaptureManager] Video saved → \(dest.path)")
            } catch {
                NSLog("[CaptureManager] Failed to move video: \(error)")
            }
        } else {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }
}
