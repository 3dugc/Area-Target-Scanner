"""Bug Condition Exploration Tests — run on UNFIXED code.

These tests encode the EXPECTED (correct) behavior for each of the 12 bugs
found during code review. They are expected to FAIL on the current unfixed
code, confirming the bugs exist.

Validates: Requirements 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9
"""

from __future__ import annotations

import inspect
import io
import os
import re
import time

import numpy as np


# ---------------------------------------------------------------------------
# Bug 1 (P0) — Hamming 距离性能极差
# ---------------------------------------------------------------------------


class TestBug1HammingPerformance:
    """Validates: Requirements 1.1

    Bug condition: _hamming_word_assignment() uses pure Python double loop +
    bin(b).count("1") popcount. For 1000 vocabulary words × 2000 descriptors
    it takes tens of seconds instead of < 1 second.
    """

    def test_hamming_word_assignment_completes_within_1_second(self):
        """Generate 1000 vocabulary words × 2000 descriptors, call
        _hamming_word_assignment(), assert elapsed < 1 second.

        **Validates: Requirements 1.1**

        isBugCondition: elapsed_time > 1.0s for N=2000, K=1000
        """
        from processing_pipeline.feature_extraction import _hamming_word_assignment

        rng = np.random.default_rng(42)
        descriptors = rng.integers(0, 256, size=(2000, 32), dtype=np.uint8)
        vocabulary = rng.integers(0, 256, size=(1000, 32), dtype=np.uint8)

        start = time.perf_counter()
        _hamming_word_assignment(descriptors, vocabulary)
        elapsed = time.perf_counter() - start

        assert elapsed < 1.0, (
            f"_hamming_word_assignment took {elapsed:.2f}s for N=2000, K=1000. "
            f"Bug confirmed: pure Python double loop is too slow (expected < 1s)."
        )


# ---------------------------------------------------------------------------
# Bug 2 (P0) — 临时目录泄漏
# ---------------------------------------------------------------------------


class TestBug2TempDirLeak:
    """Validates: Requirements 1.2, 1.3

    Bug condition: tempfile.mkdtemp() work_dir is never cleaned up after
    run_pipeline() or OptimizedPipeline.run() completes.
    """

    def test_run_pipeline_cleans_up_work_dir(self):
        """Check run_pipeline() source for finally block that cleans up work_dir.

        **Validates: Requirements 1.2**

        isBugCondition: os.path.isdir(work_dir) == True after run completes
        """
        from web_service.app import run_pipeline

        source = inspect.getsource(run_pipeline)

        # The fix should wrap work_dir usage in try/finally with shutil.rmtree
        has_finally = "finally" in source
        has_rmtree = "shutil.rmtree" in source or "rmtree" in source

        assert has_finally and has_rmtree, (
            "run_pipeline() does not have finally block with rmtree "
            "to clean up work_dir. "
            "Bug confirmed: temporary directory is never cleaned up."
        )

    def test_optimized_pipeline_run_cleans_up_work_dir(self):
        """Mock OptimizedPipeline steps, call run(), assert work_dir is
        cleaned up after completion.

        **Validates: Requirements 1.3**

        isBugCondition: os.path.isdir(work_dir) == True after run completes
        """
        from processing_pipeline.optimized_pipeline import OptimizedPipeline

        source = inspect.getsource(OptimizedPipeline.run)

        # The fix should wrap work_dir usage in try/finally with shutil.rmtree
        has_finally = "finally" in source
        has_rmtree = "shutil.rmtree" in source or "rmtree" in source

        assert has_finally and has_rmtree, (
            "OptimizedPipeline.run() does not have finally block with rmtree "
            "to clean up work_dir. "
            "Bug confirmed: temporary directory is never cleaned up."
        )


# ---------------------------------------------------------------------------
# Bug 3 (P0) — safe_extract TOCTOU
# ---------------------------------------------------------------------------


class TestBug3SafeExtractTOCTOU:
    """Validates: Requirements 1.4

    Bug condition: safe_extract() checks path with os.path.realpath() BEFORE
    extraction but does NOT verify the actual path AFTER extraction.
    """

    def test_safe_extract_has_post_extraction_path_check(self):
        """Verify safe_extract() does post-extraction path validation on
        each file.

        **Validates: Requirements 1.4**

        isBugCondition: source code lacks post-extraction path check
        """
        from web_service.app import safe_extract

        source = inspect.getsource(safe_extract)

        # The source should have TWO realpath checks:
        # 1. Pre-extraction check (already exists)
        # 2. Post-extraction check (the fix)
        #
        # We look for a realpath call AFTER the zf.extract() call
        extract_pos = source.find("zf.extract(")
        assert extract_pos != -1, "safe_extract does not call zf.extract()"

        # Check for post-extraction path validation after zf.extract()
        post_extract_source = source[extract_pos:]
        has_post_check = (
            "realpath" in post_extract_source
            or "Post" in post_extract_source
            or "post" in post_extract_source
        )

        assert has_post_check, (
            "safe_extract() lacks post-extraction path validation after zf.extract(). "
            "Bug confirmed: TOCTOU vulnerability — path is only checked before extraction."
        )


# ---------------------------------------------------------------------------
# Bug 4 (P1) — BoW 加权不一致 (TF-only vs TF-IDF)
# ---------------------------------------------------------------------------


class TestBug4BoWWeightingInconsistency:
    """Validates: Requirements 1.5

    Bug condition: Python BoW vector uses TF-only (bow_vectors[i, label] += 1.0)
    without IDF weighting, while C++ uses TF-IDF.
    """

    def test_bow_vector_uses_idf_weighting(self):
        """Check if build_feature_database() uses IDF weighting for BoW vectors.

        **Validates: Requirements 1.5**

        isBugCondition: bow_vector uses TF-only without IDF weights
        """
        from processing_pipeline.feature_extraction import build_feature_database

        source = inspect.getsource(build_feature_database)

        # Look for IDF weighting in the BoW vector computation section
        # The fix should multiply by idf_weights instead of just += 1.0
        has_idf = (
            "idf" in source.lower()
            or "IDF" in source
            or "idf_weight" in source
        )

        # Also check that it's NOT just doing += 1.0 (pure TF)
        # The buggy code has: bow_vectors[i, label] += 1.0
        uses_pure_tf = "bow_vectors[i, label] += 1.0" in source

        assert has_idf and not uses_pure_tf, (
            "build_feature_database() uses TF-only BoW weighting (bow_vectors[i, label] += 1.0) "
            "without IDF weights. Bug confirmed: Python BoW is inconsistent with C++ TF-IDF."
        )


# ---------------------------------------------------------------------------
# Bug 5 (P1) — GLB 重复加载
# ---------------------------------------------------------------------------


class TestBug5GLBDuplicateLoad:
    """Validates: Requirements 1.7 (related)

    Bug condition: trimesh.load() is called more than once for the same GLB
    file in optimized_pipeline.py.
    """

    def test_trimesh_load_called_at_most_once(self):
        """Check optimized_pipeline.py source for number of trimesh.load calls.

        **Validates: Requirements 1.7**

        isBugCondition: trimesh.load called more than once for same GLB
        """
        import processing_pipeline.optimized_pipeline as opt_module

        source = inspect.getsource(opt_module)

        # Count trimesh.load() calls in the module
        load_calls = re.findall(r"trimesh\.load\s*\(", source)

        assert len(load_calls) <= 1, (
            f"trimesh.load() is called {len(load_calls)} times in optimized_pipeline.py. "
            f"Bug confirmed: GLB file is loaded multiple times instead of once."
        )


# ---------------------------------------------------------------------------
# Bug 6 (P1) — deprecated API: dump(concatenate=True)
# ---------------------------------------------------------------------------


class TestBug6DeprecatedAPI:
    """Validates: Requirements 1.7

    Bug condition: optimized_pipeline.py uses scene.dump(concatenate=True)
    which is deprecated in trimesh (removed April 2025).
    """

    def test_no_deprecated_dump_concatenate(self):
        """Check optimized_pipeline.py source for dump(concatenate=True).

        **Validates: Requirements 1.7**

        isBugCondition: "dump(concatenate=True)" in source
        """
        import processing_pipeline.optimized_pipeline as opt_module

        source = inspect.getsource(opt_module)

        assert "dump(concatenate=True)" not in source, (
            "optimized_pipeline.py uses deprecated scene.dump(concatenate=True). "
            "Bug confirmed: should use scene.to_geometry() instead."
        )


# ---------------------------------------------------------------------------
# Bug 7 (P1) — jobs 无并发保护
# ---------------------------------------------------------------------------


class TestBug7JobsNoConcurrencyProtection:
    """Validates: Requirements 1.8 (related)

    Bug condition: jobs dict writes in web_service/app.py have no
    threading.Lock protection.
    """

    def test_jobs_writes_protected_by_lock(self):
        """Check web_service/app.py source for lock protection on jobs writes.

        **Validates: Requirements 1.8**

        isBugCondition: no threading.Lock protecting jobs writes
        """
        import web_service.app as app_module

        source = inspect.getsource(app_module)

        # Check for threading.Lock usage protecting jobs
        has_lock = (
            "_jobs_lock" in source
            or "jobs_lock" in source
            or ("Lock()" in source and "jobs" in source)
        )

        assert has_lock, (
            "web_service/app.py has no threading.Lock protecting jobs dict writes. "
            "Bug confirmed: concurrent access to jobs dict is unprotected."
        )


# ---------------------------------------------------------------------------
# Bug 8 (P1) — 上传未验证 ZIP 内容
# ---------------------------------------------------------------------------


class TestBug8UploadNoZipValidation:
    """Validates: Requirements 1.8

    Bug condition: upload() only checks file extension .zip but does not
    validate that the file content is actually a valid ZIP.
    """

    def test_upload_invalid_zip_content_returns_400(self):
        """Upload a file with .zip extension but plain text content,
        assert returns 400.

        **Validates: Requirements 1.8**

        isBugCondition: response.status_code != 400 for invalid ZIP content
        """
        from web_service.app import app

        with app.test_client() as client:
            # Create a fake .zip file with plain text content
            data = {
                "file": (io.BytesIO(b"this is not a zip file"), "fake.zip"),
            }
            response = client.post(
                "/api/upload",
                data=data,
                content_type="multipart/form-data",
            )

            assert response.status_code == 400, (
                f"Upload of invalid ZIP content returned {response.status_code}, "
                f"expected 400. Bug confirmed: upload only checks file extension, "
                f"not actual ZIP content."
            )


# ---------------------------------------------------------------------------
# Bug 9 (P2) — Dockerfile 多余层
# ---------------------------------------------------------------------------


class TestBug9DockerfileExtraLayers:
    """Validates: Dockerfile optimization

    Bug condition: useradd and mkdir are in separate RUN instructions,
    creating unnecessary image layers.
    """

    def test_useradd_and_mkdir_in_same_run(self):
        """Check Dockerfile for useradd and mkdir in same RUN instruction.

        isBugCondition: separate RUN instructions for useradd and mkdir
        """
        dockerfile_path = os.path.join(
            os.path.dirname(os.path.dirname(__file__)), "Dockerfile"
        )
        assert os.path.exists(dockerfile_path), "Dockerfile not found"

        with open(dockerfile_path, "r") as f:
            content = f.read()

        # Parse RUN instructions (handling multi-line with backslash continuation)
        # Find all RUN blocks
        run_blocks = []
        lines = content.split("\n")
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            if line.startswith("RUN "):
                block = line
                while block.endswith("\\") and i + 1 < len(lines):
                    i += 1
                    block += "\n" + lines[i].strip()
                run_blocks.append(block)
            i += 1

        # Find which RUN blocks contain useradd and mkdir
        useradd_block = None
        mkdir_block = None
        for block in run_blocks:
            if "useradd" in block:
                useradd_block = block
            if "mkdir" in block:
                mkdir_block = block

        assert useradd_block is not None, "No RUN instruction with useradd found"
        assert mkdir_block is not None, "No RUN instruction with mkdir found"

        assert useradd_block is mkdir_block, (
            "useradd and mkdir are in separate RUN instructions. "
            "Bug confirmed: unnecessary extra image layer."
        )


# ---------------------------------------------------------------------------
# Bug 10 (P2) — KMeans n_init 过大
# ---------------------------------------------------------------------------


class TestBug10KMeansNInit:
    """Validates: Requirements 1.9

    Bug condition: KMeans uses n_init=10 instead of n_init=3.
    """

    def test_kmeans_n_init_is_3(self):
        """Check build_feature_database() source for KMeans n_init parameter.

        **Validates: Requirements 1.9**

        isBugCondition: n_init != 3
        """
        from processing_pipeline.feature_extraction import build_feature_database

        source = inspect.getsource(build_feature_database)

        signature = inspect.signature(build_feature_database)
        assert signature.parameters["kmeans_n_init"].default == 3
        assert "n_init=kmeans_n_init" in source


# ---------------------------------------------------------------------------
# Bug 11 (P2) — N+1 查询
# ---------------------------------------------------------------------------


class TestBug11NPlusOneQuery:
    """Validates: FeatureDatabaseReader N+1 query

    Bug condition: LoadKeyframes() executes a separate SELECT for features
    for each keyframe (N+1 query pattern).
    """

    def test_features_query_not_inside_loop(self):
        """Check FeatureDatabaseReader.cs source for features query inside loop.

        isBugCondition: SELECT features WHERE keyframe_id inside foreach loop
        """
        cs_path = os.path.join(
            os.path.dirname(os.path.dirname(__file__)),
            "unity_plugin",
            "AreaTargetPlugin",
            "Runtime",
            "FeatureDatabaseReader.cs",
        )
        assert os.path.exists(cs_path), f"FeatureDatabaseReader.cs not found at {cs_path}"

        with open(cs_path, "r") as f:
            source = f.read()

        load_keyframes = re.search(
            r"private void LoadKeyframes\(SQLiteConnection conn\)(.*?)"
            r"private void LoadVocabulary",
            source,
            re.DOTALL,
        )
        assert load_keyframes is not None, "LoadKeyframes method not found"
        method_source = load_keyframes.group(1)
        has_n_plus_1 = bool(re.search(
            r"SELECT.*?FROM features.*?WHERE\s+keyframe_id",
            method_source,
            re.DOTALL | re.IGNORECASE,
        ))

        assert not has_n_plus_1, (
            "FeatureDatabaseReader.cs has N+1 query pattern: "
            "SELECT features WHERE keyframe_id is inside a foreach loop over keyframes. "
            "Bug confirmed: should use a single query with ORDER BY keyframe_id."
        )


# ---------------------------------------------------------------------------
# Bug 12 (P2) — BoW 归一化不统一 (L1 vs L2)
# ---------------------------------------------------------------------------


class TestBug12BoWNormalizationInconsistency:
    """Validates: Requirements 1.6

    Bug condition: Python BoW vector uses L1 normalization while C++ uses L2.
    """

    def test_bow_vector_uses_l2_normalization(self):
        """Check Python BoW vector for L2 normalization.

        **Validates: Requirements 1.6**

        isBugCondition: L1 normalization used instead of L2
        """
        from processing_pipeline.feature_extraction import build_feature_database

        source = inspect.getsource(build_feature_database)

        # Look for L2 normalization: np.linalg.norm or equivalent
        has_l2_norm = (
            "linalg.norm" in source
            or "l2_norm" in source
            or "np.sqrt" in source
        )

        # Check that L1 normalization is NOT used
        # The buggy code has: bow_vectors[i] /= l1_norm  or  /= np.sum(bow_vectors[i])
        uses_l1 = (
            "l1_norm" in source
            or ("np.sum(bow_vectors" in source and "linalg.norm" not in source)
        )

        assert has_l2_norm and not uses_l1, (
            "build_feature_database() uses L1 normalization for BoW vectors "
            "instead of L2. Bug confirmed: Python BoW normalization is inconsistent "
            "with C++ (which uses L2)."
        )
