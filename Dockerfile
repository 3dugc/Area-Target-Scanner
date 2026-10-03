FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libegl1 libusb-1.0-0 libidn2-0 libgl1 libglib2.0-0 libgomp1 libsm6 libxext6 libxrender1 \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY web_service/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt \
    && python -c "import open3d"

COPY processing_pipeline/ /app/processing_pipeline/
COPY web_service/ /app/web_service/
COPY native/ /app/native/
COPY ios_scanner/AreaTargetScanner/ThirdParty/xatlas/xatlas.h /app/native/xatlas/xatlas.h
COPY ios_scanner/AreaTargetScanner/ThirdParty/xatlas/xatlas.cpp /app/native/xatlas/xatlas.cpp

RUN mkdir -p /app/bin && \
    g++ -std=c++17 -O2 -DNDEBUG -I/app/native/xatlas \
        /app/native/xatlas_helper.cpp /app/native/xatlas/xatlas.cpp \
        -o /app/bin/xatlas_helper && \
    useradd --create-home --shell /bin/bash appuser && \
    mkdir -p /tmp/pipeline_uploads /tmp/pipeline_outputs && \
    chown -R appuser:appuser /tmp/pipeline_uploads /tmp/pipeline_outputs

ENV PYTHONPATH=/app

EXPOSE 5000

USER appuser

HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:5000/', timeout=4)"

# One process owns the SQLite-backed job queue and cleanup thread.
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "1", "--threads", "4", "--timeout", "120", "--access-logfile", "-", "--error-logfile", "-", "web_service.app:app"]
