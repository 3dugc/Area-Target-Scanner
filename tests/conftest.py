"""Shared fixtures and lazy mesh cache for tests.

Provides cached meshes built via Open3D's Poisson surface reconstruction
so that each distinct mesh is built at most once per process.
"""

from __future__ import annotations

import numpy as np
import open3d as o3d

from processing_pipeline.models import ProcessedCloud

_cache: dict[str, o3d.geometry.TriangleMesh] = {}


def _reconstruct_mesh(cloud: ProcessedCloud) -> o3d.geometry.TriangleMesh:
    """Build a triangle mesh from a ProcessedCloud using Poisson reconstruction."""
    pcd = o3d.geometry.PointCloud()
    pcd.points = o3d.utility.Vector3dVector(cloud.points)
    pcd.normals = o3d.utility.Vector3dVector(cloud.normals)
    if cloud.colors is not None and len(cloud.colors) > 0:
        pcd.colors = o3d.utility.Vector3dVector(cloud.colors)
    # Open3D's automatic Poisson thread count can terminate the Python process
    # on this macOS wheel; OMP_NUM_THREADS alone does not constrain this option.
    # Keep the same reconstruction and point clouds while bounding fixture work.
    mesh, densities = o3d.geometry.TriangleMesh.create_from_point_cloud_poisson(
        pcd, depth=9, n_threads=1
    )
    # Crop low-density vertices
    densities_arr = np.asarray(densities)
    threshold = np.quantile(densities_arr, 0.01)
    vertices_to_remove = densities_arr < threshold
    mesh.remove_vertices_by_mask(vertices_to_remove)
    mesh.compute_vertex_normals()
    return mesh


def get_sphere_mesh(n_points: int = 5000, radius: float = 1.0) -> o3d.geometry.TriangleMesh:
    """Return a cached sphere mesh (built lazily on first call)."""
    key = f"sphere_{n_points}_{radius}"
    if key not in _cache:
        cloud = make_sphere_cloud(n_points=n_points, radius=radius)
        _cache[key] = _reconstruct_mesh(cloud)
    return _cache[key]


def get_ellipsoid_mesh(
    n_points: int = 5000, radii: tuple = (2.0, 1.0, 0.7),
) -> o3d.geometry.TriangleMesh:
    """Return a cached ellipsoid mesh (built lazily on first call)."""
    key = f"ellipsoid_{n_points}_{radii}"
    if key not in _cache:
        rng = np.random.default_rng(123)
        raw = rng.standard_normal((n_points, 3))
        norms = np.linalg.norm(raw, axis=1, keepdims=True)
        norms = np.clip(norms, 1e-10, None)
        unit = raw / norms
        rx, ry, rz = radii
        points = unit * np.array([[rx, ry, rz]])
        normals_raw = points / np.array([[rx**2, ry**2, rz**2]])
        normal_norms = np.linalg.norm(normals_raw, axis=1, keepdims=True)
        normal_norms = np.clip(normal_norms, 1e-10, None)
        normals = normals_raw / normal_norms
        colors = np.zeros((n_points, 3))
        cloud = ProcessedCloud(points=points, normals=normals, colors=colors, point_count=n_points)
        _cache[key] = _reconstruct_mesh(cloud)
    return _cache[key]


def make_sphere_cloud(n_points: int = 5000, radius: float = 1.0) -> ProcessedCloud:
    """Create a ProcessedCloud of points on a sphere with outward normals."""
    rng = np.random.default_rng(42)
    raw = rng.standard_normal((n_points, 3))
    norms = np.linalg.norm(raw, axis=1, keepdims=True)
    norms = np.clip(norms, 1e-10, None)
    points = (raw / norms) * radius
    normals = raw / norms
    colors = np.zeros((n_points, 3))
    return ProcessedCloud(points=points, normals=normals, colors=colors, point_count=n_points)
