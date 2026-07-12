"""从 other 团队的 GLB 模型中提取纹理和 mesh 信息，用于对比分析"""
import trimesh
import numpy as np
from PIL import Image
import os
import json

OUTPUT_DIR = "debug/other_texture_extract"
GLB_PATH = "data/other/2026_3_19.glb"

os.makedirs(OUTPUT_DIR, exist_ok=True)

print(f"加载 GLB: {GLB_PATH}")
scene = trimesh.load(GLB_PATH)

print(f"类型: {type(scene)}")

# 收集所有 mesh 的信息
info = {}

if isinstance(scene, trimesh.Scene):
    print(f"场景包含 {len(scene.geometry)} 个几何体")
    for name, geom in scene.geometry.items():
        print(f"\n--- {name} ---")
        print(f"  类型: {type(geom)}")
        if hasattr(geom, 'vertices'):
            print(f"  顶点数: {len(geom.vertices)}")
        if hasattr(geom, 'faces'):
            print(f"  面数: {len(geom.faces)}")
        
        mesh_info = {
            "name": name,
            "vertex_count": len(geom.vertices) if hasattr(geom, 'vertices') else 0,
            "face_count": len(geom.faces) if hasattr(geom, 'faces') else 0,
        }
        
        # 提取 UV
        if hasattr(geom, 'visual') and hasattr(geom.visual, 'uv') and geom.visual.uv is not None:
            uv = geom.visual.uv
            print(f"  UV 坐标: shape={uv.shape}, range=[{uv.min():.4f}, {uv.max():.4f}]")
            mesh_info["uv_shape"] = list(uv.shape)
            mesh_info["uv_range"] = [float(uv.min()), float(uv.max())]
            
            # 保存 UV
            uv_path = os.path.join(OUTPUT_DIR, f"{name}_uv.npy")
            np.save(uv_path, uv)
            print(f"  UV 已保存: {uv_path}")
        
        # 提取纹理
        if hasattr(geom, 'visual'):
            visual = geom.visual
            print(f"  Visual 类型: {type(visual)}")
            
            if hasattr(visual, 'material'):
                mat = visual.material
                print(f"  Material 类型: {type(mat)}")
                
                # PBR material
                if hasattr(mat, 'baseColorTexture') and mat.baseColorTexture is not None:
                    tex = mat.baseColorTexture
                    if isinstance(tex, Image.Image):
                        tex_path = os.path.join(OUTPUT_DIR, f"{name}_baseColor.png")
                        tex.save(tex_path)
                        print(f"  baseColorTexture: {tex.size} -> {tex_path}")
                        mesh_info["texture_size"] = list(tex.size)
                
                if hasattr(mat, 'image') and mat.image is not None:
                    tex = mat.image
                    if isinstance(tex, Image.Image):
                        tex_path = os.path.join(OUTPUT_DIR, f"{name}_texture.png")
                        tex.save(tex_path)
                        print(f"  texture image: {tex.size} -> {tex_path}")
                        mesh_info["texture_size"] = list(tex.size)
                
                # 尝试从 SimpleMaterial 获取
                if hasattr(mat, 'main_color'):
                    print(f"  main_color: {mat.main_color}")
                    mesh_info["main_color"] = mat.main_color.tolist() if hasattr(mat.main_color, 'tolist') else str(mat.main_color)
            
            # TextureVisuals 直接有 image
            if hasattr(visual, 'image') and visual.image is not None:
                tex = visual.image
                if isinstance(tex, Image.Image):
                    tex_path = os.path.join(OUTPUT_DIR, f"{name}_visual_image.png")
                    tex.save(tex_path)
                    print(f"  visual.image: {tex.size} -> {tex_path}")
                    mesh_info["texture_size"] = list(tex.size)
        
        info[name] = mesh_info

elif isinstance(scene, trimesh.Trimesh):
    print(f"单个 mesh")
    print(f"  顶点数: {len(scene.vertices)}")
    print(f"  面数: {len(scene.faces)}")
    
    mesh_info = {
        "vertex_count": len(scene.vertices),
        "face_count": len(scene.faces),
    }
    
    if hasattr(scene, 'visual') and hasattr(scene.visual, 'uv') and scene.visual.uv is not None:
        uv = scene.visual.uv
        print(f"  UV: shape={uv.shape}, range=[{uv.min():.4f}, {uv.max():.4f}]")
        np.save(os.path.join(OUTPUT_DIR, "mesh_uv.npy"), uv)
        mesh_info["uv_shape"] = list(uv.shape)
    
    if hasattr(scene.visual, 'material'):
        mat = scene.visual.material
        if hasattr(mat, 'image') and mat.image is not None:
            mat.image.save(os.path.join(OUTPUT_DIR, "mesh_texture.png"))
            print(f"  纹理: {mat.image.size}")
            mesh_info["texture_size"] = list(mat.image.size)
        if hasattr(mat, 'baseColorTexture') and mat.baseColorTexture is not None:
            tex = mat.baseColorTexture
            if isinstance(tex, Image.Image):
                tex.save(os.path.join(OUTPUT_DIR, "mesh_baseColor.png"))
                print(f"  baseColorTexture: {tex.size}")
                mesh_info["texture_size"] = list(tex.size)

    info["mesh"] = mesh_info

# 保存汇总信息
with open(os.path.join(OUTPUT_DIR, "info.json"), "w") as f:
    json.dump(info, f, indent=2, default=str)

print(f"\n提取完成，输出目录: {OUTPUT_DIR}")
