import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// Small seams that keep the sign-in driver testable on Linux: file system, process
// launching, clock and environment. Each has a real implementation used by the app.

// MARK: - File system

public protocol LoginFileSystem: Sendable {
    func fileExists(_ path: String) -> Bool
    func isDirectory(_ path: String) -> Bool
    /// True for regular files (symlinks followed) with an execute bit for the current user.
    func isExecutableFile(_ path: String) -> Bool
    /// Entry names (not paths); empty when the directory is missing or unreadable.
    func contentsOfDirectory(_ path: String) -> [String]
    /// Creates `path` (and missing parents) with mode 0700. Existing directories keep their mode.
    func createPrivateDirectory(_ path: String) throws
    /// Writes atomically and then applies `mode` (for example 0o600 or 0o700).
    func writeFile(_ path: String, contents: Data, mode: Int) throws
    func readFile(_ path: String) -> Data?
    /// Removes a file or directory tree without following symlinks inside it.
    func removeItem(_ path: String) throws
    /// Physical path of an existing item (symlinks and `..` resolved), or nil when it does not exist.
    func realPath(_ path: String) -> String?
}

public struct SystemLoginFileSystem: LoginFileSystem {
    public init() {}

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func isExecutableFile(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    public func contentsOfDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    public func createPrivateDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func writeFile(_ path: String, contents: Data, mode: Int) throws {
        try contents.write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    public func readFile(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    public func removeItem(_ path: String) throws {
        try FileManager.default.removeItem(atPath: path)
    }

    public func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

// MARK: - Processes

public struct LoginLaunchSpec: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var currentDirectory: String?

    public init(executable: String, arguments: [String], environment: [String: String], currentDirectory: String? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.currentDirectory = currentDirectory
    }
}

public struct LoginRunResult: Equatable, Sendable {
    public var status: Int32
    public var output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// A long-running child (the CLI's sign-in command).
public protocol LoginChildProcess: Sendable {
    /// Asks the child to stop (SIGTERM). Safe to call more than once or after it exited.
    func terminate()
}

public protocol LoginProcessLaunching: Sendable {
    /// Starts a child with stdin kept open (never written) and output discarded.
    /// `onExit` is called once, on any thread, with the exit status.
    func launch(_ spec: LoginLaunchSpec, onExit: @escaping @Sendable (Int32) -> Void) throws -> LoginChildProcess
    /// Runs a short command and captures stdout. Nil when it cannot start or exceeds `timeout` (it is then terminated).
    func run(_ spec: LoginLaunchSpec, timeout: TimeInterval) -> LoginRunResult?
    /// Sends SIGTERM to a process TokenBar did not launch directly (the CLI started in Terminal).
    func terminateProcess(pid: Int32)
    /// Whether a process with this PID still exists.
    func isProcessRunning(pid: Int32) -> Bool
}

public struct SystemLoginProcessLauncher: LoginProcessLaunching {
    public init() {}

    public func launch(_ spec: LoginLaunchSpec, onExit: @escaping @Sendable (Int32) -> Void) throws -> LoginChildProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = spec.environment
        if let dir = spec.currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: dir) }
        // A pipe that is never written keeps stdin open, so the CLI waits for its browser
        // callback instead of seeing end-of-file.
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let child = SystemLoginChild(process: process, stdin: stdin)
        process.terminationHandler = { p in
            child.closeStdin()
            onExit(p.terminationStatus)
        }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            child.closeStdin()
            throw error
        }
        return child
    }

    public func run(_ spec: LoginLaunchSpec, timeout: TimeInterval) -> LoginRunResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = spec.environment
        if let dir = spec.currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: dir) }
        let out = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }

        let buffer = LockedBox(Data())
        let readDone = DispatchSemaphore(value: 0)
        let reader = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            let data = reader.readDataToEndOfFile()
            buffer.set(data)
            readDone.signal()
        }
        if exited.wait(timeout: .now() + max(0, timeout)) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            return nil
        }
        // Output of a well-behaved command is complete at exit; do not hang on a grandchild holding the pipe.
        _ = readDone.wait(timeout: .now() + 1)
        return LoginRunResult(status: process.terminationStatus, output: String(decoding: buffer.get(), as: UTF8.self))
    }

    public func terminateProcess(pid: Int32) {
        guard pid > 1 else { return }
        _ = kill(pid_t(pid), SIGTERM)
    }

    public func isProcessRunning(pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid_t(pid), 0) == 0 || errno == EPERM
    }
}

final class SystemLoginChild: LoginChildProcess, @unchecked Sendable {
    private let process: Process
    private let stdin: Pipe
    private let lock = NSLock()
    private var stdinClosed = false

    init(process: Process, stdin: Pipe) {
        self.process = process
        self.stdin = stdin
    }

    func closeStdin() {
        lock.lock()
        let shouldClose = !stdinClosed
        stdinClosed = true
        lock.unlock()
        if shouldClose { try? stdin.fileHandleForWriting.close() }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
        closeStdin()
    }
}

/// A tiny lock-protected value box.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func get() -> Value {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Value) {
        lock.lock(); defer { lock.unlock() }
        value = newValue
    }

    @discardableResult
    func update<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

// MARK: - Clock

public protocol LoginClock: Sendable {
    func now() -> Date
    func sleep(seconds: TimeInterval) async
}

public struct SystemLoginClock: LoginClock {
    public init() {}
    public func now() -> Date { Date() }
    public func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}

// MARK: - Environment

public struct LoginEnvironment: Sendable {
    /// The app's own environment. A GUI app usually has a minimal PATH.
    public var variables: [String: String]
    public var homeDirectory: String

    public init(variables: [String: String], homeDirectory: String) {
        self.variables = variables
        self.homeDirectory = homeDirectory
    }

    public static var current: LoginEnvironment {
        LoginEnvironment(variables: ProcessInfo.processInfo.environment,
                         homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
    }
}
