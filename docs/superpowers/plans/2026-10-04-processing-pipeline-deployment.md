# Processing pipeline deployment

User scope: deploy the processing service in the existing Portainer environment at
https://area-target.p.01xr.com, with CI publishing to Tencent Hong Kong like other plugins.

1. Preserve the dirty iOS workspace by using the attached deployment worktree.
2. Publish root processing image and pinned-compatible optimizer companion to
   hkccr.ccs.tencentyun.com/plugins/area-target-scanner and plugins/area-target-optimizer.
   Branches develop/main/publish map to develop/main/publish; publish also updates latest.
3. Use a deployment-owned valid optimizer lockfile because the pinned legacy lock
   contains broken temporary symlink paths; keep its source commit unchanged.
   Validate existing pipeline/web tests and pinned optimizer npm tests. Build both images,
   run a generated synthetic scan through upload/status/download, then push those images.
4. Run the processing service as appuser under one Gunicorn process so its in-process job
   queue has a single owner. Use durable upload/output volumes and bounded workers.
5. Deploy a dedicated Portainer Stack with the existing proxy network and TLS resolver;
   keep the compatible optimizer only on the Stack's internal backend network.
6. Credentials: the user configured two organization Secrets for public repositories;
   read-only GitHub API confirms this public repository can access both. Use inherited
   organization Secrets. No stored credential transfer or disclosure is needed.
7. Push develop and verify all CI, then promote remote main and publish in isolated Git
   state without rewriting branches. Deploy the verified publish images in Portainer.
8. Verify Stack health, HTTPS domain, and a synthetic processing/download through the
   browser. Keep screenshot evidence and report any unverified external requirement.
