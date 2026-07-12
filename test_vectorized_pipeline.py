#!/usr/bin/env python3
"""测试向量化 UV 展开管线 — 验证正确性 + 计时"""
import logging
import time
import sys

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

sys.path.insert(0, ".")
from processing_pipeline.uv_unwrap import uv_unwrap_scan

SCAN_DIR = "/tmp/test_uv_data2/scan_20260323_175533"

t0 = time.time()
stats = uv_unwrap_scan(SCAN_DIR)
elapsed = time.time() - t0

print(f"\n=== 向量化管线完成 ===")
print(f"总耗时: {elapsed:.1f}s")
print(f"统计: {stats}")
