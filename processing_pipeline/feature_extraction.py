"""Feature extraction: ORB + BoW vocabulary building and Hamming word assignment."""

from __future__ import annotations

from typing import List

import numpy as np
import open3d as o3d

from .models import (
    FeatureDatabase,
    KeyframeData,
)

# Module-level popcount lookup table (256 entries)
_POPCOUNT_TABLE = np.array([bin(i).count("1") for i in range(256)], dtype=np.int32)


def _hamming_word_assignment(
    descriptors: np.ndarray,
    vocabulary_medoids: np.ndarray,
    batch_size: int = 2048,
) -> np.ndarray:
    """Assign visual words to descriptors using Hamming distance.

    Vectorized implementation using broadcast XOR + popcount lookup table.
    (N, 1, D) XOR (1, K, D) → (N, K, D) → popcount lookup → sum → argmin

    Args:
        descriptors: (N, D) uint8 array of ORB descriptors.
        vocabulary_medoids: (K, D) uint8 array of vocabulary medoid descriptors.

    Returns:
        (N,) int array of word indices (0..K-1).
    """
    descriptors = np.asarray(descriptors, dtype=np.uint8)
    vocabulary_medoids = np.asarray(vocabulary_medoids, dtype=np.uint8)

    labels = np.empty(len(descriptors), dtype=np.intp)
    batch_size = max(1, int(batch_size))
    for start in range(0, len(descriptors), batch_size):
        end = min(start + batch_size, len(descriptors))
        # 广播 XOR: (B, 1, D) ^ (1, K, D) → (B, K, D)
        xor = np.bitwise_xor(
            descriptors[start:end, np.newaxis, :],
            vocabulary_medoids[np.newaxis, :, :],
        )
        # Popcount via lookup: (B, K, D) → (B, K)
        dists = _POPCOUNT_TABLE[xor].sum(axis=2)
        labels[start:end] = dists.argmin(axis=1).astype(np.intp)
    return labels


def _limit_keyframes_evenly(images: List[dict], max_keyframes: int | None):
    indexed_images = list(enumerate(images))
    if max_keyframes is None or len(indexed_images) <= max_keyframes:
        return indexed_images
    indices = np.linspace(0, len(indexed_images) - 1, max_keyframes)
    selected = sorted({int(round(i)) for i in indices})
    return [indexed_images[i] for i in selected[:max_keyframes]]


def build_feature_database(
    images: List[dict],
    mesh: o3d.geometry.TriangleMesh,
    intrinsics: dict | None = None,
    extract_akaze: bool = True,
    orb_nfeatures: int = 2000,
    bow_k: int = 1000,
    max_keyframes: int | None = None,
    use_minibatch_kmeans: bool = False,
    kmeans_batch_size: int = 4096,
    kmeans_n_init: int = 3,
    kmeans_max_iter: int = 300,
    assignment_batch_size: int = 2048,
) -> FeatureDatabase:
    """Extract ORB features from keyframes and build a visual feature database.

    For each keyframe image, extracts up to 2000 ORB features, back-projects
    2D keypoints to 3D via ray-mesh intersection, and stores valid
    correspondences. Keyframes with fewer than 20 valid features are skipped.

    When ``extract_akaze`` is True, additionally extracts AKAZE features for
    each keyframe using ``cv2.AKAZE_create()``, and obtains 3D points via the
    same ray-mesh intersection pipeline. AKAZE data is stored in the
    KeyframeData's ``akaze_*`` fields.

    After processing all keyframes, builds a visual Bag-of-Words (BoW)
    vocabulary using K-Means clustering (K=min(1000, n_descriptors)) on all
    collected descriptors, then computes TF-IDF weighted, L2-normalized BoW
    vectors for each keyframe (consistent with C++ computeBoW).

    Args:
        images: List of dicts each containing ``"path"`` (image file path)
            and ``"pose"`` (4x4 camera-to-world matrix).
        mesh: Triangle mesh used for ray-casting.
        intrinsics: Optional dict with ``fx``, ``fy``, ``cx``, ``cy`` keys.
            If *None*, intrinsics are estimated from image dimensions.
        extract_akaze: If True (default), additionally extract AKAZE features
            for each keyframe and store in akaze_* fields.

    Returns:
        Populated feature database with keyframes, vocabulary (uint8 medoids),
        and global_descriptors (TF-IDF weighted, L2-normalized BoW vectors,
        shape n_keyframes x K).
    """
    import logging

    import cv2
    import numpy as np

    logger = logging.getLogger(__name__)

    try:
        cv2.setNumThreads(1)
    except Exception:
        pass

    selected_images = _limit_keyframes_evenly(images, max_keyframes)

    # --- Step 1: Create ORB detector (+ AKAZE if requested) ---
    orb = cv2.ORB_create(nfeatures=orb_nfeatures)
    akaze = cv2.AKAZE_create() if extract_akaze else None

    # --- Step 2: Prepare ray-casting scene from mesh ---
    scene = o3d.t.geometry.RaycastingScene()
    mesh_legacy = mesh
    # Convert to tensor-based mesh for raycasting
    mesh_t = o3d.t.geometry.TriangleMesh.from_legacy(mesh_legacy)
    scene.add_triangles(mesh_t)

    keyframes: List[KeyframeData] = []

    for idx, img_info in selected_images:
        img_path = img_info["path"]
        pose = np.asarray(img_info["pose"], dtype=np.float64)

        # Load image in grayscale for ORB
        img_gray = cv2.imread(img_path, cv2.IMREAD_GRAYSCALE)
        if img_gray is None:
            logger.warning("Could not read image: %s, skipping.", img_path)
            continue

        h, w = img_gray.shape[:2]

        # --- Step 2a: Extract ORB features ---
        kps, descriptors = orb.detectAndCompute(img_gray, None)

        if descriptors is None or len(kps) == 0:
            logger.info(
                "No features detected in image %d (%s), skipping.", idx, img_path
            )
            continue

        # --- Step 2b: Estimate intrinsics from image size ---
        if intrinsics:
            fx = intrinsics["fx"]
            fy = intrinsics["fy"]
            cx = intrinsics["cx"]
            cy = intrinsics["cy"]
        else:
            fx = fy = max(w, h) * 0.8
            cx, cy = w / 2.0, h / 2.0

        # --- Step 2c: Backproject 2D keypoints to 3D via ray-mesh intersection ---
        valid_keypoints: List[tuple[float, float]] = []
        valid_descriptors: List[np.ndarray] = []
        valid_points_3d: List[tuple[float, float, float]] = []

        # Build rays for all keypoints at once for efficiency
        rays_list = []
        R = pose[:3, :3]
        t = pose[:3, 3]
        for kp in kps:
            px, py = kp.pt
            # Convert pixel to normalised camera coordinates
            x_cam = (px - cx) / fx
            y_cam = (py - cy) / fy
            # ARKit/OpenGL convention: camera looks along -Z
            dir_cam = np.array([x_cam, -y_cam, -1.0])
            dir_cam = dir_cam / np.linalg.norm(dir_cam)

            # Transform ray to world coordinates
            origin_world = t
            dir_world = R @ dir_cam

            rays_list.append([
                origin_world[0], origin_world[1], origin_world[2],
                dir_world[0], dir_world[1], dir_world[2],
            ])

        rays_tensor = o3d.core.Tensor(
            np.array(rays_list, dtype=np.float32), dtype=o3d.core.float32
        )
        result = scene.cast_rays(rays_tensor)
        t_hit = result["t_hit"].numpy()

        for j, kp in enumerate(kps):
            if np.isinf(t_hit[j]) or t_hit[j] <= 0:
                continue  # No intersection

            # Compute 3D hit point
            ray = np.array(rays_list[j], dtype=np.float64)
            origin = ray[:3]
            direction = ray[3:]
            hit_point = origin + t_hit[j] * direction

            valid_keypoints.append((kp.pt[0], kp.pt[1]))
            valid_descriptors.append(descriptors[j])
            valid_points_3d.append(
                (float(hit_point[0]), float(hit_point[1]), float(hit_point[2]))
            )

        # --- Step 2d: Skip keyframes with < 20 valid features ---
        if len(valid_keypoints) < 20:
            logger.info(
                "Image %d (%s): only %d valid features (< 20), skipping.",
                idx, img_path, len(valid_keypoints),
            )
            continue

        # Build KeyframeData
        desc_array = np.array(valid_descriptors, dtype=np.uint8)
        keyframe = KeyframeData(
            image_id=idx,
            keypoints=valid_keypoints,
            descriptors=desc_array,
            points_3d=valid_points_3d,
            camera_pose=pose,
        )
        keyframes.append(keyframe)
        logger.info(
            "Image %d (%s): %d valid features added to database.",
            idx, img_path, len(valid_keypoints),
        )

        # --- Step 2e: Extract AKAZE features (if requested) ---
        if akaze is not None:
            akaze_kps, akaze_descs = akaze.detectAndCompute(img_gray, None)

            if akaze_descs is not None and len(akaze_kps) > 0:
                # 构建 AKAZE 关键点的射线，复用相同的 intrinsics 和 pose
                akaze_rays_list = []
                for kp in akaze_kps:
                    px, py = kp.pt
                    x_cam = (px - cx) / fx
                    y_cam = (py - cy) / fy
                    dir_cam = np.array([x_cam, -y_cam, -1.0])
                    dir_cam = dir_cam / np.linalg.norm(dir_cam)
                    origin_world = t
                    dir_world = R @ dir_cam
                    akaze_rays_list.append([
                        origin_world[0], origin_world[1], origin_world[2],
                        dir_world[0], dir_world[1], dir_world[2],
                    ])

                akaze_rays_tensor = o3d.core.Tensor(
                    np.array(akaze_rays_list, dtype=np.float32),
                    dtype=o3d.core.float32,
                )
                akaze_result = scene.cast_rays(akaze_rays_tensor)
                akaze_t_hit = akaze_result["t_hit"].numpy()

                # 过滤有效交点的 AKAZE 特征
                akaze_valid_kps: List[tuple[float, float]] = []
                akaze_valid_descs: List[np.ndarray] = []
                akaze_valid_pts3d: List[tuple[float, float, float]] = []

                for j, kp in enumerate(akaze_kps):
                    if np.isinf(akaze_t_hit[j]) or akaze_t_hit[j] <= 0:
                        continue
                    ray = np.array(akaze_rays_list[j], dtype=np.float64)
                    origin = ray[:3]
                    direction = ray[3:]
                    hit_point = origin + akaze_t_hit[j] * direction

                    akaze_valid_kps.append((kp.pt[0], kp.pt[1]))
                    akaze_valid_descs.append(akaze_descs[j])
                    akaze_valid_pts3d.append(
                        (float(hit_point[0]), float(hit_point[1]), float(hit_point[2]))
                    )

                if akaze_valid_kps:
                    keyframe.akaze_keypoints = akaze_valid_kps
                    keyframe.akaze_descriptors = np.array(
                        akaze_valid_descs, dtype=np.uint8
                    )
                    keyframe.akaze_points_3d = akaze_valid_pts3d
                    logger.info(
                        "Image %d (%s): %d valid AKAZE features extracted.",
                        idx, img_path, len(akaze_valid_kps),
                    )
                else:
                    logger.info(
                        "Image %d (%s): no valid AKAZE features (all rays missed mesh).",
                        idx, img_path,
                    )
            else:
                logger.info(
                    "Image %d (%s): AKAZE detected no features.",
                    idx, img_path,
                )

    logger.info(
        "Feature database built: %d keyframes out of %d selected images (%d total).",
        len(keyframes), len(selected_images), len(images),
    )

    if len(keyframes) == 0 and len(images) > 0:
        raise ValueError(
            "Feature database is empty: no keyframes with sufficient features (>= 20) "
            "were found in any input image."
        )

    # --- Step 3: Build visual Bag-of-Words (BoW) vocabulary ---
    vocabulary = None
    global_descriptors = None

    # Collect all descriptors from all keyframes
    all_descriptors = []
    for kf in keyframes:
        all_descriptors.append(kf.descriptors)

    if all_descriptors:
        all_desc_uint8 = np.vstack(all_descriptors).astype(np.uint8)
        all_desc_float = all_desc_uint8.astype(np.float32)
        n_descriptors = all_desc_float.shape[0]

        if n_descriptors > 0:
            k = min(bow_k, n_descriptors)
            if use_minibatch_kmeans:
                from sklearn.cluster import MiniBatchKMeans

                logger.info(
                    "Building BoW vocabulary: MiniBatchKMeans K=%d on %d descriptors.",
                    k,
                    n_descriptors,
                )
                kmeans = MiniBatchKMeans(
                    n_clusters=k,
                    random_state=42,
                    n_init=kmeans_n_init,
                    max_iter=kmeans_max_iter,
                    batch_size=kmeans_batch_size,
                )
            else:
                from sklearn.cluster import KMeans

                logger.info(
                    "Building BoW vocabulary: KMeans K=%d on %d descriptors.",
                    k,
                    n_descriptors,
                )
                kmeans = KMeans(
                    n_clusters=k,
                    random_state=42,
                    n_init=kmeans_n_init,
                    max_iter=kmeans_max_iter,
                )
            kmeans.fit(all_desc_float)

            # --- Step 3b: Compute medoids (real uint8 descriptors) ---
            # For each cluster, find the real ORB descriptor closest
            # to the cluster center using Hamming distance.
            labels = kmeans.labels_
            centers_uint8 = kmeans.cluster_centers_.astype(np.uint8)
            medoids = np.zeros((k, all_desc_uint8.shape[1]), dtype=np.uint8)

            for c in range(k):
                mask = labels == c
                cluster_descs = all_desc_uint8[mask]
                if len(cluster_descs) == 0:
                    # Fallback: cast center to uint8 directly
                    medoids[c] = centers_uint8[c]
                    continue
                # Hamming distance from each descriptor to the center (vectorized)
                xor = np.bitwise_xor(cluster_descs, centers_uint8[c])  # (M, 32)
                hamming_dists = _POPCOUNT_TABLE[xor].sum(axis=1)       # (M,)
                medoids[c] = cluster_descs[np.argmin(hamming_dists)]

            # Store medoids as the vocabulary (uint8, matching C++ side)
            vocabulary = medoids

            # --- Step 4: Compute BoW vector for each keyframe ---
            # Use Hamming distance-based word assignment (consistent
            # with C++ computeBoW) with TF-IDF weighting + L2 normalization
            import math

            n_keyframes = len(keyframes)

            # 4a: Assign words for all keyframes and compute document frequencies
            all_word_labels = []
            doc_freq = np.zeros(k, dtype=np.float64)
            for i, kf in enumerate(keyframes):
                word_labels = _hamming_word_assignment(
                    kf.descriptors,
                    medoids,
                    batch_size=assignment_batch_size,
                )
                all_word_labels.append(word_labels)
                unique_words = set(word_labels.tolist())
                for w in unique_words:
                    doc_freq[w] += 1.0

            # 4b: Compute IDF weights: idf(w) = log(N / (1 + df(w)))
            idf_weights = np.array(
                [math.log(n_keyframes / (1.0 + doc_freq[w])) for w in range(k)],
                dtype=np.float64,
            )

            # 4c: Build TF-IDF weighted BoW vectors with L2 normalization
            bow_vectors = np.zeros((n_keyframes, k), dtype=np.float64)
            for i, kf in enumerate(keyframes):
                word_labels = all_word_labels[i]
                for label in word_labels:
                    bow_vectors[i, label] += idf_weights[label]
                # L2 normalization (consistent with C++ computeBoW)
                l2_norm = np.linalg.norm(bow_vectors[i])
                if l2_norm > 1e-9:
                    bow_vectors[i] /= l2_norm

            global_descriptors = bow_vectors
            logger.info(
                "BoW vectors computed for %d keyframes (K=%d).",
                n_keyframes, k,
            )

    return FeatureDatabase(
        keyframes=keyframes,
        vocabulary=vocabulary,
        global_descriptors=global_descriptors,
    )
