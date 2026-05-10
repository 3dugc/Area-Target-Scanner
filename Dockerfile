FROM python:3.11-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libgl1 libglib2.0-0 libgomp1 libsm6 libxext6 libxrender1 \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY web_service/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY processing_pipeline/ /app/processing_pipeline/
COPY web_service/ /app/web_service/
COPY native/ /app/native/
COPY ios_scanner/AreaTargetScanner/ThirdParty/xatlas/xatlas.h /app/native/xatlas/xatlas.h
COPY ios_scanner/AreaTargetScanner/ThirdParty/xatlas/xatlas.cpp /app/native/xatlas/xatlas.cpp

RUN mkdir -p /app/bin && \
    g++ -std=c++17 -O2 -DNDEBUG -I/app/native/xatlas \
        /app/native/xatlas_helper.cpp /app/native/xatlas/xatlas.cpp \
        -o /app/bin/xatlas_helper

RUN useradd --create-home --shell /bin/bash appuser

ENV PYTHONPATH=/app

EXPOSE 5000

# volume 目录在运行时由 docker compose 挂载，需要在 entrypoint 确保权限
# 这里不切换 user，因为 named volume 首次创建时需要 root 权限
# 改为在 CMD 中用 root 运行（开发环境）

CMD ["python", "web_service/app.py"]
