import Foundation
import TokenBarCore

enum Fmt {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f
    }()

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func relative(_ date: Date, to now: Date = Date()) -> String {
        relativeFormatter.localizedString(for: date, relativeTo: now)
    }

    static func clockTime(_ date: Date) -> String { clock.string(from: date) }

    static func tokens(_ n: Int) -> String { TokenFormatter.compact(n) }

    static func periodTitle(_ p: MenuBarPeriod) -> String {
        switch p {
        case .today: return "今日"
        case .last7Days: return "近 7 天"
        case .month: return "本月"
        }
    }

    static func statusText(_ s: ScanStatus) -> String? {
        switch s {
        case .ok: return nil
        case .unknownProvider: return "未知的提供方"
        case .dataDirectoryMissing: return "未找到数据目录，请在设置中检查路径"
        case .noRecentData: return "本月暂无用量记录"
        }
    }
}
