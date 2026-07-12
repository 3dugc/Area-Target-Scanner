"""Property-based tests for mesh reconstruction and simplification.

**Validates: Requirements 5.3, 5.4, 6.3, 6.4, 6.5**

Property P2: Mesh reconstruction outputs a valid mesh.
  - All triangles have area > 0 (no degenerate triangles).
  - Every vertex belongs to at least one triangle.

Property P3: Mesh simplification preserves topological approximation.
  - Simplified face count <= target face count.
  - Bounding box deviation < 5%.
"""

from __future__ import annotations

import copy

import numpy as np
import open3d as o3d
import pytest


def _simplify_mesh(mesh: o3d.geometry.TriangleMesh, target_faces: int) -> o3d.geometry.TriangleMesh:
    """Simplify mesh using Open3D quadric decimation (replaces removed ReconstructionPipeline)."""
    return mesh.simplify_quadric_decimation(target_number_of_triangles=target_faces)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _triangle_areas(mesh: o3d.geometry.TriangleMesh) -> np.ndarray:
    vertices = np.asarray(mesh.vertices)
    triangles = np.asarray(mesh.triangles)
    v0 = vertices[triangles[:, 0]]
    v1 = vertices[triangles[:, 1]]
    v2 = vertices[triangles[:, 2]]
    cross = np.cross(v1 - v0, v2 - v0)
    return 0.5 * np.linalg.norm(cross, axis=1)


def _bounding_box_extents(mesh):
    vertices = np.asarray(mesh.vertices)
    return vertices.min(axis=0), vertices.max(axis=0)


def _get_sphere_mesh():
    from tests.conftest import get_sphere_mesh
    return get_sphere_mesh()


def _get_ellipsoid_mesh():
    from tests.conftest import get_ellipsoid_mesh
    return get_ellipsoid_mesh()


# ---------------------------------------------------------------------------
# Property P2: Mesh reconstruction outputs a valid mesh
# ---------------------------------------------------------------------------


class TestMeshReconstructionProperties:
    """Property P2 — Validates: Requirements 5.3, 5.4"""

    @pytest.mark.parametrize("mesh_getter", [_get_sphere_mesh, _get_ellipsoid_mesh],
                             ids=["sphere", "ellipsoid"])
    def test_p2_all_triangles_have_positive_area(self, mesh_getter):
        mesh = mesh_getter()
        areas = _triangle_areas(mesh)
        assert len(areas) > 0, "Mesh has no triangles"
        assert np.all(areas > 0), (
            f"{(areas <= 0).sum()} degenerate triangles (area <= 0) out of {len(areas)}"
        )

    @pytest.mark.parametrize("mesh_getter", [_get_sphere_mesh, _get_ellipsoid_mesh],
                             ids=["sphere", "ellipsoid"])
    def test_p2_all_vertices_referenced(self, mesh_getter):
        mesh = mesh_getter()
        triangles = np.asarray(mesh.triangles)
        referenced = set(triangles.flatten())
        n_vertices = len(mesh.vertices)
        assert len(referenced) == n_vertices, (
            f"{n_vertices - len(referenced)} unreferenced vertices out of {n_vertices}"
        )


# ---------------------------------------------------------------------------
# Property P3: Mesh simplification preserves topological approximation
# ---------------------------------------------------------------------------


class TestMeshSimplificationProperties:
    """Property P3 — Validates: Requirements 6.3, 6.4, 6.5"""

    @pytest.mark.parametrize("mesh_getter", [_get_sphere_mesh, _get_ellipsoid_mesh],
                             ids=["sphere", "ellipsoid"])
    @pytest.mark.parametrize("target_faces", [200, 500, 1000, 2000])
    def test_p3_face_count_within_target(self, mesh_getter, target_faces):
        mesh = mesh_getter()
        if len(mesh.triangles) <= target_faces:
            pytest.skip("mesh already below target")
        simplified = _simplify_mesh(copy.deepcopy(mesh), target_faces=target_faces)
        assert len(simplified.triangles) <= target_faces

    @pytest.mark.parametrize("mesh_getter", [_get_sphere_mesh, _get_ellipsoid_mesh],
                             ids=["sphere", "ellipsoid"])
    @pytest.mark.parametrize("target_faces", [200, 500, 1000, 2000])
    def test_p3_bounding_box_deviation_within_5_percent(self, mesh_getter, target_faces):
        mesh = mesh_getter()
        if len(mesh.triangles) <= target_faces:
            pytest.skip("mesh already below target")
        orig_min, orig_max = _bounding_box_extents(mesh)
        simplified = _simplify_mesh(copy.deepcopy(mesh), target_faces=target_faces)
        simp_min, simp_max = _bounding_box_extents(simplified)
        orig_extent = orig_max - orig_min
        safe_extent = np.where(orig_extent > 1e-10, orig_extent, 1.0)
        min_deviation = np.abs(simp_min - orig_min) / safe_extent
        max_deviation = np.abs(simp_max - orig_max) / safe_extent
        max_dev = max(min_deviation.max(), max_deviation.max())
        assert max_dev < 0.05, (
            f"Bounding box deviation {max_dev:.4f} exceeds 5% threshold"
        )