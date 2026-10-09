import XCTest
import SceneKit
import simd
@testable import AreaTargetScanner

final class ImmersalMeshOverlayTests: XCTestCase {
    func testOverlayComposesMapAndScanTransformsWithoutRecenteringMesh() {
        let overlay = ImmersalMeshOverlayNode()
        let mesh = SCNNode(geometry: SCNBox(width: 4, height: 2, length: 1, chamferRadius: 0))
        mesh.simdPosition = SIMD3(7, 2, -1)
        var worldFromMap = simd_float4x4(simd_quatf(angle: .pi / 2, axis: SIMD3(0,1,0)))
        worldFromMap.columns.3 = SIMD4(3,0,1,1)
        var mapFromScan = matrix_identity_float4x4
        mapFromScan.columns.3 = SIMD4(2,0,0,1)
        overlay.update(mesh: mesh, worldFromMap: worldFromMap, mapFromScan: mapFromScan, isEnabled: true, opacity: 0.4)
        XCTAssertFalse(overlay.node.isHidden)
        let expected = worldFromMap * mapFromScan * SIMD4<Float>(7,2,-1,1)
        let actual = overlay.node.childNodes[0].simdWorldPosition
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.0001)
        XCTAssertEqual(actual.z, expected.z, accuracy: 0.0001)
        XCTAssertEqual(mesh.simdPosition, SIMD3(7,2,-1), "Never move original mesh to bounding-box center")
        XCTAssertEqual(overlay.node.opacity, 0.4, accuracy: 0.00001)
    }

    func testUnverifiedOrLostLocalizationAndToggleHideWholeMesh() {
        let overlay = ImmersalMeshOverlayNode()
        let mesh = SCNNode(geometry: SCNSphere(radius: 1))
        for (world, scan, enabled) in [(nil, Optional(matrix_identity_float4x4), true),
                                      (Optional(matrix_identity_float4x4), nil, true),
                                      (Optional(matrix_identity_float4x4), Optional(matrix_identity_float4x4), false)] {
            overlay.update(mesh: mesh, worldFromMap: world, mapFromScan: scan, isEnabled: enabled, opacity: 0.6)
            XCTAssertTrue(overlay.node.isHidden)
        }
        overlay.update(mesh: mesh, worldFromMap: matrix_identity_float4x4, mapFromScan: matrix_identity_float4x4, isEnabled: true, opacity: 0.6)
        XCTAssertFalse(overlay.node.isHidden)
        overlay.update(mesh: nil, worldFromMap: nil, mapFromScan: nil, isEnabled: true, opacity: 0.6)
        XCTAssertTrue(overlay.node.isHidden)
        XCTAssertTrue(overlay.node.childNodes.isEmpty)
    }

    func testSourceResolvesOnlySpecifiedJobScanUnderDocuments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("scan_first")
        let second = root.appendingPathComponent("scan_second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        XCTAssertEqual(ImmersalMeshSource.directory(scanName: "scan_second", documentsDirectory: root)?.lastPathComponent, "scan_second")
        for bad in ["", "..", ".", "../scan_first", "scan_first/../scan_second", "/scan_first", "missing"] {
            XCTAssertNil(ImmersalMeshSource.directory(scanName: bad, documentsDirectory: root))
        }
        let link = root.appendingPathComponent("linked_scan")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        XCTAssertNil(ImmersalMeshSource.directory(scanName: "linked_scan", documentsDirectory: root))
    }
}

import SwiftUI
import UIKit

@MainActor
final class ImmersalMeshOverlayRenderTests: XCTestCase {
    func testWireframeAndControlsRenderInLightDarkAndLargeText() async throws {
        for (style, category, name) in [(UIUserInterfaceStyle.light, ContentSizeCategory.large, "mesh-overlay-light"),
                                      (.dark, .large, "mesh-overlay-dark"),
                                      (.light, .accessibilityExtraLarge, "mesh-overlay-large-text")] {
            let geometry = SCNNode(geometry: SCNBox(width: 2.5, height: 1.8, length: 2, chamferRadius: 0))
            geometry.simdEulerAngles = SIMD3(-0.1, 0.25, 0)
            geometry.simdPosition = SIMD3(0, 0, -4)
            let mesh = try ImmersalScanMeshLoader.makeOverlay(from: geometry)
            let overlay = ImmersalMeshOverlayNode()
            overlay.update(mesh: mesh, worldFromMap: matrix_identity_float4x4, mapFromScan: matrix_identity_float4x4, isEnabled: true, opacity: 0.6)
            let scene = SCNScene()
            scene.background.contents = UIColor.darkGray
            scene.rootNode.addChildNode(overlay.node)
            let camera = SCNNode(); camera.camera = SCNCamera(); scene.rootNode.addChildNode(camera)
            let view = NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("线框示例（合成几何）").font(.headline)
                        SceneView(scene: scene, pointOfView: camera).frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 16))
                        ImmersalMeshOverlayControls(showMesh: .constant(true), opacity: .constant(0.6), isReady: true,
                                                   status: "原扫描网格已就绪 · 6 张照片核对一致")
                        Text("实际测试时，对照墙角、门框和地面边缘是否重合。此截图不是实景定位结果。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.padding(24)
                }.background(Color(uiColor: .systemGroupedBackground))
                    .navigationTitle("网格叠加检查").navigationBarTitleDisplayMode(.inline)
            }
            let host = UIHostingController(rootView: view.environment(\.sizeCategory, category))
            host.overrideUserInterfaceStyle = style
            let bounds = CGRect(x: 0, y: 0, width: 393, height: 852)
            let window = UIWindow(frame: bounds); window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = bounds; host.view.layoutIfNeeded()
            try await Task.sleep(nanoseconds: 700_000_000)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let screenshot = UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true; window.rootViewController = nil
        }
    }
}
