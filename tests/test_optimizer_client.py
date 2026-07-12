"""Unit tests for ModelOptimizerClient (mock HTTP).

Validates: Requirements 2.1, 2.2, 2.3, 2.6

Tests the ModelOptimizerClient class with mocked HTTP requests, verifying
optimize returns task_id, get_status parses responses, download writes files,
and wait_for_completion terminates on completed/failed status.
"""

from __future__ import annotations

import os
from unittest.mock import MagicMock, patch

import pytest

from processing_pipeline.optimizer_client import ModelOptimizerClient


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_client(base_url: str = "http://localhost:3000") -> ModelOptimizerClient:
    return ModelOptimizerClient(base_url=base_url, timeout=30)


def _mock_response(json_data=None, status_code=200, content=b""):
    """Create a mock requests.Response."""
    resp = MagicMock()
    resp.status_code = status_code
    resp.json.return_value = json_data or {}
    resp.raise_for_status.return_value = None
    resp.iter_content.return_value = [content] if content else []
    return resp


# ---------------------------------------------------------------------------
# Tests: optimize
# ---------------------------------------------------------------------------


class TestOptimize:
    """Test ModelOptimizerClient.optimize returns task_id.

    Validates: Requirement 2.1
    """

    @patch("processing_pipeline.optimizer_client.requests.post")
    def test_optimize_returns_task_id(self, mock_post, tmp_path):
        """optimize() should POST to /api/optimize and return the taskId."""
        obj_file = tmp_path / "model.obj"
        obj_file.write_text("v 0 0 0")

        mock_post.return_value = _mock_response(json_data={"taskId": "abc-123"})

        client = _make_client()
        task_id = client.optimize(str(obj_file))

        assert task_id == "abc-123"
        mock_post.assert_called_once()
        call_kwargs = mock_post.call_args
        assert "/api/optimize" in call_kwargs[0][0] or "/api/optimize" in str(call_kwargs)

    @patch("processing_pipeline.optimizer_client.requests.post")
    def test_optimize_sends_preset(self, mock_post, tmp_path):
        """optimize() should send the preset in form data."""
        obj_file = tmp_path / "model.obj"
        obj_file.write_text("v 0 0 0")

        mock_post.return_value = _mock_response(json_data={"taskId": "task-456"})

        client = _make_client()
        client.optimize(str(obj_file), preset="aggressive")

        call_kwargs = mock_post.call_args
        assert call_kwargs.kwargs["data"]["preset"] == "aggressive"

    @patch("processing_pipeline.optimizer_client.requests.post")
    def test_optimize_raises_on_http_error(self, mock_post, tmp_path):
        """optimize() should propagate HTTP errors."""
        obj_file = tmp_path / "model.obj"
        obj_file.write_text("v 0 0 0")

        mock_resp = _mock_response()
        mock_resp.raise_for_status.side_effect = Exception("500 Server Error")
        mock_post.return_value = mock_resp

        client = _make_client()
        with pytest.raises(Exception, match="500 Server Error"):
            client.optimize(str(obj_file))


# ---------------------------------------------------------------------------
# Tests: get_status
# ---------------------------------------------------------------------------


class TestGetStatus:
    """Test ModelOptimizerClient.get_status parses responses.

    Validates: Requirement 2.2
    """

    @patch("processing_pipeline.optimizer_client.requests.get")
    def test_get_status_returns_dict(self, mock_get):
        """get_status() should return the parsed JSON response."""
        expected = {"status": "processing", "progress": 50}
        mock_get.return_value = _mock_response(json_data=expected)

        client = _make_client()
        result = client.get_status("task-789")

        assert result == expected
        assert result["status"] == "processing"
        assert result["progress"] == 50

    @patch("processing_pipeline.optimizer_client.requests.get")
    def test_get_status_completed(self, mock_get):
        """get_status() should parse completed status."""
        mock_get.return_value = _mock_response(
            json_data={"status": "completed", "outputFile": "result.glb"}
        )

        client = _make_client()
        result = client.get_status("task-done")

        assert result["status"] == "completed"

    @patch("processing_pipeline.optimizer_client.requests.get")
    def test_get_status_calls_correct_url(self, mock_get):
        """get_status() should call /api/status/{task_id}."""
        mock_get.return_value = _mock_response(json_data={"status": "pending"})

        client = _make_client("http://opt:3000")
        client.get_status("my-task")

        mock_get.assert_called_once()
        url = mock_get.call_args[0][0]
        assert url == "http://opt:3000/api/status/my-task"


# ---------------------------------------------------------------------------
# Tests: download
# ---------------------------------------------------------------------------


class TestDownload:
    """Test ModelOptimizerClient.download writes file to disk.

    Validates: Requirement 2.3
    """

    @patch("processing_pipeline.optimizer_client.requests.get")
    def test_download_writes_file(self, mock_get, tmp_path):
        """download() should stream content to the output file."""
        glb_content = b"\x00GLB_BINARY_DATA\x01\x02\x03"
        mock_resp = _mock_response(content=glb_content)
        mock_resp.iter_content.return_value = [glb_content]
        mock_get.return_value = mock_resp

        client = _make_client()
        output_path = str(tmp_path / "optimized.glb")
        result = client.download("task-dl", output_path)

        assert result == output_path
        assert os.path.isfile(output_path)
        with open(output_path, "rb") as f:
            assert f.read() == glb_content

    @patch("processing_pipeline.optimizer_client.requests.get")
    def test_download_writes_multiple_chunks(self, mock_get, tmp_path):
        """download() should handle multiple chunks correctly."""
        chunks = [b"chunk1", b"chunk2", b"chunk3"]
        mock_resp = _mock_response()
        mock_resp.iter_content.return_value = chunks
        mock_get.return_value = mock_resp

        client = _make_client()
        output_path = str(tmp_path / "result.glb")
        client.download("task-multi", output_path)

        with open(output_path, "rb") as f:
            assert f.read() == b"chunk1chunk2chunk3"

    @patch("processing_pipeline.optimizer_client.requests.get")
    def test_download_calls_correct_url(self, mock_get, tmp_path):
        """download() should call /api/download/{task_id}."""
        mock_resp = _mock_response()
        mock_resp.iter_content.return_value = [b"data"]
        mock_get.return_value = mock_resp

        client = _make_client("http://opt:3000")
        output_path = str(tmp_path / "out.glb")
        client.download("dl-task", output_path)

        url = mock_get.call_args[0][0]
        assert url == "http://opt:3000/api/download/dl-task"


# ---------------------------------------------------------------------------
# Tests: wait_for_completion
# ---------------------------------------------------------------------------


class TestWaitForCompletion:
    """Test ModelOptimizerClient.wait_for_completion terminates correctly.

    Validates: Requirement 2.6
    """

    @patch("processing_pipeline.optimizer_client.time.sleep")
    @patch("processing_pipeline.optimizer_client.requests.get")
    def test_returns_completed_immediately(self, mock_get, mock_sleep):
        """wait_for_completion() should return 'completed' on first poll."""
        mock_get.return_value = _mock_response(
            json_data={"status": "completed"}
        )

        client = _make_client()
        result = client.wait_for_completion("task-1", poll_interval=0.01)

        assert result == "completed"
        mock_sleep.assert_not_called()

    @patch("processing_pipeline.optimizer_client.time.sleep")
    @patch("processing_pipeline.optimizer_client.requests.get")
    def test_returns_failed_immediately(self, mock_get, mock_sleep):
        """wait_for_completion() should return 'failed' on first poll."""
        mock_get.return_value = _mock_response(
            json_data={"status": "failed"}
        )

        client = _make_client()
        result = client.wait_for_completion("task-2", poll_interval=0.01)

        assert result == "failed"
        mock_sleep.assert_not_called()

    @patch("processing_pipeline.optimizer_client.time.sleep")
    @patch("processing_pipeline.optimizer_client.requests.get")
    def test_polls_until_completed(self, mock_get, mock_sleep):
        """wait_for_completion() should poll until status is 'completed'."""
        mock_get.side_effect = [
            _mock_response(json_data={"status": "pending"}),
            _mock_response(json_data={"status": "processing"}),
            _mock_response(json_data={"status": "completed"}),
        ]

        client = _make_client()
        result = client.wait_for_completion("task-3", poll_interval=0.01)

        assert result == "completed"
        assert mock_get.call_count == 3
        assert mock_sleep.call_count == 2

    @patch("processing_pipeline.optimizer_client.time.sleep")
    @patch("processing_pipeline.optimizer_client.requests.get")
    def test_polls_until_failed(self, mock_get, mock_sleep):
        """wait_for_completion() should poll until status is 'failed'."""
        mock_get.side_effect = [
            _mock_response(json_data={"status": "pending"}),
            _mock_response(json_data={"status": "failed"}),
        ]

        client = _make_client()
        result = client.wait_for_completion("task-4", poll_interval=0.01)

        assert result == "failed"
        assert mock_get.call_count == 2
        assert mock_sleep.call_count == 1
