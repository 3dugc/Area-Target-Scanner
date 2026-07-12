import Foundation

/// 扫描历史记录条目，从 Documents 目录中的 scan_ 文件夹解析而来
struct ScanHistoryItem: Identifiable, Comparable {
    let id: String          // 目录名，如 "scan_20260324_142133"
    let directoryPath: String
    let date: Date
    let formattedDate: String

    // 从文件系统读取的元数据（懒加载）
    var fileCount: Int = 0
    var totalSizeMB: Double = 0
    var hasTexture: Bool = false
    var hasZip: Bool = false
    var keyframeCount: Int = 0

    static func < (lhs: ScanHistoryItem, rhs: ScanHistoryItem) -> Bool {
        lhs.date > rhs.date // 最新的排前面
    }

    /// 从目录名解析日期
    static func parseDate(from dirName: String) -> Date? {
        // scan_yyyyMMdd_HHmmss
        guard dirName.hasPrefix("scan_") else { return nil }
        let dateStr = String(dirName.dropFirst(5))
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter.date(from: dateStr)
    }
}
