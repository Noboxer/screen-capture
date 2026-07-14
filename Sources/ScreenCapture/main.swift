import AppKit

// Headless icon-generation mode for the installer. Lets install.sh produce a
// proper .icns without bundling a separate generator binary or shipping a
// prebuilt icon file in source control.
//
//   ScreenCapture --generate-icns /path/to/AppIcon.icns
//
// Runs without NSApplication.shared.run(), exits when finished.
if CommandLine.arguments.contains("--generate-icns") {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--generate-icns"),
          i + 1 < args.count else {
        FileHandle.standardError.write(Data("--generate-icns requires an output path\n".utf8))
        exit(2)
    }
    IconGenerator.writeICNS(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
