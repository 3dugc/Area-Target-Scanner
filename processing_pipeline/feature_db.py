"""SQLite persistence for the visual feature database.

Provides :func:`save_feature_database` and :func:`load_feature_database` to
round-trip a :class:`~processing_pipeline.models.FeatureDatabase` through a
SQLite file with three tables: ``keyframes``, ``features``, and ``vocabulary``.
"""

from __future__ import annotations

import math
import sqlite3
from typing import List

import numpy as np

from processing_pipeline.models import FeatureDatabase, KeyframeData

# ---------------------------------------------------------------------------
# Schema
# ---------------------------------------------------------------------------

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS keyframes (
    id INTEGER PRIMARY KEY,
    pose BLOB NOT NULL,
    global_descriptor BLOB
);

CREATE TABLE IF NOT EXISTS features (
    id INTEGER PRIMARY KEY,
    keyframe_id INTEGER NOT NULL REFERENCES keyframes(id),
    x REAL NOT NULL,
    y REAL NOT NULL,
    x3d REAL NOT NULL,
    y3d REAL NOT NULL,
    z3d REAL NOT NULL,
    descriptor BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS vocabulary (
    word_id INTEGER PRIMARY KEY,
    descriptor BLOB NOT NULL,
    idf_weight REAL NOT NULL
);
"""

_AKAZE_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS akaze_features (
    id INTEGER PRIMARY KEY,
    keyframe_id INTEGER NOT NULL REFERENCES keyframes(id),
    x REAL NOT NULL,
    y REAL NOT NULL,
    x3d REAL NOT NULL,
    y3d REAL NOT NULL,
    z3d REAL NOT NULL,
    descriptor BLOB NOT NULL
);
"""


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _compute_idf_weights(
    keyframes: List[KeyframeData],
    n_words: int,
    vocabulary_centers: np.ndarray,
) -> np.ndarray:
    """Compute IDF weight for each visual word.

    IDF = log(N / (1 + df)) where *N* is the total number of keyframes and
    *df* is the number of keyframes that contain at least one descriptor
    assigned to that word.

    Word assignment uses Hamming distance (popcount of XOR) to match the
    C++ ``computeBoW`` implementation.

    Args:
        keyframes: Keyframe list from the feature database.
        n_words: Number of visual words (K).
        vocabulary_centers: (K, D) uint8 vocabulary medoid descriptors.

    Returns:
        (K,) array of IDF weights.
    """
    from processing_pipeline.feature_extraction import _hamming_word_assignment

    n_keyframes = len(keyframes)
    doc_freq = np.zeros(n_words, dtype=np.float64)

    vocabulary_uint8 = np.asarray(vocabulary_centers, dtype=np.uint8)

    for kf in keyframes:
        if kf.descriptors is None or len(kf.descriptors) == 0:
            continue
        labels = _hamming_word_assignment(kf.descriptors, vocabulary_uint8)
        unique_words = set(labels.tolist())
        for w in unique_words:
            doc_freq[w] += 1.0

    idf = np.array(
        [math.log(n_keyframes / (1.0 + doc_freq[w])) for w in range(n_words)],
        dtype=np.float64,
    )
    return idf


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def save_feature_database(db: FeatureDatabase, db_path: str) -> None:
    """Persist a :class:`FeatureDatabase` to a SQLite file.

    Creates (or overwrites) the database at *db_path* with three tables:
    ``keyframes``, ``features``, and ``vocabulary``.

    Args:
        db: The in-memory feature database to save.
        db_path: Filesystem path for the SQLite database file.
    """
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()
        cur.executescript(_SCHEMA_SQL)

        # -- keyframes & features ------------------------------------------
        for idx, kf in enumerate(db.keyframes):
            pose_blob = kf.camera_pose.astype(np.float64).tobytes()

            # Global descriptor for this keyframe (row from global_descriptors)
            gd_blob: bytes | None = None
            if db.global_descriptors is not None and idx < len(db.global_descriptors):
                gd_blob = db.global_descriptors[idx].astype(np.float64).tobytes()

            cur.execute(
                "INSERT INTO keyframes (id, pose, global_descriptor) VALUES (?, ?, ?)",
                (kf.image_id, pose_blob, gd_blob),
            )

            for j in range(len(kf.keypoints)):
                x, y = kf.keypoints[j]
                x3d, y3d, z3d = kf.points_3d[j]
                desc_blob = kf.descriptors[j].astype(np.uint8).tobytes()
                cur.execute(
                    "INSERT INTO features "
                    "(keyframe_id, x, y, x3d, y3d, z3d, descriptor) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?)",
                    (kf.image_id, float(x), float(y), float(x3d), float(y3d), float(z3d), desc_blob),
                )

        # -- akaze_features（若有 AKAZE 数据）-------------------------------
        has_akaze = any(
            kf.akaze_descriptors is not None for kf in db.keyframes
        )
        if has_akaze:
            cur.executescript(_AKAZE_SCHEMA_SQL)
            for kf in db.keyframes:
                if kf.akaze_descriptors is None:
                    continue
                for j in range(len(kf.akaze_keypoints)):
                    x, y = kf.akaze_keypoints[j]
                    x3d, y3d, z3d = kf.akaze_points_3d[j]
                    desc_blob = kf.akaze_descriptors[j].astype(np.uint8).tobytes()
                    cur.execute(
                        "INSERT INTO akaze_features "
                        "(keyframe_id, x, y, x3d, y3d, z3d, descriptor) "
                        "VALUES (?, ?, ?, ?, ?, ?, ?)",
                        (kf.image_id, float(x), float(y), float(x3d), float(y3d), float(z3d), desc_blob),
                    )

        # -- vocabulary ----------------------------------------------------
        if db.vocabulary is not None:
            medoids = np.asarray(db.vocabulary, dtype=np.uint8)
            idf_weights = _compute_idf_weights(db.keyframes, len(medoids), medoids)

            for word_id in range(len(medoids)):
                desc_blob = medoids[word_id].tobytes()
                cur.execute(
                    "INSERT INTO vocabulary (word_id, descriptor, idf_weight) "
                    "VALUES (?, ?, ?)",
                    (word_id, desc_blob, float(idf_weights[word_id])),
                )

        conn.commit()
    finally:
        conn.close()


def load_feature_database(db_path: str) -> FeatureDatabase:
    """Load a :class:`FeatureDatabase` from a SQLite file.

    Reads the ``keyframes``, ``features``, and ``vocabulary`` tables and
    reconstructs the in-memory data structures.  The vocabulary is returned
    as a uint8 medoid array (not a KMeans object).

    Args:
        db_path: Filesystem path to the SQLite database.

    Returns:
        Reconstructed :class:`FeatureDatabase`.
    """
    conn = sqlite3.connect(db_path)
    try:
        cur = conn.cursor()

        # -- Load keyframes ------------------------------------------------
        cur.execute("SELECT id, pose, global_descriptor FROM keyframes ORDER BY id")
        kf_rows = cur.fetchall()

        keyframes: List[KeyframeData] = []
        gd_list: list[np.ndarray | None] = []

        for kf_id, pose_blob, gd_blob in kf_rows:
            pose = np.frombuffer(pose_blob, dtype=np.float64).reshape(4, 4).copy()

            gd: np.ndarray | None = None
            if gd_blob is not None:
                gd = np.frombuffer(gd_blob, dtype=np.float64).copy()
            gd_list.append(gd)

            # Load features for this keyframe
            cur.execute(
                "SELECT x, y, x3d, y3d, z3d, descriptor FROM features "
                "WHERE keyframe_id = ? ORDER BY id",
                (kf_id,),
            )
            feat_rows = cur.fetchall()

            kps: List[tuple[float, float]] = []
            pts3d: List[tuple[float, float, float]] = []
            descs: list[np.ndarray] = []

            for x, y, x3d, y3d, z3d, desc_blob in feat_rows:
                kps.append((float(x), float(y)))
                pts3d.append((float(x3d), float(y3d), float(z3d)))
                descs.append(np.frombuffer(desc_blob, dtype=np.uint8).copy())

            desc_array = np.array(descs, dtype=np.uint8) if descs else np.empty((0, 32), dtype=np.uint8)

            keyframes.append(
                KeyframeData(
                    image_id=kf_id,
                    keypoints=kps,
                    descriptors=desc_array,
                    points_3d=pts3d,
                    camera_pose=pose,
                )
            )

        # Build global_descriptors matrix
        global_descriptors: np.ndarray | None = None
        if gd_list and gd_list[0] is not None:
            global_descriptors = np.array(gd_list, dtype=np.float64)

        # -- 加载 AKAZE 特征（兼容回退：表不存在则跳过）-------------------
        cur.execute(
            "SELECT name FROM sqlite_master WHERE type='table' AND name='akaze_features'"
        )
        has_akaze_table = cur.fetchone() is not None

        if has_akaze_table:
            for kf in keyframes:
                cur.execute(
                    "SELECT x, y, x3d, y3d, z3d, descriptor FROM akaze_features "
                    "WHERE keyframe_id = ? ORDER BY id",
                    (kf.image_id,),
                )
                akaze_rows = cur.fetchall()
                if akaze_rows:
                    akaze_kps: List[tuple[float, float]] = []
                    akaze_pts3d: List[tuple[float, float, float]] = []
                    akaze_descs: list[np.ndarray] = []
                    for x, y, x3d, y3d, z3d, desc_blob in akaze_rows:
                        akaze_kps.append((float(x), float(y)))
                        akaze_pts3d.append((float(x3d), float(y3d), float(z3d)))
                        akaze_descs.append(np.frombuffer(desc_blob, dtype=np.uint8).copy())
                    kf.akaze_keypoints = akaze_kps
                    kf.akaze_points_3d = akaze_pts3d
                    kf.akaze_descriptors = np.array(akaze_descs, dtype=np.uint8)

        # -- Load vocabulary -----------------------------------------------
        cur.execute("SELECT word_id, descriptor, idf_weight FROM vocabulary ORDER BY word_id")
        vocab_rows = cur.fetchall()

        vocabulary = None
        if vocab_rows:
            medoids = []
            for word_id, desc_blob, idf_weight in vocab_rows:
                medoids.append(np.frombuffer(desc_blob, dtype=np.uint8).copy())
            vocabulary = np.array(medoids, dtype=np.uint8)

        return FeatureDatabase(
            keyframes=keyframes,
            global_descriptors=global_descriptors,
            vocabulary=vocabulary,
        )
    finally:
        conn.close()
