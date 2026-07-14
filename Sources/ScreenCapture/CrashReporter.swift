import Foundation
import Darwin

/// Catches uncaught Obj-C exceptions and fatal POSIX signals, dumps the call
/// stack to NSLog (which the LaunchAgent routes to ~/Library/Logs/screen-capture*.log),
/// then re-raises so launchd's KeepAlive can restart the process cleanly.
///
/// Without this, a crash leaves nothing in the log file — just an empty ".log"
/// and a confused user. With it, every crash leaves a stack trace we can diff.
enum CrashReporter {

    static func install() {
        NSSetUncaughtExceptionHandler { exception in
            let name   = exception.name.rawValue
            let reason = exception.reason ?? "(no reason)"
            let stack  = exception.callStackSymbols.joined(separator: "\n")
            NSLog("[CrashReporter] Uncaught NSException: \(name) — \(reason)\n\(stack)")
        }

        // Fatal signals that indicate a real bug, not user-initiated termination.
        // We log + re-raise so launchd KeepAlive restarts the daemon.
        let fatal: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGPIPE]
        for sig in fatal {
            signal(sig) { sig in
                let symbols = Thread.callStackSymbols.joined(separator: "\n")
                NSLog("[CrashReporter] Caught signal \(sig)\n\(symbols)")
                // Restore default handler and re-raise so the process actually dies
                // and launchd notices, instead of looping in a broken state.
                signal(sig, SIG_DFL)
                raise(sig)
            }
        }
    }
}
