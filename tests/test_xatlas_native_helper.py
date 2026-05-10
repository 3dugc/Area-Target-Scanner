"""Tests for native xatlas helper orchestration."""

import os
import textwrap

import numpy as np
import pytest


def _make_fake_helper(path, exit_code=0, write_output=True):
    output_block = ""
    if write_output:
        output_block = textwrap.dedent(
            """
            with open(sys.argv[2], "wb") as f:
                f.write(b"XATLASOU")
                f.write(struct.pack("<6I", 1, 3, 3, 2048, 2048, 1))
                f.write(np.array([0, 1, 2], dtype="<u4").tobytes())
                f.write(np.array([0, 1, 2], dtype="<u4").tobytes())
                f.write(np.array([[0.0, 0.0], [1.0, 0.0], [0.0, 1.0]], dtype="<f4").tobytes())
            """
        )
    script = textwrap.dedent(
        f"""\
        #!/usr/bin/env python3
        import json
        import struct
        import sys
        import numpy as np

        print(json.dumps({{"type": "progress", "category": "AddMesh", "progress": 100}}), flush=True)
        print(json.dumps({{"type": "progress", "category": "ComputeCharts", "progress": 50}}), flush=True)
        print(json.dumps({{"type": "progress", "category": "PackCharts", "progress": 100}}), flush=True)
        {textwrap.indent(output_block, "        ")}
        if {write_output!r}:
            print(json.dumps({{"type": "done", "chart_count": 1, "width": 2048, "height": 2048}}), flush=True)
        print("helper warning", file=sys.stderr)
        sys.exit({exit_code})
        """
    )
    path.write_text(script)
    os.chmod(path, 0o755)


def test_native_helper_progress_and_result(tmp_path):
    import processing_pipeline.uv_unwrap as uv_module

    helper = tmp_path / "fake_xatlas_helper.py"
    _make_fake_helper(helper)

    events = []
    vertices = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0]], dtype=np.float32)
    normals = np.zeros((3, 3), dtype=np.float32)
    faces = np.array([[0, 1, 2]], dtype=np.uint32)

    new_verts, new_normals, new_uvs, new_faces, vmapping, meta = uv_module.unwrap_with_xatlas(
        vertices,
        normals,
        faces,
        atlas_size=2048,
        profile="fast",
        on_progress=lambda step, progress=None: events.append((step, progress)),
        helper_path=str(helper),
        use_native=True,
    )

    assert meta["native_xatlas"] is True
    assert meta["chart_count"] == 1
    np.testing.assert_array_equal(vmapping, np.array([0, 1, 2], dtype=np.uint32))
    np.testing.assert_array_equal(new_faces, faces)
    assert new_verts.shape == (3, 3)
    assert new_normals.shape == (3, 3)
    assert new_uvs.shape == (3, 2)
    assert any("ComputeCharts" in step for step, _ in events)
    assert any(progress == 12 for _, progress in events)


def test_native_helper_failure_is_reported(tmp_path):
    import processing_pipeline.uv_unwrap as uv_module

    helper = tmp_path / "broken_xatlas_helper.py"
    _make_fake_helper(helper, exit_code=7, write_output=False)

    vertices = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0]], dtype=np.float32)
    normals = np.zeros((3, 3), dtype=np.float32)
    faces = np.array([[0, 1, 2]], dtype=np.uint32)

    with pytest.raises(RuntimeError, match="exit code 7"):
        uv_module.unwrap_with_xatlas(
            vertices,
            normals,
            faces,
            atlas_size=2048,
            profile="fast",
            helper_path=str(helper),
            use_native=True,
        )


def test_python_xatlas_fallback_when_native_disabled(monkeypatch):
    import processing_pipeline.uv_unwrap as uv_module

    vertices = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0]], dtype=np.float32)
    normals = np.zeros((3, 3), dtype=np.float32)
    faces = np.array([[0, 1, 2]], dtype=np.uint32)
    expected = ("verts", "normals", "uvs", "faces", "mapping", {"native_xatlas": False})

    def fake_python(*args, **kwargs):
        return expected

    monkeypatch.setattr(uv_module, "_unwrap_with_python_xatlas", fake_python)

    assert uv_module.unwrap_with_xatlas(
        vertices,
        normals,
        faces,
        profile="fast",
        use_native=False,
    ) == expected


def test_native_output_corruption_reports_clear_error(tmp_path):
    import processing_pipeline.uv_unwrap as uv_module

    output = tmp_path / "bad.bin"
    output.write_bytes(b"not-xatlas")
    vertices = np.zeros((3, 3), dtype=np.float32)
    normals = np.zeros((3, 3), dtype=np.float32)

    with pytest.raises(RuntimeError, match="invalid magic"):
        uv_module._read_xatlas_helper_output(str(output), vertices, normals)


def test_real_native_helper_one_triangle_when_available():
    import processing_pipeline.uv_unwrap as uv_module

    helper_path = os.environ.get("UV_XATLAS_HELPER_PATH", "/app/bin/xatlas_helper")
    if not os.path.isfile(helper_path):
        pytest.skip("native xatlas helper is not built in this environment")

    events = []
    vertices = np.array([[0, 0, 0], [1, 0, 0], [0, 1, 0]], dtype=np.float32)
    normals = np.array([[0, 0, 1], [0, 0, 1], [0, 0, 1]], dtype=np.float32)
    faces = np.array([[0, 1, 2]], dtype=np.uint32)

    new_verts, new_normals, new_uvs, new_faces, vmapping, meta = uv_module.unwrap_with_xatlas(
        vertices,
        normals,
        faces,
        atlas_size=256,
        profile="fast",
        on_progress=lambda step, progress=None: events.append((step, progress)),
        helper_path=helper_path,
        use_native=True,
    )

    assert meta["native_xatlas"] is True
    assert len(new_verts) >= 3
    assert len(new_normals) == len(new_verts)
    assert new_uvs.shape[1] == 2
    assert new_faces.shape[1] == 3
    assert vmapping.max() < len(vertices)
    assert any("ComputeCharts" in step for step, _ in events)
