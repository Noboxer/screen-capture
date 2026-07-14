import AppKit

/// In-app updater (#5). Queries the GitHub Releases API for the latest published
/// release, compares it to the running bundle version, and — on the user's
/// confirmation — downloads the release DMG, swaps /Applications/ScreenCapture.app,
/// and relaunches.
///
/// Requires the release assets to be publicly downloadable (a public repo, or a
/// public releases repo), since the app authenticates with no token.
enum Updater {

    static let repoOwner = "Noboxer"
    static let repoName  = "screen-capture"
    static let appPath   = "/Applications/ScreenCapture.app"

    enum UpdaterError: LocalizedError {
        case badResponse, noAsset
        var errorDescription: String? {
            switch self {
            case .badResponse: return "Couldn't read the release information from GitHub."
            case .noAsset:     return "The latest release has no .dmg download attached."
            }
        }
    }

    struct Release {
        let version: String
        let dmgURL:  URL
        let htmlURL: URL
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Public entry point

    static func checkForUpdates(userInitiated: Bool) {
        fetchLatest { result in
            switch result {
            case .failure(let err):
                if userInitiated { presentError(err) }
            case .success(let rel):
                if isNewer(rel.version, than: currentVersion) {
                    promptInstall(rel)
                } else if userInitiated {
                    presentInfo(title: "You're up to date",
                                text: "ScreenCapture v\(currentVersion) is the latest version.")
                }
            }
        }
    }

    // MARK: - Network

    private static func fetchLatest(_ completion: @escaping (Result<Release, Error>) -> Void) {
        let url = URL(string: "https://api.github.com/repos/\(repoOwner)/\(repoName)/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ScreenCapture-Updater", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { data, _, err in
            DispatchQueue.main.async {
                if let err { completion(.failure(err)); return }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag  = json["tag_name"] as? String,
                      let assets = json["assets"] as? [[String: Any]] else {
                    completion(.failure(UpdaterError.badResponse)); return
                }
                guard let dmg = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".dmg") == true }),
                      let dmgStr = dmg["browser_download_url"] as? String,
                      let dmgURL = URL(string: dmgStr) else {
                    completion(.failure(UpdaterError.noAsset)); return
                }
                let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let htmlURL = URL(string: (json["html_url"] as? String) ?? "") ?? url
                completion(.success(Release(version: version, dmgURL: dmgURL, htmlURL: htmlURL)))
            }
        }.resume()
    }

    /// Dotted numeric version compare. "1.10" > "1.9", "1.1.0" > "1.0".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Install

    private static func promptInstall(_ rel: Release) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Update available — v\(rel.version)"
        alert.informativeText = "You have v\(currentVersion). Download and install v\(rel.version)? "
            + "ScreenCapture will relaunch when it's done."
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Release Notes")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn:  downloadAndInstall(rel)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(rel.htmlURL)
        default: break
        }
    }

    private static func downloadAndInstall(_ rel: Release) {
        URLSession.shared.downloadTask(with: rel.dmgURL) { tmpURL, _, err in
            guard let tmpURL, err == nil else {
                DispatchQueue.main.async { presentError(err ?? UpdaterError.badResponse) }
                return
            }
            let dmgPath = NSTemporaryDirectory() + "ScreenCapture-update.dmg"
            try? FileManager.default.removeItem(atPath: dmgPath)
            do {
                try FileManager.default.moveItem(at: tmpURL, to: URL(fileURLWithPath: dmgPath))
            } catch {
                DispatchQueue.main.async { presentError(error) }
                return
            }
            DispatchQueue.main.async { installDMG(atPath: dmgPath) }
        }.resume()
    }

    private static func installDMG(atPath dmgPath: String) {
        // Mount, replace the app bundle, strip quarantine (the user already trusts
        // this update — it came from inside the running, trusted app), unmount.
        let script = """
        set -e
        MNT=$(mktemp -d /tmp/sc-update.XXXXXX)
        hdiutil attach "\(dmgPath)" -nobrowse -noverify -mountpoint "$MNT" >/dev/null
        rm -rf "\(appPath)"
        cp -R "$MNT/ScreenCapture.app" "\(appPath)"
        xattr -dr com.apple.quarantine "\(appPath)" 2>/dev/null || true
        hdiutil detach "$MNT" >/dev/null 2>&1 || true
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        let errPipe = Pipe()
        task.standardError = errPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            presentError(error); return
        }

        guard task.terminationStatus == 0 else {
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            presentInfo(title: "Update failed",
                        text: "Couldn't install the update.\n\n\(msg)")
            return
        }

        // Relaunch: a detached shell waits for this process to exit, then reopens
        // the freshly-installed bundle. No KeepAlive is involved anymore.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/bash")
        relaunch.arguments = ["-c", "sleep 1; open -n \"\(appPath)\""]
        try? relaunch.run()
        NSApp.terminate(nil)
    }

    // MARK: - Alerts

    private static func presentError(_ error: Error) {
        presentInfo(title: "Couldn't check for updates", text: error.localizedDescription)
    }

    private static func presentInfo(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
