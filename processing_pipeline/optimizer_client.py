"""REST API client for the 3D-Model-Optimizer service (https://github.com/3dugc/3D-Model-Optimizer)."""

from __future__ import annotations

import time

import requests


class ModelOptimizerClient:
    """3D-Model-Optimizer REST API 客户端。

    Communicates with the 3D-Model-Optimizer Docker service to convert
    OBJ models into optimized GLB format with Draco and texture compression.
    """

    def __init__(
        self,
        base_url: str = "http://model_optimizer:3000",
        timeout: int = 300,
    ) -> None:
        self.base_url = base_url
        self.timeout = timeout

    def optimize(
        self,
        obj_path: str,
        mtl_path: str | None = None,
        texture_path: str | None = None,
        preset: str = "balanced",
        options: dict | None = None,
    ) -> str:
        """Pack OBJ + MTL + texture into a ZIP and upload to the optimizer.

        Args:
            obj_path: Path to the OBJ file to optimize.
            mtl_path: Optional path to the MTL material file.
            texture_path: Optional path to the texture image file.
            preset: Optimization preset (e.g. "balanced").
            options: Optional dict of custom optimization options that override
                the preset (e.g. ``{"draco": {"enabled": False}}``).

        Returns:
            The task_id string for tracking the optimization job.
        """
        import json as _json
        import os
        import tempfile
        import zipfile

        # Build a ZIP containing the OBJ and its companion files
        zip_fd, zip_path = tempfile.mkstemp(suffix=".zip")
        try:
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zf:
                zf.write(obj_path, os.path.basename(obj_path))
                if mtl_path and os.path.isfile(mtl_path):
                    zf.write(mtl_path, os.path.basename(mtl_path))
                if texture_path and os.path.isfile(texture_path):
                    zf.write(texture_path, os.path.basename(texture_path))

            form_data: dict = {"preset": preset}
            if options:
                form_data["options"] = _json.dumps(options)

            with open(zip_path, "rb") as f:
                resp = requests.post(
                    f"{self.base_url}/api/optimize",
                    files={"file": ("model.zip", f, "application/zip")},
                    data=form_data,
                    timeout=self.timeout,
                )
        finally:
            os.close(zip_fd)
            os.unlink(zip_path)

        resp.raise_for_status()
        return resp.json()["taskId"]

    def get_status(self, task_id: str) -> dict:
        """Query the status of an optimization task.

        Args:
            task_id: The task identifier returned by :meth:`optimize`.

        Returns:
            A dict containing at least a ``"status"`` key.
        """
        resp = requests.get(
            f"{self.base_url}/api/status/{task_id}",
            timeout=30,
        )
        resp.raise_for_status()
        return resp.json()

    def download(self, task_id: str, output_path: str) -> str:
        """Download the optimized GLB file for a completed task.

        Args:
            task_id: The task identifier.
            output_path: Local path where the GLB file will be written.

        Returns:
            The *output_path* that was written to.
        """
        resp = requests.get(
            f"{self.base_url}/api/download/{task_id}",
            timeout=self.timeout,
            stream=True,
        )
        resp.raise_for_status()
        with open(output_path, "wb") as f:
            for chunk in resp.iter_content(chunk_size=8192):
                f.write(chunk)
        return output_path

    def wait_for_completion(
        self,
        task_id: str,
        poll_interval: float = 2.0,
        timeout: float = 1800.0,
    ) -> str:
        """Poll until the task reaches a terminal status.

        Repeatedly calls :meth:`get_status` and sleeps for *poll_interval*
        seconds between calls until the status is ``"completed"`` or
        ``"failed"``.

        Args:
            task_id: The task identifier.
            poll_interval: Seconds to wait between status checks.
            timeout: Maximum seconds to wait before raising ``TimeoutError``.
                Defaults to 1800 (30 minutes).

        Returns:
            The terminal status string (``"completed"`` or ``"failed"``).

        Raises:
            TimeoutError: If the task does not reach a terminal status within
                *timeout* seconds.
        """
        start = time.monotonic()
        while True:
            if time.monotonic() - start > timeout:
                raise TimeoutError(
                    f"Optimizer task {task_id} did not complete within {timeout}s"
                )
            status = self.get_status(task_id)
            if status["status"] in ("completed", "failed"):
                return status["status"]
            time.sleep(poll_interval)
