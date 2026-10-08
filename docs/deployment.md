# Processing pipeline deployment

The current production entry point is https://at.3dugc.com. `area-target.p.01xr.com` is the legacy deployment hostname. The Portainer stack in [`docker-compose.portainer.yml`](../docker-compose.portainer.yml) serves the Flask processing pipeline through Traefik and runs its compatible model optimizer on a private backend network. Pages and APIs require service login; `/login`, the login endpoint, and minimal `/healthz` remain public. Configure credentials before deploying an image with login support; see [service login](service-login.md).

## Images and branches

Both images are built for `linux/amd64` and published to Tencent Container Registry:

| Component | Image | Build source |
|---|---|---|
| Processing pipeline and web UI | `hkccr.ccs.tencentyun.com/plugins/area-target-scanner` | Root `Dockerfile` |
| Compatible optimizer companion | `hkccr.ccs.tencentyun.com/plugins/area-target-optimizer` | Root context with `deploy/optimizer.Dockerfile` and pinned `model_optimizer/` source |

| Branch | Purpose | Published tags |
|---|---|---|
| `develop` | Development integration | `develop` |
| `main` | Stable mainline and runtime verification | None |
| `publish` | Release deployment | `latest` |

Only `develop` and `latest` tags are pushed for each image. Commit IDs remain in image revision labels and CI reports for verification; they are not published as image tags.

The optimizer source is pinned by the gitlink at `255b46e2d9ad15906e683efda02eefab3e8d2eb4`, a three-file WebP export fix on the compatible `8ced6f3a908c5f2fcdec578238e65064e9f009e7` baseline. Its source is maintained in the independent `3D-Model-Optimizer` repository. Its companion image supports the OBJ/ZIP → GLB path used by this pipeline, including Sharp texture processing. Optional CAD, FBX and KTX toolchains are omitted. Review the pipeline API contract before changing the gitlink, and update `OPTIMIZER_COMMIT` in the deploy workflow at the same time. The separately deployed optimizer's current release has a different API contract.

The pinned revision's legacy `package-lock.json` contains invalid local symlink paths. Deployment therefore uses [`deploy/optimizer-package-lock.json`](../deploy/optimizer-package-lock.json), regenerated from that revision's unchanged `package.json`. CI checks the source commit first, overlays this lock, and runs `npm ci`, build and tests. The optimizer image installs from the same lock. When changing optimizer dependencies, regenerate and validate this deployment lock together with the pinned source.

## GitHub Actions configuration

Add these repository secrets for `hkccr.ccs.tencentyun.com`:

- `TENCENT_REGISTRY_USERNAME`, or the existing alias `TENCENT_REGISTRY_USER`.
- `TENCENT_REGISTRY_PASSWORD`.

The registry account needs push access to both image repositories under `plugins`. Portainer needs pull access to the same registry.

[`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) runs on pushes to `develop`, `main` and `publish`, and supports manual runs on those branches. Publishing from `develop` or `publish` fails immediately if credentials are missing or Tencent registry login fails. The `main` branch runs all validation and runtime checks without registry credentials or image publication. Organization secrets can be inherited when this repository is included in their access policy. It checks out only the pinned optimizer submodule using public HTTPS; nested submodules are not needed.

Before publishing, the workflow runs Python pipeline/web/authentication tests and the optimizer's locked npm install, TypeScript build and tests. It then builds and loads both images with separate GitHub Actions cache scopes, starts them together with a newly generated random test password, and runs normal and oversized synthetic scans through login, upload, processing and asset download. Smoke verifies that unauthenticated upload is rejected and that service sessions do not bypass per-job Bearer tokens. Temporary credentials are passed through private files and removed during cleanup. Only these verified images are tagged and pushed from `develop` or `publish`; `main` runs the same checks and skips publication. Pull requests do not publish images. The existing `CI` workflow continues to cover the wider native, Unity and iOS checks separately.

## Portainer stack

1. Confirm the target Docker host has the external `proxy` network, and Traefik uses the `websecure` entry point and `letsencrypt` certificate resolver. Point `at.3dugc.com` DNS at that host.
2. Add Tencent Container Registry to Portainer using a credential that can pull both images.
3. Generate a password hash as described in [service login](service-login.md). Create or update an `area-target` stack from `docker-compose.portainer.yml`. Set `AREA_TARGET_USERNAME` and `AREA_TARGET_PASSWORD_HASH`; Compose rejects empty credentials. Both image references use `latest`; an old `AREA_TARGET_IMAGE_TAG` stack variable does not override them. For a development deployment, change both image references to `develop`. The host defaults to `at.3dugc.com`. For an existing live stack, preserve its configured routes, resource limits and volumes when adding authentication variables.
4. Pull the published images and deploy the stack. The optimizer health check gates pipeline startup. The pipeline listens internally on port `5000`; the optimizer listens on backend port `3000`.
5. Open https://at.3dugc.com, log in, and verify a scan upload completes. Export `AREA_TARGET_USERNAME` and `AREA_TARGET_PASSWORD` from a secure prompt as described in [service login](service-login.md), then run the repeatable HTTP check:

   ```bash
   python tools/deployment/smoke.py --url https://at.3dugc.com --timeout 180
   ```

The pipeline runs as `appuser` under Gunicorn with one worker and four threads; the optimizer runs as `node`. The stack limits the pipeline to 3 CPUs / 5 GiB and the optimizer to 1 CPU / 768 MiB, matching the current server allocation. Pipeline job execution is limited to one worker with three queued jobs. Traefik reaches the pipeline through `proxy`; the optimizer stays on the internal `backend` network. Docker checks the public `/healthz` endpoint for liveness.

Web uploads through `/api/upload` allow up to 1,000,000,000 total camera-image pixels, including 100 original 1920×1440 images (276,480,000 pixels). The web worker passes these original frames and dimensions to processing. The 512 MiB request, 500 MiB expanded ZIP, 32-million-pixel individual image, and 8,192-pixel image dimension limits still apply. Mobile API working-scan budgets retain their negotiated preparation policy.

Watchtower is disabled for both services. Update the stack deliberately and pull both `latest` images after each release. GitHub Actions publishes images; it does not call Portainer.

## Persistent data and release flow

Keep the three named volumes when updating or recreating the stack:

| Volume | Container path | Contents |
|---|---|---|
| `pipeline_uploads` | `/tmp/pipeline_uploads` | Uploaded scan ZIPs and temporary scan data |
| `pipeline_outputs` | `/tmp/pipeline_outputs` | Asset bundles, durable `jobs.sqlite` job history and `service_auth.sqlite` sessions/login limits |
| `model_optimizer_temp` | `/app/temp` | Optimizer uploads and results |

Docker normally prefixes volume names with the stack name. Keep that name stable, and back up these volumes before moving hosts. Restored volumes must be writable by each image's runtime user. Pipeline retention defaults are 24 hours for completed jobs and 6 hours for failed jobs; job history survives container restarts, while interrupted queued or processing jobs are marked failed and must be submitted again. Let active jobs finish before an update. Scheduled cleanup still applies.

1. Merge feature work into `develop` and let validation and image publishing complete.
2. After validation, promote `develop` into `main` and wait for its validation and runtime checks. This branch does not push image tags.
3. When ready to release, merge `main` into `publish`.
4. Deploy the `latest` image tag for both services, then rerun the HTTP smoke check.

Tags are mutable. Record the two deployed image digests before an update so a rollback can restore the previous pair while preserving the existing volumes.

### GLB 纹理兼容选项

Web 上传默认保留源 JPEG/PNG 纹理，不执行纹理格式压缩，以便兼容标准 GLB 查看器。模型几何仍按原优化流程处理。上传页可显式勾选“压缩纹理为 WebP（需要查看器支持）”；对应 `/api/upload` 表单字段 `texture_compression=1`（或 `true`）。未提供字段、`0` 或 `false` 表示关闭，其他值返回400。当前优化器镜像未安装 toktx，压缩回退使用 WebP；WebP 编码与 `EXT_texture_webp` 声明由独立的 `3D-Model-Optimizer` 项目负责，查看器仍须支持该扩展。

任务数据库保存该选择，状态响应包含布尔字段 `texture_compression`。缓存身份包含纹理选项，默认缓存版本升级为v5，避免复用此前的纹理格式结果。移动端未提交选项时也默认保留 JPEG/PNG；既有结果文件不原地改写，可重新提交原扫描生成兼容版本。

### UV 图集方向

服务端重新展开 UV 时，OBJ 的 V=0 对应贴图底部，而图像行从顶部开始。纹理烘焙和空洞填充结束后，写出前翻转一次图像行，保留 OBJ UV 与模型几何。默认缓存版本 v5 避免复用旧方向图集。原 iOS 图集（关闭重新展开 UV 时）保持原样。
