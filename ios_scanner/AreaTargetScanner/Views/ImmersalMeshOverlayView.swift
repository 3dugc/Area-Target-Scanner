import SwiftUI
import SceneKit
import ARKit

/// A dedicated parent holds the transform; the authored model is never normalized
/// to a viewer origin or scaled to fit. Unverified/stale alignment stays hidden.
final class ImmersalMeshOverlayNode {
    let node = SCNNode()
    private var source: SCNNode?

    init() { node.name = "scan-mesh-overlay"; node.isHidden = true }

    func update(mesh: SCNNode?, worldFromMap: simd_float4x4?, mapFromScan: simd_float4x4?,
                isEnabled: Bool, opacity: CGFloat) {
        if source !== mesh {
            node.childNodes.forEach { $0.removeFromParentNode() }
            source = mesh
            if let mesh { node.addChildNode(mesh.clone()) }
        }
        node.opacity = opacity.isFinite ? min(1, max(0, opacity)) : 0.6
        guard isEnabled, mesh != nil, let worldFromMap, let mapFromScan else { node.isHidden = true; return }
        let transform = worldFromMap * mapFromScan
        guard (0..<4).allSatisfy({ c in (0..<4).allSatisfy { transform[c][$0].isFinite } }) else {
            node.isHidden = true; return
        }
        node.simdTransform = transform; node.isHidden = false
    }
}

struct ImmersalCameraPreview: UIViewRepresentable {
    let session: ARSession
    let worldFromMap: simd_float4x4?
    let markerInMap: SIMD3<Float>?
    let scanMesh: SCNNode?
    let mapFromScan: simd_float4x4?
    let showMesh: Bool
    let meshOpacity: Double

    final class Coordinator { let overlay = ImmersalMeshOverlayNode() }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = session; view.scene = SCNScene()
        view.scene.rootNode.addChildNode(context.coordinator.overlay.node)
        let anchor = SCNNode(); anchor.name = "test-marker"
        let ball = SCNSphere(radius: 0.08)
        ball.firstMaterial?.diffuse.contents = UIColor.systemCyan
        ball.firstMaterial?.lightingModel = .constant
        anchor.geometry = ball; anchor.isHidden = true
        view.scene.rootNode.addChildNode(anchor)
        return view
    }

    func updateUIView(_ view: ARSCNView, context: Context) {
        context.coordinator.overlay.update(mesh: scanMesh, worldFromMap: worldFromMap,
            mapFromScan: mapFromScan, isEnabled: showMesh, opacity: CGFloat(meshOpacity))
        guard let marker = view.scene.rootNode.childNode(withName: "test-marker", recursively: false) else { return }
        // The original point marker remains the fallback when no verified mesh is available.
        guard scanMesh == nil || mapFromScan == nil, let worldFromMap, let markerInMap else { marker.isHidden = true; return }
        let world = worldFromMap * SIMD4(markerInMap, 1)
        marker.simdPosition = SIMD3(world.x, world.y, world.z); marker.isHidden = false
    }
    static func dismantleUIView(_ view: ARSCNView, coordinator: Coordinator) { view.session.pause() }
}

struct ImmersalMeshOverlayControls: View {
    @Binding var showMesh: Bool
    @Binding var opacity: Double
    let isReady: Bool
    let status: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("叠加原扫描网格", isOn: $showMesh).font(.headline)
                .accessibilityIdentifier("show-scan-mesh")
            Text(status).font(.footnote).foregroundStyle(.secondary)
            if showMesh {
                HStack {
                    Text("网格透明度").font(.subheadline)
                    Spacer()
                    Text("\(Int((1 - opacity) * 100))%").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: Binding(get: { 1 - opacity }, set: { opacity = 1 - $0 }), in: 0.1...0.85)
                    .accessibilityLabel("网格透明度")

            }
        }.padding(16).background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }
}
