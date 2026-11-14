import Foundation

/// Read-only file system seam used by account discovery, so detection is testable with temp dirs or fakes.
public protocol FileSystem: Sendable {
    var homeDirectory: String { get }
    func isDirectory(_ path: String) -> Bool
    func fileExists(_ path: String) -> Bool
    /// Contents of a regular file, or nil when missing, unreadable or larger than `maxBytes`.
    func contents(of path: String, maxBytes: Int) -> Data?
    /// Names (not paths) of the entries in a directory; empty when it cannot be listed.
    func entries(of path: String) -> [String]
    /// Absolute path with symlinks resolved, used to tell whether two paths are the same directory.
    func resolvedPath(_ path: String) -> String
}

public struct LocalFileSystem: FileSystem {
    public let homeDirectory: String

    public init(homeDirectory: String = NSHomeDirectory()) {
        self.homeDirectory = homeDirectory
    }

    public func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    public func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func contents(of path: String, maxBytes: Int) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) == .typeRegular,
              let size = (attrs[.size] as? NSNumber)?.intValue, size <= maxBytes else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    public func entries(of path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    public func resolvedPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Path normalisation shared by discovery and the config: `~` expanded, `.`/`..` and trailing slashes removed.
/// Symlinks are kept, so the path the user knows is the one shown.
public func normalizedPath(_ raw: String, home: String) -> String {
    var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if p == "~" { p = home } else if p.hasPrefix("~/") { p = home + String(p.dropFirst(1)) }
    guard p.hasPrefix("/") else { return p }
    let standardized = URL(fileURLWithPath: p).standardizedFileURL.path
    return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
}
