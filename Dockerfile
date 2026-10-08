FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libegl1 libusb-1.0-0 libidn2-0 libgl1 libglib2.0-0 libgomp1 libsm6 libxext6 libxrender1 \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY web_service/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

# Open3D's Linux arm64 wheel requires the system Fortran runtime.
# Keep runtime installation and import checks after the cached Python install.
RUN apt-get update && apt-get install -y --no-install-recommends libgfortran5 \
    && rm -rf /var/lib/apt/lists/*
RUN python -c "import open3d, cv2; assert cv2.__version__.split('.')[0] == '5'; cv2.ORB_create(); cv2.xfeatures2d.AKAZE_create(); assert callable(cv2.solvePnPRansac)"

COPY processing_pipeline/ /app/processing_pipeline/
COPY web_service/ /app/web_service/
COPY native/ /app/native/
COPY native_visual_localizer/include/area_target_runtime.h /app/native-quality/include/area_target_runtime.h
COPY native_visual_localizer/src/frame_contract.h /app/native-quality/src/frame_contract.h
COPY native_visual_localizer/src/frame_contract.cpp /app/native-quality/src/frame_contract.cpp
COPY native_visual_localizer/src/gray_quality.cpp /app/native-quality/src/gray_quality.cpp
COPY native_visual_localizer/src/rigid_math.h /app/native-quality/src/rigid_math.h
COPY native_visual_localizer/src/keyframe_selection.cpp /app/native-quality/src/keyframe_selection.cpp
COPY ios_scanner/AreaTargetScanner/ThirdParty/xatlas/xatlas.h /app/native/xatlas/xatlas.h
COPY ios_scanner/AreaTargetScanner/ThirdParty/xatlas/xatlas.cpp /app/native/xatlas/xatlas.cpp

RUN mkdir -p /app/bin && \
    g++ -std=c++17 -O2 -shared -fPIC -fvisibility=hidden -I/app/native-quality/include -I/app/native-quality/src \
        /app/native-quality/src/gray_quality.cpp /app/native-quality/src/frame_contract.cpp /app/native-quality/src/keyframe_selection.cpp \
        -o /app/bin/libarea_target_quality.so && \
    g++ -std=c++17 -O2 -DNDEBUG -I/app/native/xatlas \
        /app/native/xatlas_helper.cpp /app/native/xatlas/xatlas.cpp \
        -o /app/bin/xatlas_helper && \
    useradd --create-home --shell /bin/bash appuser && \
    mkdir -p /tmp/pipeline_uploads /tmp/pipeline_outputs && \
    chown -R appuser:appuser /tmp/pipeline_uploads /tmp/pipeline_outputs

ENV PYTHONPATH=/app
ENV AREA_TARGET_QUALITY_LIBRARY=/app/bin/libarea_target_quality.so

# CI passes the same timestamp used by the OCI created label. Changing the
# build argument also prevents Docker's cache from retaining an older version.
ARG BUILD_TIME
RUN python /app/web_service/build_version.py --build-time "$BUILD_TIME"

EXPOSE 5000

USER appuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/healthz', timeout=4)"

# One process owns the SQLite-backed job queue and cleanup thread.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--threads", "4", "--timeout", "120", "--access-logfile", "-", "--error-logfile", "-", "web_service.app:app"]
