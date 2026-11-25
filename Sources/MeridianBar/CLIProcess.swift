import Foundation
import os

// Subprocess plumbing for AccountManager. Arguments travel as argv, never
// through a shell. Output is drained by pipe handlers with a bounded tail, so
// a chatty CLI cannot grow memory. Timeout and task cancellation terminate the
// child's whole process group: Foundation's Process gives every child its own
// group (verified on macOS 26), so a nested `claude auth login` spawned by
// `meridian profile add` dies together with Meridian.

enum CLITool: String, Sendable {
    case claude, meridian
}

struct CLIPromptReply: Equatable, Sendable {
    /// Substring of stdout/stderr that identifies the prompt.
    var prompt: String
    /// Written to stdin once, when the prompt appears.
    var reply: String
}

struct CLIProcessSpec: Sendable {
    var executable: URL
    var arguments: [String]
    var environment: [String: String]
    /// Login flows may read stdin lazily; keep it open (no EOF) until exit.
    var keepsStdinOpen = false
    var promptReplies: [CLIPromptReply] = []
    var timeout: Duration = .seconds(30)
    /// Bytes retained per stream; only the tail survives beyond this.
    var outputLimit = 64 * 1024
}

struct CLIProcessResult: Sendable {
    var exitStatus: Int32
    var wasSignaled: Bool
    var stdout: Data
    var stderr: Data

    var succeeded: Bool { !wasSignaled && exitStatus == 0 }
}

enum CLIProcessFailure: Error, Equatable {
    case launchFailed(String)
    case timedOut
    case cancelled
}

/// Injection point: tests substitute a scripted runner so no real CLI runs.
protocol CLIProcessRunning: Sendable {
    func run(_ spec: CLIProcessSpec) async throws -> CLIProcessResult
}

/// Finds CLI executables for a GUI process whose PATH is the launchd default.
struct CLIToolLocator: Sendable {
    let home: URL
    let environment: [String: String]

    private static let systemBinDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    private static let homeBinDirectories = [
        ".local/bin", ".npm-global/bin", ".volta/bin", ".bun/bin", ".claude/local",
    ]

    /// PATH entries first, then the usual install locations, deduplicated.
    var searchPath: [String] {
        var seen = Set<String>()
        var result: [String] = []
        let add = { (entry: String) in
            if !entry.isEmpty, seen.insert(entry).inserted { result.append(entry) }
        }
        for entry in (environment["PATH"] ?? "").split(separator: ":") { add(String(entry)) }
        for dir in Self.homeBinDirectories { add(home.appendingPathComponent(dir).path) }
        for dir in Self.systemBinDirectories { add(dir) }
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm.path) {
            for version in versions.sorted().reversed() {
                add(nvm.appendingPathComponent(version).appendingPathComponent("bin").path)
            }
        }
        return result
    }

    var pathValue: String { searchPath.joined(separator: ":") }

    func locate(_ tool: CLITool) -> URL? {
        let fm = FileManager.default
        for dir in searchPath {
            let candidate = URL(fileURLWithPath: dir).appendingPathComponent(tool.rawValue)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), !isDirectory.boolValue,
                fm.isExecutableFile(atPath: candidate.path)
            {
                return candidate
            }
        }
        return nil
    }
}

/// One-shot latch: `open()` releases every current and future `wait()`.
final class AsyncGate: Sendable {
    private struct State {
        var isOpen = false
        var nextID = 0
        var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var isOpen: Bool { state.withLock { $0.isOpen } }

    func open() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.isOpen = true
            let pending = Array(s.waiters.values)
            s.waiters = [:]
            return pending
        }
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until opened or the current task is cancelled.
    func wait() async {
        let id = state.withLock { s -> Int in
            s.nextID += 1
            return s.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { s -> Bool in
                    if s.isOpen || Task.isCancelled { return true }
                    s.waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.resume()
        }
    }

    /// True when opened before `timeout`; false on timeout or cancellation.
    func wait(timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.wait()
                return self.isOpen
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

/// Bounded stdout/stderr sink that can answer a known prompt on stdin.
/// `@unchecked`: FileHandle is not Sendable; all access goes through the lock
/// or is a single write/close guarded by `stdinOpen`.
private final class OutputCollector: @unchecked Sendable {
    enum Stream { case stdout, stderr }

    private struct State {
        var stdout = Data()
        var stderr = Data()
        var eofCount = 0
        var pendingReplies: [CLIPromptReply]
        var recent = ""
        var stdinOpen = true
    }

    private let state: OSAllocatedUnfairLock<State>
    private let limit: Int
    private let stdin: FileHandle
    /// Opens once both output streams reached EOF.
    let drained = AsyncGate()

    init(limit: Int, replies: [CLIPromptReply], stdin: FileHandle) {
        self.limit = max(limit, 1024)
        self.stdin = stdin
        state = OSAllocatedUnfairLock(initialState: State(pendingReplies: replies))
    }

    func receive(_ data: Data, from stream: Stream) {
        if data.isEmpty {
            let done = state.withLock { s -> Bool in
                s.eofCount += 1
                return s.eofCount >= 2
            }
            if done { drained.open() }
            return
        }
        let reply: Data? = state.withLock { s in
            switch stream {
            case .stdout: Self.append(data, to: &s.stdout, limit: limit)
            case .stderr: Self.append(data, to: &s.stderr, limit: limit)
            }
            guard !s.pendingReplies.isEmpty, s.stdinOpen else { return nil }
            s.recent += String(decoding: data, as: UTF8.self)
            if s.recent.count > 4096 { s.recent = String(s.recent.suffix(4096)) }
            guard let index = s.pendingReplies.firstIndex(where: { s.recent.contains($0.prompt) }) else {
                return nil
            }
            let matched = s.pendingReplies.remove(at: index)
            s.recent = ""
            return Data(matched.reply.utf8)
        }
        if let reply { try? stdin.write(contentsOf: reply) }
    }

    func closeStdin() {
        let wasOpen = state.withLock { s -> Bool in
            defer { s.stdinOpen = false }
            return s.stdinOpen
        }
        if wasOpen { try? stdin.close() }
    }

    func snapshot() -> (stdout: Data, stderr: Data) {
        state.withLock { ($0.stdout, $0.stderr) }
    }

    private static func append(_ data: Data, to buffer: inout Data, limit: Int) {
        buffer.append(data)
        let excess = buffer.count - limit
        if excess > 0 { buffer.removeFirst(excess) }
    }
}

struct SystemProcessRunner: CLIProcessRunning {
    func run(_ spec: CLIProcessSpec) async throws -> CLIProcessResult {
        let process = Process()
        process.executableURL = spec.executable
        process.arguments = spec.arguments
        process.environment = spec.environment
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let exited = AsyncGate()
        let output = OutputCollector(
            limit: spec.outputLimit, replies: spec.promptReplies, stdin: stdinPipe.fileHandleForWriting)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            output.receive(data, from: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            output.receive(data, from: .stderr)
        }
        process.terminationHandler = { _ in exited.open() }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            output.closeStdin()
            throw CLIProcessFailure.launchFailed(spec.executable.lastPathComponent)
        }
        let pid = process.processIdentifier
        if !spec.keepsStdinOpen, spec.promptReplies.isEmpty { output.closeStdin() }

        let finished = await withTaskCancellationHandler {
            await exited.wait(timeout: spec.timeout)
        } onCancel: {
            Self.terminate(pid: pid, exited: exited)
        }
        if !finished {
            Self.terminate(pid: pid, exited: exited)
            _ = await exited.wait(timeout: .seconds(3))
        }
        _ = await output.drained.wait(timeout: .seconds(1))
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        output.closeStdin()
        try? stdoutPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForReading.close()

        if Task.isCancelled { throw CLIProcessFailure.cancelled }
        if !finished { throw CLIProcessFailure.timedOut }
        let collected = output.snapshot()
        return CLIProcessResult(
            exitStatus: process.terminationStatus,
            wasSignaled: process.terminationReason == .uncaughtSignal,
            stdout: collected.stdout,
            stderr: collected.stderr)
    }

    /// SIGTERM the child's process group now, SIGKILL it if still alive in 2 s.
    private static func terminate(pid: pid_t, exited: AsyncGate) {
        guard pid > 0, !exited.isOpen else { return }
        deliver(SIGTERM, to: pid)
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            if !exited.isOpen { deliver(SIGKILL, to: pid) }
        }
    }

    private static func deliver(_ signal: Int32, to pid: pid_t) {
        if kill(-pid, signal) != 0 { kill(pid, signal) }
    }
}
