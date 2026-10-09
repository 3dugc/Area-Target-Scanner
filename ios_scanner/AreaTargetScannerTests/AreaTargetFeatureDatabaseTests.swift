import XCTest
import SQLite3
@testable import AreaTargetScanner

final class AreaTargetFeatureDatabaseTests: XCTestCase {
    func testLoadsProductionORBAndOptionalAKAZE() throws {
        let fixture = try AreaTargetSQLiteFixture(akaze: true)
        defer { fixture.remove() }
        let database = try AreaTargetFeatureDatabase.load(url: fixture.url)
        XCTAssertEqual(database.vocabulary.count, 1)
        XCTAssertEqual(database.vocabulary[0].id, 0)
        XCTAssertEqual(database.keyframes[0].id, 7)
        XCTAssertEqual(database.keyframes[0].pose[3], 0.25)
        XCTAssertEqual(database.keyframes[0].orb.count, 1)
        XCTAssertEqual(database.keyframes[0].orb.descriptors.count, 32)
        XCTAssertEqual(database.keyframes[0].akaze?.descriptors.count, 61)
        XCTAssertEqual(database.featureCount, 2)
        XCTAssertEqual(database.keyframes[0].orb.points3D, [1, 2, -3])
    }
    func testLoadsWithoutOptionalAKAZE() throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        let database = try AreaTargetFeatureDatabase.load(url: fixture.url)
        XCTAssertNil(database.keyframes[0].akaze)
        XCTAssertEqual(database.featureCount, 1)
    }
    func testLoadsEveryKeyframeAt100And500CapacityWithinExistingFeatureLimits() throws {
        for count in [100, 500] {
            let fixture = try AreaTargetSQLiteFixture(akaze: true); defer { fixture.remove() }
            try fixture.populateCoverage(frameCount: count)
            let database = try AreaTargetFeatureDatabase.load(url: fixture.url)
            XCTAssertEqual(database.keyframes.count, count)
            XCTAssertEqual(database.keyframes.map(\.id), Array(8..<(8 + count)).map(Int32.init))
            XCTAssertEqual(database.featureCount, 200_000)
            XCTAssertEqual(database.keyframes.reduce(0) { $0 + $1.orb.count }, 160_000)
            XCTAssertEqual(database.keyframes.reduce(0) { $0 + ($1.akaze?.count ?? 0) }, 40_000)
        }
    }
    func testMissingFileDoesNotCreateFile() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try AreaTargetFeatureDatabase.load(url: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testRejectsCorruptDatabase() throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        try Data("SQLite format 3\0broken".utf8).write(to: fixture.url)
        XCTAssertThrowsError(try AreaTargetFeatureDatabase.load(url: fixture.url))
    }
    func testRejectsWrongSchemaInvalidBLOBsNonfiniteValuesOrphansAndEmptyData() throws {
        for mutation in ["ALTER TABLE features RENAME TO wrong_features",
                         "UPDATE features SET descriptor=zeroblob(31)",
                         "UPDATE vocabulary SET descriptor=zeroblob(33)",
                         "UPDATE keyframes SET pose=zeroblob(127)",
                         "UPDATE akaze_features SET descriptor=zeroblob(60)",
                         "UPDATE features SET x3d=1e999", "UPDATE vocabulary SET idf_weight=1e999",
                         "UPDATE features SET keyframe_id=8", "DELETE FROM features", "DELETE FROM vocabulary",
                         "UPDATE vocabulary SET word_id=2147483648", "UPDATE keyframes SET id=-1",
                         "UPDATE features SET descriptor='text'",
                         "INSERT INTO keyframes SELECT 8,pose,NULL FROM keyframes WHERE id=7"] {
            let fixture = try AreaTargetSQLiteFixture(akaze: true); defer { fixture.remove() }
            try fixture.execute(mutation)
            XCTAssertThrowsError(try AreaTargetFeatureDatabase.load(url: fixture.url), mutation)
        }
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        var pose = AreaTargetSQLiteFixture.pose; pose[1] = .infinity
        try fixture.setPose(pose)
        XCTAssertThrowsError(try AreaTargetFeatureDatabase.load(url: fixture.url))
    }
    func testRejectsBudgetsBeforeAllocatingArrays() throws {
        for mutation in [
            "WITH RECURSIVE n(i) AS (SELECT 8 UNION ALL SELECT i+1 FROM n WHERE i<1007) INSERT INTO keyframes SELECT i,zeroblob(128),NULL FROM n",
            "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<=4096) INSERT INTO vocabulary SELECT i,zeroblob(32),1 FROM n",
            "WITH RECURSIVE n(i) AS (SELECT 2 UNION ALL SELECT i+1 FROM n WHERE i<=200000) INSERT INTO features SELECT i,7,1,2,1,2,-3,zeroblob(32) FROM n"
        ] {
            let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
            try fixture.execute(mutation)
            XCTAssertThrowsError(try AreaTargetFeatureDatabase.load(url: fixture.url), mutation)
        }
    }
    func testRejectsFiniteNonAffineScaledAndReflectedPoses() throws {
        for indexAndValue in [(15,0.0),(0,2.0),(10,-1.0)] {
            let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
            var pose = AreaTargetSQLiteFixture.pose; pose[indexAndValue.0] = indexAndValue.1
            try fixture.setPose(pose)
            XCTAssertThrowsError(try AreaTargetFeatureDatabase.load(url:fixture.url))
        }
    }
    func testRejectsPerKeyframeORBAndAKAZEAndTotalBoWWorkBudgets() throws {
        for statements in [
            ["WITH RECURSIVE n(i) AS (SELECT 2 UNION ALL SELECT i+1 FROM n WHERE i<2001) INSERT INTO features SELECT i,7,1,2,1,2,-3,zeroblob(32) FROM n"],
            ["WITH RECURSIVE n(i) AS (SELECT 2 UNION ALL SELECT i+1 FROM n WHERE i<8193) INSERT INTO akaze_features SELECT i,7,1,2,1,2,-3,zeroblob(61) FROM n"],
            ["WITH RECURSIVE n(i) AS (SELECT 8 UNION ALL SELECT i+1 FROM n WHERE i<31) INSERT INTO keyframes SELECT i,(SELECT pose FROM keyframes WHERE id=7),NULL FROM n",
             "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<4095) INSERT INTO vocabulary SELECT i,zeroblob(32),1 FROM n",
             "DELETE FROM features; WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<2000) INSERT INTO features SELECT (id-7)*2000+i,id,1,2,1,2,-3,zeroblob(32) FROM keyframes CROSS JOIN n"]
        ] {
            let fixture = try AreaTargetSQLiteFixture(akaze:true); defer { fixture.remove() }
            for sql in statements { try fixture.execute(sql) }
            XCTAssertThrowsError(try AreaTargetFeatureDatabase.load(url:fixture.url))
        }
    }
    func testRepeatedReadsReleaseSQLiteConnectionsAndStatements() throws {
        let fixture = try AreaTargetSQLiteFixture(); defer { fixture.remove() }
        _ = try AreaTargetFeatureDatabase.load(url:fixture.url)
        let baseline = sqlite3_memory_used()
        for _ in 0..<30 { _ = try AreaTargetFeatureDatabase.load(url:fixture.url) }
        XCTAssertLessThanOrEqual(sqlite3_memory_used(),baseline + 4096,"Prepared statements must not keep SQLite connections alive")
    }
    func testErrorUsesFixedLocalizedDescriptionWithoutPath() {
        XCTAssertFalse((AreaTargetOfflineError.invalidDatabase.errorDescription ?? "").contains("/"))
        XCTAssertFalse((AreaTargetOfflineError.invalidDatabase.errorDescription ?? "").isEmpty)
    }
}

/// Actual temporary SQLite databases using the server's ordinary-table schema.
final class AreaTargetSQLiteFixture {
    let url: URL
    static let pose: [Double] = [1,0,0,0.25,0,1,0,-0.5,0,0,1,0.75,0,0,0,1]
    init(akaze: Bool = false) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("area-target-" + UUID().uuidString + ".db")
        try execute("CREATE TABLE keyframes(id INTEGER PRIMARY KEY,pose BLOB NOT NULL,global_descriptor BLOB); CREATE TABLE features(id INTEGER PRIMARY KEY,keyframe_id INTEGER NOT NULL,x REAL NOT NULL,y REAL NOT NULL,x3d REAL NOT NULL,y3d REAL NOT NULL,z3d REAL NOT NULL,descriptor BLOB NOT NULL); CREATE TABLE vocabulary(word_id INTEGER PRIMARY KEY,descriptor BLOB NOT NULL,idf_weight REAL NOT NULL); INSERT INTO keyframes VALUES(7,zeroblob(128),NULL); INSERT INTO features VALUES(1,7,10,20,1,2,-3,zeroblob(32)); INSERT INTO vocabulary VALUES(0,zeroblob(32),1);")
        try setPose(Self.pose)
        if akaze { try execute("CREATE TABLE akaze_features(id INTEGER PRIMARY KEY,keyframe_id INTEGER NOT NULL,x REAL NOT NULL,y REAL NOT NULL,x3d REAL NOT NULL,y3d REAL NOT NULL,z3d REAL NOT NULL,descriptor BLOB NOT NULL); INSERT INTO akaze_features VALUES(1,7,10,20,1,2,-3,zeroblob(61));") }
    }
    func execute(_ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw FixtureError.sqlite }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw FixtureError.sqlite }
    }
    func setPose(_ pose: [Double]) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw FixtureError.sqlite }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE keyframes SET pose=?", -1, &statement, nil) == SQLITE_OK else { throw FixtureError.sqlite }
        defer { sqlite3_finalize(statement) }
        try pose.withUnsafeBytes { bytes in
            guard sqlite3_bind_blob(statement,1,bytes.baseAddress,Int32(bytes.count),unsafeBitCast(-1,to:sqlite3_destructor_type.self)) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_DONE else { throw FixtureError.sqlite }
        }
    }
    func populateCoverage(frameCount: Int) throws {
        precondition([100, 500].contains(frameCount))
        let orb = 160_000 / frameCount, akaze = 40_000 / frameCount
        try execute("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<\(frameCount)) INSERT INTO keyframes SELECT 7+i,pose,NULL FROM keyframes CROSS JOIN n WHERE id=7; DELETE FROM keyframes WHERE id=7; DELETE FROM features; DELETE FROM akaze_features;")
        try execute("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<\(orb)) INSERT INTO features SELECT (id-8)*\(orb)+i,id,i%640,i%480,1+i*0.001,2,-3,zeroblob(32) FROM keyframes CROSS JOIN n;")
        try execute("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<\(akaze)) INSERT INTO akaze_features SELECT (id-8)*\(akaze)+i,id,i%640,i%480,1+i*0.001,2,-3,zeroblob(61) FROM keyframes CROSS JOIN n;")
    }
    func remove() { try? FileManager.default.removeItem(at: url) }
    enum FixtureError: Error { case sqlite }
}
