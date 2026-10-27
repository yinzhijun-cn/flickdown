import AppKit
import Darwin

let isChinese = Locale.preferredLanguages.first?.hasPrefix("zh") ?? false

/// Picks the UI string for the user's language.
func L(_ zh: String, _ en: String) -> String { isChinese ? zh : en }

enum Prefs {
    static var showOutline: Bool {
        get { UserDefaults.standard.object(forKey: "showOutline") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showOutline") }
    }

    static var sourceMode: Bool {
        get { UserDefaults.standard.bool(forKey: "sourceMode") }
        set { UserDefaults.standard.set(newValue, forKey: "sourceMode") }
    }

    static var zoom: Double {
        get { let z = UserDefaults.standard.double(forKey: "zoom"); return z == 0 ? 1 : z }
        set { UserDefaults.standard.set(newValue, forKey: "zoom") }
    }

    static var pageWidth: PageWidth {
        get { UserDefaults.standard.string(forKey: "pageWidth").flatMap(PageWidth.init) ?? .standard }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "pageWidth") }
    }
}

/// The preview's text column width; the raw value is the page's `data-width` (web/index.html sets the widths).
enum PageWidth: String {
    case standard, wide, full
}

/// Startup and render timing, enabled with FLICK_BENCH=1.
/// Lines go to stderr and, if FLICK_BENCH_LOG is set, are appended to that file (scripts/bench.sh reads it).
enum Bench {
    static let env = ProcessInfo.processInfo.environment
    static let enabled = env["FLICK_BENCH"] != nil
    static let processStart: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return now() }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }()

    static func now() -> Double { Date().timeIntervalSince1970 }

    static func mark(_ event: String, _ detail: @autoclosure () -> String = "") {
        guard enabled else { return }
        let t = now()
        let line = String(format: "[flick] %.6f %8.1fms %@ %@\n", t, (t - processStart) * 1000, event, detail())
        FileHandle.standardError.write(Data(line.utf8))
        if let path = env["FLICK_BENCH_LOG"], let handle = FileHandle(forWritingAtPath: path) ?? create(path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        }
    }

    private static func create(_ path: String) -> FileHandle? {
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }
}
