#!/usr/bin/env python3
"""验证 ScanData 目录数据完整性，对照 ScanDataModels.cs 的格式要求"""

import json
import os
import sys
import math

SCAN_DIR = "unity_project/Assets/StreamingAssets/ScanData"

def main():
    errors = []
    warnings = []

    # 1. 检查必要文件存在
    poses_path = os.path.join(SCAN_DIR, "poses.json")
    intrinsics_path = os.path.join(SCAN_DIR, "intrinsics.json")
    images_dir = os.path.join(SCAN_DIR, "images")

    for p in [poses_path, intrinsics_path, images_dir]:
        if not os.path.exists(p):
            errors.append(f"缺少: {p}")

    if errors:
        print("❌ 基础文件缺失:")
        for e in errors:
            print(f"  {e}")
        return 1

    # 2. 验证 intrinsics.json
    print("=== intrinsics.json ===")
    with open(intrinsics_path) as f:
        intr = json.load(f)

    required_keys = ["fx", "fy", "cx", "cy", "width", "height"]
    for k in required_keys:
        if k not in intr:
            errors.append(f"intrinsics 缺少字段: {k}")

    if not errors:
        print(f"  fx={intr['fx']}, fy={intr['fy']}")
        print(f"  cx={intr['cx']}, cy={intr['cy']}")
        print(f"  width={intr['width']}, height={intr['height']}")
        # 合理性检查
        if intr['fx'] <= 0 or intr['fy'] <= 0:
            errors.append(f"焦距必须为正: fx={intr['fx']}, fy={intr['fy']}")
        if intr['width'] <= 0 or intr['height'] <= 0:
            errors.append(f"分辨率必须为正: {intr['width']}x{intr['height']}")
        if not (0 < intr['cx'] < intr['width']):
            warnings.append(f"cx={intr['cx']} 不在 (0, {intr['width']}) 范围内")
        if not (0 < intr['cy'] < intr['height']):
            warnings.append(f"cy={intr['cy']} 不在 (0, {intr['height']}) 范围内")
    print(f"  ✅ intrinsics 格式正确")

    # 3. 验证 poses.json
    print("\n=== poses.json ===")
    with open(poses_path) as f:
        poses = json.load(f)

    if not isinstance(poses, dict) or "frames" not in poses:
        errors.append("poses.json 必须包含 'frames' 字段")
        print("❌ 格式错误")
        return 1

    frames = poses["frames"]
    print(f"  帧数: {len(frames)}")

    # 检查每一帧
    missing_images = []
    bad_transforms = []
    indices = []

    for i, frame in enumerate(frames):
        # 必要字段
        for k in ["index", "timestamp", "imageFile", "transform"]:
            if k not in frame:
                errors.append(f"帧 {i} 缺少字段: {k}")
                continue

        indices.append(frame["index"])

        # transform 必须是 16 个浮点数
        t = frame["transform"]
        if not isinstance(t, list) or len(t) != 16:
            bad_transforms.append(f"帧 {i}: transform 长度 {len(t) if isinstance(t, list) else 'N/A'}")
        else:
            # 检查是否都是数字
            if not all(isinstance(v, (int, float)) for v in t):
                bad_transforms.append(f"帧 {i}: transform 包含非数字值")
            # 检查是否有 NaN/Inf
            if any(math.isnan(v) or math.isinf(v) for v in t):
                bad_transforms.append(f"帧 {i}: transform 包含 NaN 或 Inf")
            # 检查最后一行 (列优先: t[3], t[7], t[11], t[15]) 应接近 (0,0,0,1)
            last_row = [t[3], t[7], t[11], t[15]]
            if not (abs(last_row[0]) < 0.01 and abs(last_row[1]) < 0.01 and
                    abs(last_row[2]) < 0.01 and abs(last_row[3] - 1.0) < 0.01):
                warnings.append(f"帧 {i}: 最后一行不是 [0,0,0,1]: {last_row}")

        # 检查图片文件存在
        img_path = os.path.join(SCAN_DIR, frame["imageFile"])
        if not os.path.exists(img_path):
            missing_images.append(frame["imageFile"])

    # 检查 index 连续性
    sorted_indices = sorted(indices)
    expected = list(range(len(frames)))
    if sorted_indices != expected:
        warnings.append(f"index 不连续: 范围 {sorted_indices[0]}-{sorted_indices[-1]}, 期望 0-{len(frames)-1}")

    if bad_transforms:
        for bt in bad_transforms:
            errors.append(bt)

    if missing_images:
        for mi in missing_images:
            errors.append(f"图片缺失: {mi}")

    # 检查 images 目录中的实际文件数
    actual_images = [f for f in os.listdir(images_dir) if f.endswith('.jpg')]
    print(f"  images/ 目录中的 jpg 文件数: {len(actual_images)}")
    print(f"  poses.json 引用的图片数: {len(frames)}")

    if len(actual_images) != len(frames):
        warnings.append(f"图片数量不匹配: 目录有 {len(actual_images)} 张, poses 引用 {len(frames)} 帧")

    print(f"  ✅ poses 格式正确")

    # 4. 输出结果
    print("\n=== 验证结果 ===")
    if errors:
        print(f"❌ 发现 {len(errors)} 个错误:")
        for e in errors:
            print(f"  ❌ {e}")
    else:
        print("✅ 无错误")

    if warnings:
        print(f"⚠️  {len(warnings)} 个警告:")
        for w in warnings:
            print(f"  ⚠️  {w}")
    else:
        print("✅ 无警告")

    # 5. 摘要
    print(f"\n=== 摘要 ===")
    print(f"  数据集: data3 (scan_20260324_142133)")
    print(f"  帧数: {len(frames)}")
    print(f"  分辨率: {intr['width']}x{intr['height']}")
    print(f"  焦距: fx={intr['fx']:.2f}, fy={intr['fy']:.2f}")
    print(f"  主点: cx={intr['cx']:.2f}, cy={intr['cy']:.2f}")

    return 1 if errors else 0

if __name__ == "__main__":
    sys.exit(main())
