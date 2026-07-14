import AppKit

/// Renders the in-app camera-viewfinder icon at every size required by an .icns
/// bundle, writes them into a temporary .iconset directory, then shells out to
/// `iconutil` to produce the final .icns file.
///
/// Used at install time so the source repo doesn't need to carry a binary icon
/// artifact and the icon stays in sync with the in-app drawing.
enum IconGenerator {

    /// Sizes required by macOS .icns. Both @1x and @2x variants of each base size.
    private static let sizes: [(name: String, pixels: Int)] = [
        ("icon_16x16.png",     16),
        ("icon_16x16@2x.png",  32),
        ("icon_32x32.png",     32),
        ("icon_32x32@2x.png",  64),
        ("icon_128x128.png",   128),
        ("icon_128x128@2x.png",256),
        ("icon_256x256.png",   256),
        ("icon_256x256@2x.png",512),
        ("icon_512x512.png",   512),
        ("icon_512x512@2x.png",1024),
    ]

    static func writeICNS(to url: URL) {
        let fm  = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
        do {
            try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
            for (name, px) in sizes {
                let png = drawIcon(side: px).pngData()
                try png.write(to: tmp.appendingPathComponent(name))
            }

            // iconutil ships with macOS; it bundles the iconset into a single .icns.
            let proc = Process()
            proc.launchPath = "/usr/bin/iconutil"
            proc.arguments  = ["-c", "icns", tmp.path, "-o", url.path]
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                FileHandle.standardError.write(Data("iconutil failed (\(proc.terminationStatus))\n".utf8))
                return
            }
            try? fm.removeItem(at: tmp)
        } catch {
            FileHandle.standardError.write(Data("Icon generation failed: \(error)\n".utf8))
        }
    }

    /// Same visual design as AppDelegate.makeAppIcon but parameterized by pixel
    /// size and pre-rendered to a bitmap rep so it survives PNG encoding cleanly.
    private static func drawIcon(side: Int) -> NSImage {
        let s = CGFloat(side)
        let img = NSImage(size: NSSize(width: s, height: s))
        img.lockFocus()
        defer { img.unlockFocus() }

        // Rounded blue gradient background, matching macOS app-icon squircle radius.
        let path = NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: img.size),
            xRadius: s * 0.225, yRadius: s * 0.225
        )
        NSGradient(colors: [
            NSColor(calibratedRed: 0.20, green: 0.42, blue: 0.95, alpha: 1),
            NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.62, alpha: 1),
        ])!.draw(in: path, angle: -50)

        // Camera viewfinder glyph, tinted white via blend mode.
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.46, weight: .medium)
        if let icon = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let tinted = NSImage(size: icon.size)
            tinted.lockFocus()
            icon.draw(in: NSRect(origin: .zero, size: icon.size))
            if let ctx = NSGraphicsContext.current?.cgContext {
                ctx.setBlendMode(.sourceAtop)
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.95).cgColor)
                ctx.fill(CGRect(origin: .zero, size: icon.size))
                ctx.setBlendMode(.normal)
            }
            tinted.unlockFocus()
            let iw = tinted.size.width, ih = tinted.size.height
            tinted.draw(in: NSRect(x: (s - iw) / 2, y: (s - ih) / 2, width: iw, height: ih),
                        from: .zero, operation: .sourceOver, fraction: 1)
        }
        return img
    }
}

private extension NSImage {
    /// Render this NSImage to PNG-encoded Data at the image's natural size.
    /// Goes through a bitmap rep so the result is guaranteed-deterministic
    /// (lockFocus drawing into an NSImage doesn't always serialize cleanly).
    func pngData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width),
            pixelsHigh: Int(size.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
