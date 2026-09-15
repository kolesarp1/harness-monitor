import Foundation

// Gated perf tracing: launch with HARNESS_USAGE_PERF=1 to log tick/monitor/scan costs to stderr.
// Call sites guard on `enabled` before doing any measurement work, so the off path costs nothing.
public enum PerfLog {
    public static let enabled = ProcessInfo.processInfo.environment["HARNESS_USAGE_PERF"] == "1"
    private static let start = Date()

    public static func log(_ msg: String) {
        guard enabled else { return }
        let line = String(format: "[perf +%09.3f] %@\n", Date().timeIntervalSince(start), msg)
        FileHandle.standardError.write(Data(line.utf8))
    }

    // Duration → milliseconds, for uniform log lines.
    public static func ms(_ d: Duration) -> Double {
        Double(d.components.seconds) * 1000 + Double(d.components.attoseconds) / 1e15
    }
}
