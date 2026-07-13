import XCTest
import simd
@testable import AreaTargetScanner

final class CoordinateContractTests: XCTestCase {

    func testFixtureComposesExpectedUnityWorldFromScan() throws {
        let fixture = try loadFixture()
        let unityWorldFromCamera = try matrix(named: "unityWorldFromCamera", in: fixture)
        let cameraFromScan = try matrix(named: "cameraFromScan", in: fixture)

        let result = unityWorldFromCamera * cameraFromScan

        XCTAssertEqual(result.columns.3.x, 5, accuracy: 0.00001)
        XCTAssertEqual(result.columns.3.y, 7, accuracy: 0.00001)
        XCTAssertEqual(result.columns.3.z, 9, accuracy: 0.00001)
    }

    func testCameraPoseStoresARKitMatrixInColumnMajorOrder() {
        let transform = simd_float4x4(
            SIMD4<Float>(1, 2, 3, 4),
            SIMD4<Float>(5, 6, 7, 8),
            SIMD4<Float>(9, 10, 11, 12),
            SIMD4<Float>(13, 14, 15, 16)
        )

        let pose = CameraPose(
            timestamp: 1.0,
            transform: transform,
            imageFilename: "frame_0000.jpg"
        )

        XCTAssertEqual(
            pose.transform,
            [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]
        )
    }

    func testFixtureLandscapeRightKeepsImageDimensionsAndIntrinsics() throws {
        let fixture = try loadFixture()
        let image = try XCTUnwrap(fixture["image"] as? [String: Any])
        let intrinsics = try XCTUnwrap(fixture["intrinsics"] as? [String: Any])

        XCTAssertEqual(fixture["imageOrientation"] as? String, "landscapeRight")
        XCTAssertEqual(image["width"] as? Int, 640)
        XCTAssertEqual(image["height"] as? Int, 480)
        XCTAssertEqual(try XCTUnwrap(intrinsics["fx"] as? Double), 500, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(intrinsics["fy"] as? Double), 510, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(intrinsics["cx"] as? Double), 320, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(intrinsics["cy"] as? Double), 240, accuracy: 0.00001)
    }

    private func loadFixture() throws -> [String: Any] {
        let bundle = Bundle(for: CoordinateContractTests.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "coordinate-contract-v1", withExtension: "json"),
            "Coordinate contract fixture must be included in the test bundle"
        )
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func matrix(named name: String, in fixture: [String: Any]) throws -> simd_float4x4 {
        let values = try XCTUnwrap(fixture[name] as? [NSNumber])
        XCTAssertEqual(values.count, 16, "\(name) must contain 16 row-major values")

        return simd_float4x4(
            SIMD4<Float>(values[0].floatValue, values[4].floatValue, values[8].floatValue, values[12].floatValue),
            SIMD4<Float>(values[1].floatValue, values[5].floatValue, values[9].floatValue, values[13].floatValue),
            SIMD4<Float>(values[2].floatValue, values[6].floatValue, values[10].floatValue, values[14].floatValue),
            SIMD4<Float>(values[3].floatValue, values[7].floatValue, values[11].floatValue, values[15].floatValue)
        )
    }
}
