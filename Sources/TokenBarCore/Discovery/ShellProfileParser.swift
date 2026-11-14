import Foundation

/// A CLI home directory named in a shell start-up file, e.g. `export CODEX_HOME=~/.codex-work`
/// or `alias claude-work='CLAUDE_CONFIG_DIR=~/.claude-work claude'`.
public struct ShellVariableHint: Equatable, Sendable {
    public var name: String
    /// Absolute path with `~` / `$HOME` expanded.
    public var value: String
    /// Alias or function name the assignment appeared in, used as a fallback account name.
    public var label: String?
    public var file: String

    public init(name: String, value: String, label: String? = nil, file: String) {
        self.name = name
        self.value = value
        self.label = label
        self.file = file
    }
}

/// Reads the variables that relocate a CLI's home out of the user's shell start-up files.
///
/// A GUI app does not inherit the terminal's environment, so this is how TokenBar learns about
/// profiles that only exist in `.zshrc` and friends. Only simple, literal assignments are understood:
/// values may use `~`, `$HOME` and `${HOME}`; anything else that needs a shell to evaluate is skipped.
/// Files are never executed and `source` lines are not followed.
public enum ShellProfileParser {
    /// Start-up files read, relative to the home directory.
    public static let profileFiles = [
        ".zshenv", ".zprofile", ".zshrc", ".zlogin",
        ".bash_profile", ".bashrc", ".profile",
        ".config/fish/config.fish",
    ]

    public static func hints(variables: Set<String>, fileSystem fs: FileSystem) -> [ShellVariableHint] {
        let home = fs.homeDirectory
        var files = profileFiles.map { home + "/" + $0 }
        let fishConf = home + "/.config/fish/conf.d"
        files += fs.entries(of: fishConf).filter { $0.hasSuffix(".fish") }.sorted().map { fishConf + "/" + $0 }

        var out: [ShellVariableHint] = []
        for file in files {
            guard let data = fs.contents(of: file, maxBytes: 2 * 1024 * 1024),
                  let text = String(data: data, encoding: .utf8) else { continue }
            for hint in parse(text, variables: variables, home: home, file: file)
            where !out.contains(where: { $0.name == hint.name && $0.value == hint.value }) {
                out.append(hint)
            }
        }
        return out
    }

    public static func parse(_ text: String, variables: Set<String>, home: String, file: String = "") -> [ShellVariableHint] {
        var out: [ShellVariableHint] = []
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let label = commandLabel(in: line)
            for (name, rawValue) in assignments(in: line, variables: variables) {
                guard let value = resolve(rawValue, home: home) else { continue }
                if !out.contains(where: { $0.name == name && $0.value == value }) {
                    out.append(ShellVariableHint(name: name, value: value, label: label, file: file))
                }
            }
        }
        return out
    }

    // MARK: - Lexing

    /// `alias name=…`, fish `alias name '…'`, `name() { … }`, `function name …`.
    static func commandLabel(in line: String) -> String? {
        let patterns = [
            #"^alias\s+([A-Za-z0-9_.:+-]+)\s*="#,
            #"^alias\s+([A-Za-z0-9_.:+-]+)\s+['"]"#,
            #"^(?:function\s+)?([A-Za-z0-9_.:+-]+)\s*\(\)"#,
            #"^function\s+([A-Za-z0-9_.:+-]+)"#,
            #"^abbr\s+(?:-a\s+|--add\s+)?([A-Za-z0-9_.:+-]+)\s"#,
        ]
        for p in patterns {
            if let m = firstMatch(p, in: line, group: 1) { return m }
        }
        return nil
    }

    static func assignments(in line: String, variables: Set<String>) -> [(String, String)] {
        var out: [(String, String)] = []
        let chars = Array(line)
        for name in variables.sorted() {
            // POSIX style: NAME=value anywhere a word can start (export, env, inside alias quotes, functions).
            var searchFrom = line.startIndex
            while let r = line.range(of: name + "=", range: searchFrom..<line.endIndex) {
                searchFrom = r.upperBound
                let start = line.distance(from: line.startIndex, to: r.lowerBound)
                if start > 0 {
                    let prev = chars[start - 1]
                    guard prev == " " || prev == "\t" || prev == "'" || prev == "\"" || prev == ";" || prev == "(" || prev == "{" else { continue }
                }
                let valueStart = line.distance(from: line.startIndex, to: r.upperBound)
                if let v = readValue(chars, from: valueStart) { out.append((name, v)) }
            }
            // fish: set -gx NAME value / set --export NAME value
            let fish = #"(?:^|[\s;])set\s+((?:-{1,2}[A-Za-z]+\s+)+)"# + NSRegularExpression.escapedPattern(for: name) + #"\s+(.+)$"#
            if let re = try? NSRegularExpression(pattern: fish),
               let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let flagsRange = Range(m.range(at: 1), in: line), let restRange = Range(m.range(at: 2), in: line) {
                let flags = line[flagsRange]
                let exported = flags.contains("--export") || flags.split(separator: " ").contains { $0.hasPrefix("-") && !$0.hasPrefix("--") && $0.contains("x") }
                if exported, let v = readValue(Array(line[restRange]), from: 0) { out.append((name, v)) }
            }
        }
        return out
    }

    /// Reads one shell word starting at `i`, honouring simple quoting; backslash escapes are dropped.
    static func readValue(_ chars: [Character], from i: Int) -> String? {
        guard i < chars.count else { return nil }
        var value = ""
        var j = i
        var quote: Character?
        while j < chars.count {
            let c = chars[j]
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && q == "\"" && j + 1 < chars.count { j += 1; value.append(chars[j]) } else { value.append(c) }
            } else if c == "\\" && j + 1 < chars.count {
                j += 1
                let next = chars[j]
                if next != "\"" && next != "'" { value.append(next) }
            } else if c == "\"" || c == "'" {
                // An opening quote right at the start belongs to the value; anywhere else it closes an
                // enclosing alias quote (alias x='A=/p cmd') and ends the word.
                if value.isEmpty && j == i { quote = c } else { break }
            } else if c == " " || c == "\t" || c == ";" || c == "|" || c == "&" || c == ")" {
                break
            } else if c == "}" && !value.contains("{") {
                break       // end of a one-line function body; `${HOME}` keeps its brace
            } else {
                value.append(c)
            }
            j += 1
        }
        return value.isEmpty ? nil : value
    }

    /// Expands `~`, `$HOME` and `${HOME}`. Returns nil for anything that still needs a shell.
    static func resolve(_ raw: String, home: String) -> String? {
        var v = raw.replacingOccurrences(of: "${HOME}", with: home).replacingOccurrences(of: "$HOME", with: home)
        if v == "~" { v = home } else if v.hasPrefix("~/") { v = home + String(v.dropFirst()) }
        guard v.hasPrefix("/"), !v.contains("$"), !v.contains("`"), !v.contains("*"), !v.contains("?") else { return nil }
        return normalizedPath(v, home: home)
    }

    private static func firstMatch(_ pattern: String, in s: String, group: Int) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: group), in: s) else { return nil }
        return String(s[r])
    }
}
