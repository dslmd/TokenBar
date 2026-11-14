import Foundation

/// Finds a CLI binary even though a GUI app starts with a minimal PATH.
///
/// Order: Homebrew, npm global prefixes, Bun, Volta, nvm (newest Node first), ~/.local/bin,
/// provider-specific extras, a few other version managers, the app's PATH, and finally a
/// login shell (`<shell> -lic 'command -v <name>'`).
struct CLILocator: Sendable {
    let fileSystem: LoginFileSystem
    let launcher: LoginProcessLaunching
    let environment: LoginEnvironment
    let loginShellPath: String
    let loginShellTimeout: TimeInterval

    func locate(_ name: String, extraDirectories: [String] = []) -> String? {
        for dir in candidateDirectories(extraDirectories: extraDirectories) {
            let path = (dir as NSString).appendingPathComponent(name)
            if fileSystem.isExecutableFile(path) { return path }
        }
        return locateWithLoginShell(name)
    }

    func candidateDirectories(extraDirectories: [String] = []) -> [String] {
        let home = environment.homeDirectory
        func inHome(_ sub: String) -> String { (home as NSString).appendingPathComponent(sub) }

        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        dirs += npmPrefixes().map { ($0 as NSString).appendingPathComponent("bin") }
        dirs += [inHome(".bun/bin"), inHome(".volta/bin")]
        dirs += nvmBinDirectories()
        dirs.append(inHome(".local/bin"))
        dirs += extraDirectories
        dirs += [inHome("Library/pnpm"), inHome(".asdf/shims"), inHome(".local/share/mise/shims")]
        if let path = environment.variables["PATH"] {
            dirs += path.split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        }
        var seen = Set<String>()
        return dirs.filter { seen.insert($0).inserted }
    }

    /// `$NPM_CONFIG_PREFIX`, the `prefix=` line of ~/.npmrc, and the two common manual prefixes.
    func npmPrefixes() -> [String] {
        let home = environment.homeDirectory
        var prefixes: [String] = []
        if let p = environment.variables["NPM_CONFIG_PREFIX"] ?? environment.variables["npm_config_prefix"],
           let expanded = expandHome(p) {
            prefixes.append(expanded)
        }
        if let data = fileSystem.readFile((home as NSString).appendingPathComponent(".npmrc")) {
            for raw in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("prefix"), let eq = line.firstIndex(of: "=") else { continue }
                guard line[..<eq].trimmingCharacters(in: .whitespaces) == "prefix" else { continue }
                var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
                if let expanded = expandHome(value) { prefixes.append(expanded) }
            }
        }
        prefixes.append((home as NSString).appendingPathComponent(".npm-global"))
        prefixes.append((home as NSString).appendingPathComponent(".npm-packages"))
        return prefixes
    }

    /// `~/.nvm/versions/node/*/bin` (or under `$NVM_DIR`), newest version first.
    func nvmBinDirectories() -> [String] {
        let nvmDir = environment.variables["NVM_DIR"].flatMap(expandHome)
            ?? (environment.homeDirectory as NSString).appendingPathComponent(".nvm")
        let versionsDir = (nvmDir as NSString).appendingPathComponent("versions/node")
        let versions = fileSystem.contentsOfDirectory(versionsDir).filter { !$0.hasPrefix(".") }
        return versions
            .sorted { Self.compareVersions($0, $1) == .orderedDescending }
            .map { (versionsDir as NSString).appendingPathComponent("\($0)/bin") }
    }

    func locateWithLoginShell(_ name: String) -> String? {
        // Only plain command names are ever interpolated into the shell command.
        guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              fileSystem.isExecutableFile(loginShellPath) else { return nil }
        var env = environment.variables
        env["HOME"] = environment.homeDirectory
        let spec = LoginLaunchSpec(executable: loginShellPath, arguments: ["-lic", "command -v \(name)"],
                                   environment: env, currentDirectory: environment.homeDirectory)
        guard let result = launcher.run(spec, timeout: loginShellTimeout), result.status == 0 else { return nil }
        return Self.parseLoginShellOutput(result.output, isExecutable: fileSystem.isExecutableFile)
    }

    /// Interactive shells may print banners; only the last line that is an absolute,
    /// executable path counts. Aliases and functions (`alias x=…`, `x`) are ignored.
    static func parseLoginShellOutput(_ output: String, isExecutable: (String) -> Bool) -> String? {
        for raw in output.split(whereSeparator: \.isNewline).reversed() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("/"), !line.contains(" -> ") else { continue }
            if isExecutable(line) { return line }
        }
        return nil
    }

    private func expandHome(_ value: String) -> String? {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v == "~" { v = environment.homeDirectory }
        else if v.hasPrefix("~/") { v = environment.homeDirectory + v.dropFirst(1) }
        else if v.hasPrefix("$HOME/") { v = environment.homeDirectory + v.dropFirst(5) }
        else if v.hasPrefix("${HOME}/") { v = environment.homeDirectory + v.dropFirst(7) }
        return v.hasPrefix("/") ? v : nil
    }

    /// Compares "v20.11.1"-style names numerically; non-numeric parts sort lowest.
    static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ s: String) -> [Int] {
            let trimmed = s.hasPrefix("v") ? String(s.dropFirst()) : s
            return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? -1 }
        }
        let pa = parts(a), pb = parts(b)
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return a.compare(b)
    }
}
