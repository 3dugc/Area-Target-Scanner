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
    var hasImmersalZip: Bool = false
    var keyframeCount: Int = 0

    static func < (lhs: ScanHistoryItem, rhs: ScanHistoryItem) -> Bool {
        lhs.date > rhs.date // 最新的排前面
    }

    /// 两种处理流程显示同一份扫描的人类可读名称。
    static func displayName(for directoryName: String) -> String {
        guard isStandardScanName(directoryName), parseDate(from: directoryName) != nil else {
            return "扫描记录"
        }
        let value = Array(directoryName.dropFirst(5))
        return "扫描 \(String(value[0..<4]))-\(String(value[4..<6]))-\(String(value[6..<8])) \(String(value[9..<11])):\(String(value[11..<13])):\(String(value[13..<15]))"
    }

    /// Immersal 名称需要 1–24 个 ASCII 字母或数字；同一扫描默认名保持稳定。
    static func defaultImmersalMapName(for directoryName: String) -> String {
        guard isStandardScanName(directoryName), parseDate(from: directoryName) != nil else {
            return "Scan"
        }
        return "Scan" + directoryName.dropFirst(5).replacingOccurrences(of: "_", with: "")
    }

    private static func isStandardScanName(_ directoryName: String) -> Bool {
        let bytes = Array(directoryName.utf8)
        guard bytes.count == 20, directoryName.hasPrefix("scan_"), bytes[13] == 95 else { return false }
        return bytes[5..<13].allSatisfy { (48...57).contains($0) }
            && bytes[14..<20].allSatisfy { (48...57).contains($0) }
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
