# Processing pipeline deployment

The production entry point is https://area-target.p.01xr.com. The Portainer stack in [`docker-compose.portainer.yml`](../docker-compose.portainer.yml) serves the Flask processing pipeline through Traefik and runs its compatible model optimizer on a private backend network.

## Images and branches

Both images are built for `linux/amd64` and published to Tencent Container Registry:

| Component | Image | Build source |
|---|---|---|
| Processing pipeline and web UI | `hkccr.ccs.tencentyun.com/plugins/area-target-scanner` | Root `Dockerfile` |
| Compatible optimizer companion | `hkccr.ccs.tencentyun.com/plugins/area-target-optimizer` | Root context with `deploy/optimizer.Dockerfile` and pinned `model_optimizer/` source |

| Branch | Purpose | Published tags |
|---|---|---|
| `develop` | Development integration | `develop` |
| `main` | Stable mainline | `main` |
| `publish` | Release deployment | `publish`, `latest` |

The optimizer source is pinned by the gitlink at `8ced6f3a908c5f2fcdec578238e65064e9f009e7`. Its companion image supports the OBJ/ZIP → GLB path used by this pipeline, including Sharp texture processing. Optional CAD, FBX and KTX toolchains are omitted. Review the pipeline API contract before changing the gitlink, and update `OPTIMIZER_COMMIT` in the deploy workflow at the same time. The separately deployed optimizer's current release has a different API contract.

The pinned revision's legacy `package-lock.json` contains invalid local symlink paths. Deployment therefore uses [`deploy/optimizer-package-lock.json`](../deploy/optimizer-package-lock.json), regenerated from that revision's unchanged `package.json`. CI checks the source commit first, overlays this lock, and runs `npm ci`, build and tests. The optimizer image installs from the same lock. When changing optimizer dependencies, regenerate and validate this deployment lock together with the pinned source.

## GitHub Actions configuration

Add these repository secrets for `hkccr.ccs.tencentyun.com`:

- `TENCENT_REGISTRY_USERNAME`, or the existing alias `TENCENT_REGISTRY_USER`.
- `TENCENT_REGISTRY_PASSWORD`.

The registry account needs push access to both image repositories under `plugins`. Portainer needs pull access to the same registry.

[`.github/workflows/deploy.yml`](../.github/workflows/deploy.yml) runs on pushes to `develop`, `main` and `publish`, and supports manual runs on those branches. It fails immediately if credentials are missing or Tencent registry login fails. Organization secrets can be inherited when this repository is included in their access policy. It checks out only the pinned optimizer submodule using public HTTPS; nested submodules are not needed.

Before publishing, the workflow runs Python pipeline/web tests and the optimizer's locked npm install, TypeScript build and tests. It then builds and loads both images with separate GitHub Actions cache scopes, starts them together, and runs a synthetic scan through upload, processing and asset download. Only these verified images are tagged and pushed. Pull requests do not publish images. The existing `CI` workflow continues to cover the wider native, Unity and iOS checks separately.

## Portainer stack

1. Confirm the target Docker host has the external `proxy` network, and Traefik uses the `websecure` entry point and `letsencrypt` certificate resolver. Point `area-target.p.01xr.com` DNS at that host.
2. Add Tencent Container Registry to Portainer using a credential that can pull both images.
3. Create or update an `area-target` stack from `docker-compose.portainer.yml`. Set `AREA_TARGET_IMAGE_TAG=publish`; set `AREA_TARGET_HOST=area-target.p.01xr.com` if overriding the default. The same tag is used for both services.
4. Pull the published images and deploy the stack. The optimizer health check gates pipeline startup. The pipeline listens internally on port `5000`; the optimizer listens on backend port `3000`.
5. Open https://area-target.p.01xr.com and verify a scan upload completes. The same repeatable HTTP check can be run locally:

   ```bash
   python tools/deployment/smoke.py --url https://area-target.p.01xr.com --timeout 180
   ```

The pipeline runs as `appuser` under Gunicorn with one worker and four threads; the optimizer runs as `node`. The stack limits the pipeline to 1.5 CPUs / 2 GiB and the optimizer to 0.75 CPU / 768 MiB. Pipeline job execution is limited to one worker with three queued jobs. Traefik reaches the pipeline through `proxy`; the optimizer stays on the internal `backend` network.

The stack opts both services into an existing Watchtower installation through its labels. If Watchtower is present and configured for these containers, it can refresh published tags. Otherwise, update the stack with image repull after each release. GitHub Actions publishes images; it does not call Portainer.

## Persistent data and release flow

Keep the three named volumes when updating or recreating the stack:

| Volume | Container path | Contents |
|---|---|---|
| `pipeline_uploads` | `/tmp/pipeline_uploads` | Uploaded scan ZIPs and temporary scan data |
| `pipeline_outputs` | `/tmp/pipeline_outputs` | Asset bundles and durable `jobs.sqlite` job history |
| `model_optimizer_temp` | `/app/temp` | Optimizer uploads and results |

Docker normally prefixes volume names with the stack name. Keep that name stable, and back up these volumes before moving hosts. Restored volumes must be writable by each image's runtime user. Pipeline retention defaults are 24 hours for completed jobs and 6 hours for failed jobs; job history survives container restarts, while interrupted queued or processing jobs are marked failed and must be submitted again. Let active jobs finish before an update. Scheduled cleanup still applies.

1. Merge feature work into `develop` and let validation and image publishing complete.
2. After validation, promote `develop` into `main`.
3. When ready to release, merge `main` into `publish`.
4. Deploy the `publish` or `latest` image tag for both services, then rerun the HTTP smoke check.

Tags are mutable. Record the two deployed image digests before an update so a rollback can restore the previous pair while preserving the existing volumes.
