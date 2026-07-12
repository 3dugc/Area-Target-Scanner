import SwiftUI
import SceneKit
import SceneKit.ModelIO
import ModelIO
import UIKit

/// 3D model preview with SceneKit + debug overlay.
struct ModelPreviewView: View {
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var loadError: String? = nil
    @State private var loadInfo: String? = nil
    @State private var loadSuccess = false

    #if DEBUG
    private var isDebugOverlayEnabled: Bool {
        let processInfo = ProcessInfo.processInfo
        return processInfo.arguments.contains("-ModelPreviewDebug")
            || processInfo.environment["MODEL_PREVIEW_DEBUG"] == "1"
    }
    #endif

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.15, green: 0.15, blue: 0.15).ignoresSafeArea()

            SceneModelView(fileURL: fileURL, onLoad: { success, error in
                loadSuccess = success
                loadError = error
                loadInfo = nil
            }, onInfo: { info in
                loadInfo = info
            })
            .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 8) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.white, .black.opacity(0.6))
                }
                .padding(.top, 56)

                #if DEBUG
                if isDebugOverlayEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("DEBUG 模型预览").font(.caption.weight(.bold)).foregroundStyle(.yellow)
                        Text("URL: \(fileURL.lastPathComponent)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.white)
                        Text("完整路径: \(fileURL.path)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.7))
                        if loadSuccess {
                            Text("✅ 加载成功").font(.caption).foregroundStyle(.green)
                        }
                        if let info = loadInfo {
                            Text("ℹ️ \(info)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.cyan)
                        }
                        if let err = loadError {
                            Text("❌ 错误: \(err)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.red)
                        }
                    }
                    .padding(8)
                    .background(.black.opacity(0.7))
                    .cornerRadius(8)
                }
                #endif
            }
            .padding(.leading, 20)
        }
    }
}

struct SceneModelView: UIViewRepresentable {
    let fileURL: URL
    var onLoad: ((Bool, String?) -> Void)?
    var onInfo: ((String) -> Void)?

    private struct LoadedScene {
        let scene: SCNScene
        let loaderInfo: String
        let textureInfo: String?
    }

    func makeUIView(context: Context) -> SCNView {
        let scnView = SCNView()
        scnView.backgroundColor = UIColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
        scnView.allowsCameraControl = true
        scnView.autoenablesDefaultLighting = true

        do {
            let loadedScene = try loadScene()
            let scene = loadedScene.scene
            scnView.scene = scene

            var nodeCount = 0
            var hasMaterial = false
            var hasTexture = false
            scene.rootNode.enumerateChildNodes { node, _ in
                nodeCount += 1
                if let geometry = node.geometry {
                    for mat in geometry.materials {
                        hasMaterial = true
                        mat.lightingModel = .lambert
                        mat.isDoubleSided = true
                        if mat.diffuse.contents != nil {
                            hasTexture = true
                        }
                    }
                }
            }

            let (minVec, maxVec) = scene.rootNode.boundingBox
            let dx = maxVec.x - minVec.x
            let dy = maxVec.y - minVec.y
            let dz = maxVec.z - minVec.z
            let size = max(dx, max(dy, dz))

            if size > 0 {
                let center = SCNVector3(
                    (minVec.x + maxVec.x) / 2,
                    (minVec.y + maxVec.y) / 2,
                    (minVec.z + maxVec.z) / 2
                )
                let cameraNode = SCNNode()
                cameraNode.camera = SCNCamera()
                cameraNode.camera?.automaticallyAdjustsZRange = true
                cameraNode.position = SCNVector3(center.x, center.y, center.z + size * 2)
                cameraNode.look(at: center)
                scene.rootNode.addChildNode(cameraNode)
                scnView.pointOfView = cameraNode
            }

            DispatchQueue.main.async {
                onLoad?(true, nil)
                let infoParts = [
                    "preview=v4",
                    loadedScene.loaderInfo,
                    "material=\(hasMaterial), texture=\(hasTexture)",
                    "nodes=\(nodeCount), size=\(String(format: "%.2f", size))",
                    loadedScene.textureInfo
                ].compactMap { $0 }
                onInfo?(infoParts.joined(separator: "\n"))
            }
            print("[ModelPreview] 加载成功: nodes=\(nodeCount), size=\(String(format: "%.2f", size)), material=\(hasMaterial), texture=\(hasTexture)")
        } catch {
            DispatchQueue.main.async {
                onLoad?(false, error.localizedDescription)
            }
        }

        return scnView
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    private func loadScene() throws -> LoadedScene {
        if fileURL.pathExtension.lowercased() == "obj" {
            return loadModelIOOBJScene()
        }

        let scene = try SCNScene(url: fileURL, options: [
            .checkConsistency: true,
            .assetDirectoryURLs: [fileURL.deletingLastPathComponent()]
        ])
        return LoadedScene(
            scene: scene,
            loaderInfo: "loader=scenekit",
            textureInfo: inspectScene(scene)
        )
    }

    private func loadModelIOOBJScene() -> LoadedScene {
        let directoryURL = fileURL.deletingLastPathComponent()
        let asset = MDLAsset(url: fileURL)
        asset.resolver = MDLPathAssetResolver(path: directoryURL.path)
        asset.loadTextures()

        let scene = SCNScene(mdlAsset: asset)
        let conversionInfo = convertModelIOTexturesForSceneKit(in: scene)
        let textureInfo = [
            "modelio objects=\(asset.count), canImportOBJ=\(MDLAsset.canImportFileExtension("obj"))",
            conversionInfo,
            inspectScene(scene)
        ].joined(separator: "\n")

        return LoadedScene(
            scene: scene,
            loaderInfo: "loader=modelio_obj",
            textureInfo: textureInfo
        )
    }

    private func convertModelIOTexturesForSceneKit(in scene: SCNScene) -> String {
        var materialCount = 0
        var convertedCount = 0
        var failedCount = 0
        var textureDescriptions = Set<String>()

        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            for material in geometry.materials {
                materialCount += 1
                if let cgImage = makeCGImage(from: material.diffuse.contents, descriptions: &textureDescriptions) {
                    material.diffuse.contents = cgImage
                    material.emission.contents = cgImage
                    material.lightingModel = .constant
                    convertedCount += 1
                } else if material.diffuse.contents != nil {
                    failedCount += 1
                }

                material.isDoubleSided = true
                material.diffuse.wrapS = .clamp
                material.diffuse.wrapT = .clamp
                material.diffuse.mipFilter = .none
                material.diffuse.minificationFilter = .linear
                material.diffuse.magnificationFilter = .linear
            }
        }

        return [
            "convert mdlTex=\(convertedCount)/\(materialCount), failed=\(failedCount)",
            "tex \(textureDescriptions.sorted().joined(separator: "|"))"
        ].joined(separator: "\n")
    }

    private func makeCGImage(from contents: Any?, descriptions: inout Set<String>) -> CGImage? {
        guard let contents else { return nil }
        if let image = contents as? UIImage, let cgImage = image.cgImage {
            descriptions.insert("ui:\(Int(image.size.width))x\(Int(image.size.height))")
            return cgImage
        }
        if let texture = contents as? MDLTexture {
            let dimensions = texture.dimensions
            descriptions.insert("mdl:\(dimensions.x)x\(dimensions.y)")
            return texture.imageFromTexture()?.takeUnretainedValue()
        }
        return nil
    }

    private func inspectScene(_ scene: SCNScene) -> String {
        var geometryCount = 0
        var materialCount = 0
        var elementCount = 0
        var uvSourceCount = 0
        var uvVectorCount = 0
        var vertexSourceCount = 0
        var vertexVectorCount = 0
        var normalSourceCount = 0
        var normalVectorCount = 0
        var diffuseTypes = Set<String>()
        var emissionTypes = Set<String>()
        var lightingModels = Set<String>()

        scene.rootNode.enumerateChildNodes { node, _ in
            guard let geometry = node.geometry else { return }
            geometryCount += 1
            elementCount += geometry.elementCount

            let vertexSources = geometry.sources(for: .vertex)
            vertexSourceCount += vertexSources.count
            vertexVectorCount += vertexSources.reduce(0) { $0 + $1.vectorCount }

            let normalSources = geometry.sources(for: .normal)
            normalSourceCount += normalSources.count
            normalVectorCount += normalSources.reduce(0) { $0 + $1.vectorCount }

            let uvSources = geometry.sources(for: .texcoord)
            uvSourceCount += uvSources.count
            uvVectorCount += uvSources.reduce(0) { $0 + $1.vectorCount }

            for material in geometry.materials {
                material.isDoubleSided = true
                material.diffuse.wrapS = .clamp
                material.diffuse.wrapT = .clamp
                material.diffuse.mipFilter = .none
                material.diffuse.minificationFilter = .linear
                material.diffuse.magnificationFilter = .linear
                diffuseTypes.insert(describeMaterialContents(material.diffuse.contents))
                emissionTypes.insert(describeMaterialContents(material.emission.contents))
                lightingModels.insert(material.lightingModel.rawValue)
                materialCount += 1
            }
        }

        return [
            "geo=\(geometryCount)g/\(elementCount)e/\(materialCount)m",
            "src v=\(vertexSourceCount):\(vertexVectorCount), uv=\(uvSourceCount):\(uvVectorCount), n=\(normalSourceCount):\(normalVectorCount)",
            "mat diffuse=\(diffuseTypes.sorted().joined(separator: "|"))",
            "mat emission=\(emissionTypes.sorted().joined(separator: "|"))",
            "light=\(lightingModels.sorted().joined(separator: "|"))"
        ].joined(separator: "\n")
    }

    private func describeMaterialContents(_ contents: Any?) -> String {
        guard let contents else { return "nil" }
        if let url = contents as? URL {
            return "url:\(url.lastPathComponent)"
        }
        if let string = contents as? String {
            return "str:\(string)"
        }
        if let image = contents as? UIImage {
            return "uiimage:\(Int(image.size.width))x\(Int(image.size.height))"
        }
        let typeName = String(describing: type(of: contents))
        if typeName.contains("CGImage") || typeName == "__NSCFType" {
            return "cgimage"
        }
        if contents is UIColor {
            return "color"
        }
        return String(describing: type(of: contents))
    }
}
