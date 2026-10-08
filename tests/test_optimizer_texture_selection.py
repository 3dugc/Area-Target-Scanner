"""Area Target passes its persisted texture choice to the optimizer."""

import copy
import json
import struct
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import pytest

from processing_pipeline.optimized_pipeline import OptimizedPipeline


def _glb(metadata, binary=b"\x01\x02\x03\x04"):
    metadata = copy.deepcopy(metadata)
    metadata.setdefault("asset", {"version": "2.0"})
    payload = json.dumps(metadata, separators=(",", ":")).encode()
    payload += b" " * (-len(payload) % 4)
    binary += b"\0" * (-len(binary) % 4)
    return (
        struct.pack("<4sII", b"glTF", 2, 28 + len(payload) + len(binary))
        + struct.pack("<II", len(payload), 0x4E4F534A)
        + payload
        + struct.pack("<II", len(binary), 0x004E4942)
        + binary
    )


def _metadata(raw):
    length = struct.unpack_from("<I", raw, 12)[0]
    return json.loads(raw[20 : 20 + length]), raw[20 + length :]


def _downloaded_format(tmp_path, texture_compression=None):
    artifact = _glb(
        {
            "images": [{"mimeType": "image/jpeg", "bufferView": 0}],
            "textures": [{"source": 0}],
            "bufferViews": [{"buffer": 0, "byteLength": 4}],
            "buffers": [{"byteLength": 4}],
        }
    )
    args = (
        {}
        if texture_compression is None
        else {"texture_compression": texture_compression}
    )
    pipeline = OptimizedPipeline(**args)
    scan = SimpleNamespace(
        obj_path="model.obj", mtl_path="model.mtl", texture_path="texture.jpg"
    )
    with patch(
        "processing_pipeline.optimized_pipeline.ModelOptimizerClient"
    ) as factory:
        client = factory.return_value
        client.optimize.return_value = "task"
        client.wait_for_completion.return_value = "completed"
        client.download.side_effect = lambda _id, dest: Path(dest).write_bytes(artifact)
        output = pipeline.optimize_model(scan, str(tmp_path))
        assert Path(output).read_bytes() == artifact
        return client.optimize.call_args.kwargs["options"]


def test_default_retains_core_jpeg_png_texture(tmp_path):
    options = _downloaded_format(tmp_path)
    assert options["texture"]["enabled"] is False
    assert options["draco"]["enabled"] is False


@pytest.mark.parametrize("enabled", [False, True])
def test_optimizer_receives_explicit_texture_selection(tmp_path, enabled):
    options = _downloaded_format(tmp_path, enabled)
    assert options["texture"]["enabled"] is enabled
