import Foundation
import Darwin

/// Sits between the tuner pipeline and mpv: every byte of the MPEG-TS goes on to
/// the player, and while recording, also to a file. This replaces mpv's
/// stream-record, which fails in the bundled libmpv ("Writing header failed").
///
/// File writes run on their own queue, so a slow or removed SD card can never
/// stall the picture; if the backlog grows too large the recording is marked failed.
final class StreamTap {
    /// Read end for the player (hand it to mpv as fdclose://<fd>).
    let playerFD: Int32

    private let input: Int32
    private let toPlayer: Int32
    private let lock = NSLock()
    private let fileQueue = DispatchQueue(label: "hdtvmate.record.write")
    private var file: Int32 = -1
    private var aligned = false
    private var written: Int64 = 0
    private var backlog: Int = 0
    private var failure: String?
    private static let maxBacklog = 64 << 20

    /// Takes ownership of `input` (the pipeline's read end). Nil if a pipe can't be made.
    init?(input: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        playerFD = fds[0]
        toPlayer = fds[1]
        self.input = input
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)          // mpv going away must not kill the app
        let thread = Thread { [self] in self.pump() }
        thread.name = "hdtvmate.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func pump() {
        let size = 1 << 18
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate(); close(input); close(toPlayer) }
        var playerGone = false
        while true {
            let n = read(input, buf, size)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            if !playerGone {
                var off = 0
                while off < n {
                    let w = write(toPlayer, buf + off, n - off)
                    if w < 0 && errno == EINTR { continue }
                    if w <= 0 { playerGone = true; break }
                    off += w
                }
            }
            record(buf, n)
            if playerGone && !isRecording { break }
        }
    }

    private var isRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return file >= 0
    }

    /// Queue `n` bytes for the recording file, starting at a TS packet boundary.
    private func record(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard file >= 0, failure == nil else { return }
        var start = 0
        if !aligned {
            guard let s = StreamTap.syncOffset(buf, n) else { return }
            start = s
            aligned = true
        }
        let count = n - start
        guard count > 0 else { return }
        if backlog + count > StreamTap.maxBacklog {
            failure = "the drive can't keep up"
            return
        }
        backlog += count
        let data = Data(bytes: buf + start, count: count)
        let fd = file
        fileQueue.async { [weak self] in
            let ok: Bool = data.withUnsafeBytes { raw -> Bool in
                var off = 0
                while off < raw.count {
                    let w = Darwin.write(fd, raw.baseAddress! + off, raw.count - off)
                    if w < 0 && errno == EINTR { continue }
                    if w <= 0 { return false }
                    off += w
                }
                return true
            }
            guard let self = self else { return }
            let err: String? = ok ? nil : String(cString: strerror(errno))
            self.lock.lock()
            self.backlog -= data.count
            if ok { if self.file == fd { self.written += Int64(data.count) } }
            else if self.file == fd && self.failure == nil { self.failure = err ?? "write failed" }
            self.lock.unlock()
        }
    }

    /// First offset where three TS packets in a row start with the 0x47 sync byte.
    private static func syncOffset(_ buf: UnsafeMutablePointer<UInt8>, _ n: Int) -> Int? {
        var i = 0
        while i + 376 < n {
            if buf[i] == 0x47 && buf[i + 188] == 0x47 && buf[i + 376] == 0x47 { return i }
            i += 1
        }
        return nil
    }

    /// Start writing the stream to `path` (replacing any file there). Throws on open failure.
    func startRecording(to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        lock.lock()
        let old = file
        file = fd
        aligned = false
        written = 0
        failure = nil
        lock.unlock()
        if old >= 0 { fileQueue.async { close(old) } }
    }

    /// Stop writing; `done` runs on the main queue once every queued byte is on disk.
    func stopRecording(done: (() -> Void)? = nil) {
        lock.lock()
        let fd = file
        file = -1
        lock.unlock()
        fileQueue.async {
            if fd >= 0 { fsync(fd); close(fd) }
            if let done = done { DispatchQueue.main.async(execute: done) }
        }
    }

    /// Bytes written to the current recording, and why it failed if it did.
    var status: (bytes: Int64, failure: String?) {
        lock.lock(); defer { lock.unlock() }
        return (written, failure)
    }
}
