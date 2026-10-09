import Foundation
import SQLite3

enum AreaTargetOfflineError: LocalizedError {
    case invalidDatabase, unsupported, nativeFailure
    var errorDescription: String? {
        switch self {
        case .invalidDatabase: return "Area Target 特征数据无效，请重新下载或重新处理扫描。"
        case .unsupported: return "当前设备不支持 Area Target 离线定位。"
        case .nativeFailure: return "Area Target 离线引擎无法载入，请重新尝试。"
        }
    }
}

/// The server writes row-major float64 poses and fixed-length binary descriptors.
/// This reader validates the whole bounded snapshot before any native pointer is exposed.
struct AreaTargetFeatureDatabase {
    struct VocabularyWord { let id: Int32; let descriptor: Data; let weight: Float }
    struct FeatureBlock {
        var descriptors = Data()
        var points3D = [Float]()
        var points2D = [Float]()
        var count: Int { points2D.count / 2 }
    }
    struct Keyframe {
        let id: Int32
        let pose: [Float]
        var orb = FeatureBlock()
        var akaze: FeatureBlock?
    }
    // Stored producer profiles are ORB1000 (fast) / ORB2000 (quality).
    static let maximumORBPerKeyframe = 2000
    // AKAZE_create() has no producer cap; this is an explicit mobile memory/matching limit.
    static let maximumAKAZEPerKeyframe = 8192
    static let maximumBoWComparisons = 200_000_000
    let vocabulary: [VocabularyWord]
    let keyframes: [Keyframe]
    var featureCount: Int { keyframes.reduce(0) { $0 + $1.orb.count + ($1.akaze?.count ?? 0) } }

    static func load(url: URL) throws -> Self {
        guard url.isFileURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              size.isRegularFile == true, let byteCount = size.fileSize,
              byteCount > 0, byteCount <= 512 * 1024 * 1024 else { throw AreaTargetOfflineError.invalidDatabase }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let database = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw AreaTargetOfflineError.invalidDatabase
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 250)
        sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 128 * 1024)
        sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 4096)
        sqlite3_limit(database, SQLITE_LIMIT_COLUMN, 64)
        let budget = SQLBudget()
        let context = Unmanaged.passUnretained(budget).toOpaque()
        sqlite3_progress_handler(database, 1000, { raw in
            guard let raw else { return 1 }
            let budget = Unmanaged<SQLBudget>.fromOpaque(raw).takeUnretainedValue()
            budget.ticks += 1
            return budget.ticks > 20_000 || ProcessInfo.processInfo.systemUptime > budget.deadline ? 1 : 0
        }, context)
        defer { sqlite3_progress_handler(database, 0, nil, nil) }
        try execute(database, "PRAGMA query_only=ON")
        try execute(database, "PRAGMA trusted_schema=OFF")
        try execute(database, "BEGIN")
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        let check = try SQLRows(database, "PRAGMA quick_check(1)")
        guard try check.next(), check.text(0) == "ok" else { throw AreaTargetOfflineError.invalidDatabase }
        try requireTable(database, "keyframes", columns: ["id":"INTEGER", "pose":"BLOB", "global_descriptor":"BLOB"])
        let featureColumns = ["id":"INTEGER", "keyframe_id":"INTEGER", "x":"REAL", "y":"REAL", "x3d":"REAL", "y3d":"REAL", "z3d":"REAL", "descriptor":"BLOB"]
        try requireTable(database, "features", columns: featureColumns)
        try requireTable(database, "vocabulary", columns: ["word_id":"INTEGER", "descriptor":"BLOB", "idf_weight":"REAL"])
        let optionalTable = try SQLRows(database, "SELECT type,sql FROM sqlite_master WHERE name='akaze_features'")
        let hasAKAZE = try optionalTable.next()
        if hasAKAZE { try requireTable(database, "akaze_features", columns: featureColumns) }
        let keyframeCount = try count(database, "keyframes", limit: 1000)
        let vocabularyCount = try count(database, "vocabulary", limit: 4096)
        let orbCount = try count(database, "features", limit: 200_000)
        let akazeCount = hasAKAZE ? try count(database, "akaze_features", limit: 200_000) : 0
        guard keyframeCount > 0, vocabularyCount > 0, orbCount > 0,
              orbCount + akazeCount <= 200_000,
              orbCount * vocabularyCount <= maximumBoWComparisons else { throw AreaTargetOfflineError.invalidDatabase }
        try requirePerKeyframeBudget(database, table:"features", maximum:maximumORBPerKeyframe)
        if hasAKAZE { try requirePerKeyframeBudget(database, table:"akaze_features", maximum:maximumAKAZEPerKeyframe) }

        var words = [VocabularyWord]()
        words.reserveCapacity(vocabularyCount)
        let vocabularyRows = try SQLRows(database, "SELECT word_id,descriptor,idf_weight FROM vocabulary ORDER BY word_id")
        var seenWordIDs = Set<Int32>()
        while try vocabularyRows.next() {
            let id = try vocabularyRows.identifier(0)
            guard seenWordIDs.insert(id).inserted else { throw AreaTargetOfflineError.invalidDatabase }
            words.append(VocabularyWord(id: id, descriptor: try vocabularyRows.blob(1, size: 32), weight: try vocabularyRows.number(2)))
        }
        var keyframes = [Keyframe]()
        keyframes.reserveCapacity(keyframeCount)
        var positions = [Int32:Int]()
        let frameRows = try SQLRows(database, "SELECT id,pose FROM keyframes ORDER BY id")
        while try frameRows.next() {
            let id = try frameRows.identifier(0)
            guard positions[id] == nil else { throw AreaTargetOfflineError.invalidDatabase }
            let bytes = try frameRows.blob(1, size: 128)
            let pose: [Float] = try bytes.withUnsafeBytes { raw in
                try (0..<16).map { index in
                    let bits = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self))
                    let value = Double(bitPattern: bits)
                    let narrowed = Float(value)
                    guard value.isFinite, narrowed.isFinite else { throw AreaTargetOfflineError.invalidDatabase }
                    return narrowed
                }
            }
            guard AreaTargetPose.cameraFromScan(rowMajor:pose) != nil else { throw AreaTargetOfflineError.invalidDatabase }
            positions[id] = keyframes.count
            keyframes.append(Keyframe(id: id, pose: pose))
        }
        for (table, length) in hasAKAZE ? [("features", 32), ("akaze_features", 61)] : [("features", 32)] {
            let rows = try SQLRows(database, "SELECT id,keyframe_id,x,y,x3d,y3d,z3d,descriptor FROM \(table) ORDER BY keyframe_id,id")
            var seenIDs = Set<Int32>()
            while try rows.next() {
                let featureID = try rows.identifier(0)
                guard seenIDs.insert(featureID).inserted,
                      let position = positions[try rows.identifier(1)] else { throw AreaTargetOfflineError.invalidDatabase }
                let descriptor = try rows.blob(7, size: length)
                let points2D = try [rows.number(2), rows.number(3)]
                let points3D = try [rows.number(4), rows.number(5), rows.number(6)]
                if length == 32 {
                    keyframes[position].orb.descriptors.append(descriptor)
                    keyframes[position].orb.points2D.append(contentsOf: points2D)
                    keyframes[position].orb.points3D.append(contentsOf: points3D)
                } else {
                    if keyframes[position].akaze == nil { keyframes[position].akaze = FeatureBlock() }
                    keyframes[position].akaze!.descriptors.append(descriptor)
                    keyframes[position].akaze!.points2D.append(contentsOf: points2D)
                    keyframes[position].akaze!.points3D.append(contentsOf: points3D)
                }
            }
        }
        guard keyframes.allSatisfy({ $0.orb.count > 0 }) else { throw AreaTargetOfflineError.invalidDatabase }
        return Self(vocabulary: words, keyframes: keyframes)
    }

    private static func requirePerKeyframeBudget(_ db:OpaquePointer,table:String,maximum:Int) throws {
        let rows = try SQLRows(db,"SELECT keyframe_id FROM \(table) GROUP BY keyframe_id HAVING COUNT(*)>\(maximum) LIMIT 1")
        guard try !rows.next() else { throw AreaTargetOfflineError.invalidDatabase }
    }
    private static func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AreaTargetOfflineError.invalidDatabase }
    }
    private static func count(_ db: OpaquePointer, _ table: String, limit: Int) throws -> Int {
        let rows = try SQLRows(db, "SELECT COUNT(*) FROM (SELECT 1 FROM \(table) LIMIT \(limit + 1))")
        guard try rows.next() else { throw AreaTargetOfflineError.invalidDatabase }
        let value = Int(sqlite3_column_int64(rows.statement, 0))
        guard value <= limit else { throw AreaTargetOfflineError.invalidDatabase }
        return value
    }
    private static func requireTable(_ db: OpaquePointer, _ name: String, columns: [String:String]) throws {
        let schema = try SQLRows(db, "SELECT type,sql FROM sqlite_master WHERE name='\(name)'")
        guard try schema.next(), schema.text(0) == "table",
              let sql = schema.text(1), sql.uppercased().hasPrefix("CREATE TABLE") else { throw AreaTargetOfflineError.invalidDatabase }
        let rows = try SQLRows(db, "PRAGMA table_info(\(name))")
        var actual = [String:String]()
        while try rows.next() { if let name = rows.text(1), let type = rows.text(2) { actual[name] = type.uppercased() } }
        guard columns.allSatisfy({ actual[$0.key] == $0.value }) else { throw AreaTargetOfflineError.invalidDatabase }
    }
}

private final class SQLBudget {
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    var ticks = 0
}
private final class SQLRows {
    let statement: OpaquePointer
    init(_ db: OpaquePointer, _ sql: String) throws {
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_finalize(pointer) }
            throw AreaTargetOfflineError.invalidDatabase
        }
        statement = pointer
    }
    deinit { sqlite3_finalize(statement) }
    func next() throws -> Bool {
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else { throw AreaTargetOfflineError.invalidDatabase }
        return result == SQLITE_ROW
    }
    func text(_ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT, let pointer = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: pointer)
    }
    func identifier(_ column: Int32) throws -> Int32 {
        guard sqlite3_column_type(statement, column) == SQLITE_INTEGER else { throw AreaTargetOfflineError.invalidDatabase }
        let value = sqlite3_column_int64(statement, column)
        guard value >= 0, value <= Int32.max else { throw AreaTargetOfflineError.invalidDatabase }
        return Int32(value)
    }
    func number(_ column: Int32) throws -> Float {
        let type = sqlite3_column_type(statement, column)
        guard type == SQLITE_FLOAT || type == SQLITE_INTEGER else { throw AreaTargetOfflineError.invalidDatabase }
        let value = sqlite3_column_double(statement, column)
        let narrowed = Float(value)
        guard value.isFinite, narrowed.isFinite else { throw AreaTargetOfflineError.invalidDatabase }
        return narrowed
    }
    func blob(_ column: Int32, size: Int) throws -> Data {
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB,
              sqlite3_column_bytes(statement, column) == size,
              let pointer = sqlite3_column_blob(statement, column) else { throw AreaTargetOfflineError.invalidDatabase }
        return Data(bytes: pointer, count: size)
    }
}
