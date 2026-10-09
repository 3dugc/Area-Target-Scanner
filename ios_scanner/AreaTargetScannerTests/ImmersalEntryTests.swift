import XCTest
@testable import AreaTargetScanner

final class ImmersalEntryTests: XCTestCase {
    func testStatusUsesOperationStageForItsOwnTask() {
        let task = job(scanName: "scan_A", mapName: "CloudA")
        XCTAssertEqual(ImmersalMappingPresentation.statusTitle(for: task, busyJobID: task.id,
            operationTitle: "正在检查云端工作区"), "正在检查云端工作区")
    }

    func testAnotherTasksBusyStageDoesNotReplaceSelectedTaskStatus() {
        var task = job(scanName: "scan_B", mapName: "CloudB")
        task.phase = .pending
        XCTAssertEqual(ImmersalMappingPresentation.statusTitle(for: task, busyJobID: UUID(),
            operationTitle: "正在检查云端工作区"), "等待建图")
    }

    func testDeletingAnUnconfirmedSubmissionExplainsLocalScopeAndPossibleCloudMap() {
        var task = job(scanName: "scan_A", mapName: "CloudA")
        task.pendingOperation = .construct
        let message = ImmersalMappingPresentation.deletionMessage(for: task)
        XCTAssertTrue(message.contains("扫描数据"))
        XCTAssertTrue(message.contains("云端"))
        XCTAssertTrue(message.contains("不会取消"))
        XCTAssertTrue(message.contains("待确认") || message.contains("尚未确认"))
    }

    func testPreparationDoesNotSelectAnotherScansUnfinishedTask() {
        let unrelated = job(scanName: "scan_B", mapName: "CloudB")

        XCTAssertNil(ImmersalMappingPresentation.currentJob(
            jobs: [unrelated], scanName: "scan_A", selectedJobID: nil))
    }

    func testTaskSelectionUsesIdentityEvenWhenEntryHasAnotherScan() {
        let first = job(scanName: "scan_A", mapName: "CloudA")
        let selected = job(scanName: "scan_B", mapName: "CloudB")

        XCTAssertEqual(ImmersalMappingPresentation.currentJob(
            jobs: [first, selected], scanName: "scan_A", selectedJobID: selected.id)?.id,
                       selected.id)
    }

    func testMissingSelectedTaskDoesNotSilentlyShowAnotherTask() {
        let other = job(scanName: "scan_A", mapName: "CloudA")

        XCTAssertNil(ImmersalMappingPresentation.currentJob(
            jobs: [other], scanName: "scan_A", selectedJobID: UUID()))
    }

    func testPreparationPrefersUnfinishedTaskForTheSameScan() {
        var finished = job(scanName: "scan_A", mapName: "Finished")
        finished.phase = .done
        let unfinished = job(scanName: "scan_A", mapName: "Unfinished")

        XCTAssertEqual(ImmersalMappingPresentation.currentJob(
            jobs: [finished, unfinished], scanName: "scan_A", selectedJobID: nil)?.id,
                       unfinished.id)
    }

    func testRenamedSceneTitleDoesNotChangeCloudOrDirectoryIdentity() {
        let task = job(scanName: "scan_A", mapName: "CloudA")
        var names = ["scan_A": "一楼大厅"]
        let resolve: (String) -> String? = { names[$0] }

        XCTAssertEqual(ImmersalMappingPresentation.sceneTitle(
            scanName: task.scanName, job: task, resolve: resolve), "一楼大厅")
        names["scan_A"] = "东侧大厅"
        XCTAssertEqual(ImmersalMappingPresentation.sceneTitle(
            scanName: task.scanName, job: task, resolve: resolve), "东侧大厅")
        XCTAssertEqual(task.scanName, "scan_A")
        XCTAssertEqual(task.mapName, "CloudA")
    }

    func testLegacyTaskFallsBackToExistingDisplayName() {
        let id = UUID()
        let task = ImmersalMappingJob(id: id, userID: 1, scanName: "scan_A",
                                     mapName: "Legacy" + id.uuidString.replacingOccurrences(of: "-", with: ""),
                                     createdAt: Date())

        XCTAssertEqual(ImmersalMappingPresentation.sceneTitle(
            scanName: task.scanName, job: task, resolve: { _ in nil }), "Legacy")
    }

    private func job(scanName: String, mapName: String) -> ImmersalMappingJob {
        ImmersalMappingJob(id: UUID(), userID: 1, scanName: scanName,
                           mapName: mapName, createdAt: Date())
    }
}
