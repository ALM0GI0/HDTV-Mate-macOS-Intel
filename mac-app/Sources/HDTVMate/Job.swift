import Foundation
import Darwin

/// A shell pipeline started in its own process group, so stop() reaches every
/// process in it (hdtvmate, python, ffmpeg) and never the app itself.
final class Job {
    let pid: pid_t

    private init(pid: pid_t) { self.pid = pid }

    static func spawn(_ command: String, env: [String: String], stdoutFD: Int32? = nil,
                      onLine: @escaping (String) -> Void,
                      onExit: @escaping (Int32) -> Void) -> Job? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }

        var fa: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fa)
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        if let out = stdoutFD {
            posix_spawn_file_actions_adddup2(&fa, out, 1)
            posix_spawn_file_actions_addclose(&fa, out)
        } else {
            posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&fa, fds[1], 2)
        posix_spawn_file_actions_addclose(&fa, fds[0])
        posix_spawn_file_actions_addclose(&fa, fds[1])

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)

        let argStrings: [String] = ["/bin/bash", "-c", command]
        var argv: [UnsafeMutablePointer<CChar>?] = argStrings.map { s -> UnsafeMutablePointer<CChar>? in strdup(s) }
        argv.append(nil)
        let envStrings: [String] = env.map { "\($0.key)=\($0.value)" }
        var envp: [UnsafeMutablePointer<CChar>?] = envStrings.map { s -> UnsafeMutablePointer<CChar>? in strdup(s) }
        envp.append(nil)
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, "/bin/bash", &fa, &attr, argv, envp)
        argv.forEach { free($0) }
        envp.forEach { free($0) }
        posix_spawn_file_actions_destroy(&fa)
        posix_spawnattr_destroy(&attr)
        close(fds[1])
        guard rc == 0 else { close(fds[0]); return nil }

        let fd = fds[0]
        let childPid = pid
        let job = Job(pid: childPid)
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 8192)
            var line: [UInt8] = []
            while true {
                let n = read(fd, &buf, buf.count)
                if n <= 0 { break }
                for i in 0..<n {
                    let b = buf[i]
                    if b == 10 || b == 13 {
                        if !line.isEmpty {
                            let s = String(decoding: line, as: UTF8.self)
                            DispatchQueue.main.async { onLine(s) }
                            line.removeAll(keepingCapacity: true)
                        }
                    } else {
                        line.append(b)
                    }
                }
            }
            if !line.isEmpty {
                let s = String(decoding: line, as: UTF8.self)
                DispatchQueue.main.async { onLine(s) }
            }
            close(fd)
            var status: Int32 = 0
            waitpid(childPid, &status, 0)
            DispatchQueue.main.async { onExit(status) }
        }
        return job
    }

    /// Ctrl-C the whole pipeline (hdtvmate shuts the tuner down cleanly), then force it.
    func terminate() {
        let p = pid
        killpg(p, SIGINT)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if killpg(p, 0) == 0 { killpg(p, SIGKILL) }
        }
    }

    /// Blocking version used when the app quits.
    func terminateNow() {
        killpg(pid, SIGINT)
        for _ in 0..<30 {
            if killpg(pid, 0) != 0 { return }
            usleep(100_000)
        }
        killpg(pid, SIGKILL)
    }
}
