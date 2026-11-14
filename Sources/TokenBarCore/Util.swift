import Foundation

/// Small, allocation-light helpers shared by the parsers.
enum JSON {
    /// Parses one JSON object; returns nil for anything else (never throws).
    static func object(_ data: Data) -> [String: Any]? {
        guard !data.isEmpty,
              let any = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return any as? [String: Any]
    }

    static func int(_ value: Any?) -> Int {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        if let d = value as? Double, d.isFinite { return Int(d) }
        if let s = value as? String, let i = Int(s) { return i }
        return 0
    }

    static func int64(_ value: Any?) -> Int64? {
        if let i = value as? Int64 { return i }
        if let i = value as? Int { return Int64(i) }
        if let n = value as? NSNumber { return n.int64Value }
        if let d = value as? Double, d.isFinite { return Int64(d) }
        return nil
    }

    static func double(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let n = value as? NSNumber { return n.doubleValue }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty else { return nil }
        return s
    }
}

extension Data {
    /// Cheap substring pre-filter so we only JSON-decode lines that can matter.
    func containsASCII(_ needle: String) -> Bool {
        range(of: Data(needle.utf8)) != nil
    }
}

/// Fast, locale-independent ISO-8601 parser (`2025-10-02T10:15:30.123Z`,
/// offsets such as `+08:00` are honoured, a missing zone means UTC).
public enum ISO8601 {
    public static func parse(_ string: String) -> Date? {
        let u = Array(string.utf8)
        guard u.count >= 19 else { return nil }
        func num(_ from: Int, _ len: Int) -> Int? {
            var v = 0
            for i in from..<(from + len) {
                guard i < u.count, u[i] >= 48, u[i] <= 57 else { return nil }
                v = v * 10 + Int(u[i] - 48)
            }
            return v
        }
        guard let y = num(0, 4), u[4] == 45, let mo = num(5, 2), u[7] == 45, let d = num(8, 2),
              u[10] == 84 || u[10] == 32 || u[10] == 116,
              let h = num(11, 2), u[13] == 58, let mi = num(14, 2), u[16] == 58, let s = num(17, 2),
              (1...12).contains(mo), (1...31).contains(d), h < 24, mi < 60, s < 61 else { return nil }
        var idx = 19
        var frac = 0.0
        if idx < u.count, u[idx] == 46 || u[idx] == 44 {
            idx += 1
            var scale = 0.1
            while idx < u.count, u[idx] >= 48, u[idx] <= 57 {
                frac += Double(u[idx] - 48) * scale
                scale /= 10
                idx += 1
            }
        }
        var offset = 0
        if idx < u.count {
            if u[idx] == 90 || u[idx] == 122 {
                offset = 0
            } else if u[idx] == 43 || u[idx] == 45 {
                let sign = u[idx] == 45 ? -1 : 1
                guard let oh = num(idx + 1, 2) else { return nil }
                var om = 0
                var p = idx + 3
                if p < u.count, u[p] == 58 { p += 1 }
                if p + 1 < u.count, let m = num(p, 2) { om = m }
                offset = sign * (oh * 3600 + om * 60)
            } else {
                return nil
            }
        }
        let days = daysFromCivil(y, mo, d)
        let secs = Double(days * 86400 + h * 3600 + mi * 60 + s - offset)
        return Date(timeIntervalSince1970: secs + frac)
    }

    /// Howard Hinnant's days_from_civil.
    static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146097 + doe - 719468
    }
}

/// "1.2M"-style abbreviations for the menu bar and popover.
public enum TokenFormatter {
    public static func compact(_ n: Int) -> String {
        let v = Double(abs(n))
        let sign = n < 0 ? "-" : ""
        func fmt(_ x: Double, _ suffix: String) -> String {
            // One decimal below 10, none from 100 up; strip trailing ".0".
            let s: String
            if x >= 100 { s = String(format: "%.0f", x) }
            else if x >= 10 { s = String(format: "%.0f", x) }
            else { s = String(format: "%.1f", x) }
            return sign + (s.hasSuffix(".0") ? String(s.dropLast(2)) : s) + suffix
        }
        switch v {
        case 999_500_000...: return fmt(v / 1_000_000_000, "B")
        case 999_500...: return fmt(v / 1_000_000, "M")
        case 1_000...: return fmt(v / 1_000, "K")
        default: return "\(n)"
        }
    }

    /// Full number with thousands separators, e.g. "1,234,567".
    public static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
}
