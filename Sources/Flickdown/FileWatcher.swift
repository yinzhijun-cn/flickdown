import Foundation

/// Calls `onChange` when the file is modified. Survives atomic saves (write temp file + rename),
/// which most editors use, by re-opening the path whenever the watched inode goes away.
@MainActor
final class FileWatcher {
    private let path: String
    private let onChange: @MainActor () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.path = url.path
        self.onChange = onChange
        attach(retries: 0)
    }

    func stop() {
        pending?.cancel()
        source?.cancel()
        source = nil
    }

    private func attach(retries: Int) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // The editor may not have moved the new file into place yet.
            if retries < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    MainActor.assumeIsolated { self?.attach(retries: retries + 1) }
                }
            }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .revoke], queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                if !source.data.isDisjoint(with: [.delete, .rename, .revoke]) {
                    source.cancel()
                    self.source = nil
                    self.attach(retries: 0)
                }
                self.scheduleChange()
            }
        }
        src.setCancelHandler { close(fd) }
        source = src
        src.resume()
        if retries > 0 { scheduleChange() }
    }

    /// Editors often emit several events per save; coalesce them into one reload.
    private func scheduleChange() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.onChange() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03, execute: work)
    }
}
