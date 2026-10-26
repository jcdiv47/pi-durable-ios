import Darwin
import Foundation

/// M0 outputs in `Documents/m0/`, read by `scripts/` through `simctl get_app_container` or
/// `devicectl device copy from`.
enum M0Files {
    static let directory: URL = {
        let url = URL.documentsDirectory.appendingPathComponent("m0", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static func url(_ name: String) -> URL { directory.appendingPathComponent(name) }

    static func writeJSON(_ name: String, _ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
        try data.write(to: url(name), options: .atomic)
    }

    static func removeDatabase(_ url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}

/// Appends one line per `write(2)`, so a line is in the file as soon as `append` returns, even if
/// the process is killed right after.
final class LineLog: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()

    init(_ url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ line: String) {
        lock.withLock { try? handle.write(contentsOf: Data((line + "\n").utf8)) }
    }
}

enum ProcessMetrics {
    /// `phys_footprint` in MiB: the number jetsam compares against the memory limit.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Milliseconds since the kernel created this process (includes dyld and app launch).
    static func msSinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return -1 }
        let start = info.kp_proc.p_un.__p_starttime
        let seconds = Double(start.tv_sec) + Double(start.tv_usec) / 1e6
        return (Date().timeIntervalSince1970 - seconds) * 1000
    }
}

/// Samples `phys_footprint` on a background queue and keeps the peak.
final class FootprintSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Double = 0
    private var samples = 0
    private var timer: DispatchSourceTimer?

    func start(intervalMs: Int = 50) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: .milliseconds(intervalMs))
        timer.setEventHandler { [weak self] in
            let value = ProcessMetrics.footprintMB()
            self?.lock.withLock {
                self?.peak = max(self?.peak ?? 0, value)
                self?.samples += 1
            }
        }
        self.timer = timer
        timer.resume()
    }

    func stop() -> (peakMB: Double, samples: Int) {
        timer?.cancel()
        timer = nil
        return lock.withLock { (peak, samples) }
    }
}
