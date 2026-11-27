# Kopia replication (out-of-cluster repos)

Cluster data is backed up by kopiur, not by jobs here:

| What | Repo | Replicas | Defined in |
|---|---|---|---|
| Longhorn PVCs | `kopia-main` (syno-nuss-roy) | Backblaze, syno-coeuve | `infra/kopiur/`, `<namespace>/kopiur.yaml` |
| NAS folders (seafile, s3, music) | `kopia-nas` (Backblaze) | syno-coeuve | `infra/kopiur/`, `<namespace>/kopiur.yaml` |
| immich | `immich-backup` (Backblaze) | syno-coeuve | `workloads/appl-n8r/immich/kopiur.yaml` |

This namespace only keeps plain `kopia repository sync-to` CronJobs for repos
written from outside the cluster (laptops).

## Jobs

| Job | Schedule | Source | Destination |
|---|---|---|---|
| `kopia-sync-fw-laptop` | daily 03:00 | syno-nuss-roy (WebDAV) | syno-coeuve (WebDAV) |
| `kopia-verify-fw-laptop` | Sun 04:00 | — | syno-coeuve |

## Secrets

| ExternalSecret | OpenBao path | Keys |
|---|---|---|
| `webdav-syno-nuss-roy` | `k8s/appl-kopia-repl/webdav-syno-nuss-roy` | `KOPIA_WEBDAV_URL`, `KOPIA_WEBDAV_USER`, `KOPIA_WEBDAV_PASS` |
| `webdav-syno-coeuve` | `k8s/appl-kopia-repl/webdav-syno-coeuve` | same three |
| `backblaze-s3` | `k8s/appl-kopia-repl/backblaze-s3` | `KOPIA_S3_BUCKET`, `KOPIA_S3_ENDPOINT`, `KOPIA_S3_ACCESS_KEY`, `KOPIA_S3_SECRET_KEY` |
| `kopia-repl-fw-laptop` | `k8s/appl-kopia-repl/fw-laptop` | `KOPIA_REPO_PATH`, `KOPIA_PASSWORD` |

The endpoint paths are the single source of truth per endpoint; kopiur's
ExternalSecrets (`appl-kopiur`, `appl-n8r`) read the same paths.

## How to add a replicated repo

Use this when the repo already exists on the source NAS and you want a mirror
at the destination. The job has no in-cluster data dependency.

1. **Pre-create the destination folder** on syno-coeuve (Synology WebDAV
   returns 409 if the parent dir doesn't exist):
   ```bash
   # On syno-coeuve via SSH or File Station
   mkdir -p /volume1/backup/<repo-name>
   ```

2. **Write the per-repo secret to OpenBao:**
   ```bash
   bao kv put secret/k8s/appl-kopia-repl/<repo-name> \
     KOPIA_REPO_PATH="<repo-name>" \
     KOPIA_PASSWORD="<repo-password>"
   ```

3. **Copy `fw-laptop-externalsecret.yaml`** → `<repo-name>-externalsecret.yaml`.
   Change `metadata.name`, `target.name` to `kopia-repl-<repo-name>`, and
   `extract.key` to `k8s/appl-kopia-repl/<repo-name>`.

4. **Copy `fw-laptop.yaml`** → `<repo-name>.yaml`. Change `fw-laptop` →
   `<repo-name>` in:
   - Both CronJob `metadata.name` fields (`kopia-sync-<repo-name>`,
     `kopia-verify-<repo-name>`)
   - Both `envFrom.secretRef.name` fields (`kopia-repl-<repo-name>`)

   No other changes — the endpoint `secretKeyRef`s stay the same.

5. **Commit & test:**
   ```bash
   kubectl -n appl-kopia-repl create job --from=cronjob/kopia-sync-<repo-name> manual-1
   kubectl -n appl-kopia-repl logs job/manual-1 -f
   ```

## Gotchas

- **Synology WebDAV + `sync-to` on first run:** the destination folder must
  exist before the sync. Synology returns 409 Conflict if you PUT into a
  non-existent collection. Pre-create the folder via File Station or SSH.
- **`--times` doesn't work on Synology WebDAV:** it doesn't support PROPPATCH
  for modification times. Don't pass `--times` to `sync-to`.
- **Bool flags:** Kopia uses `--flag` / `--no-flag`, not `--flag=true` /
  `--flag=false`. The latter causes "unexpected true" errors.
- **`set -euo pipefail` doesn't work in the kopia image:** it's Alpine/ash, not
  bash. Use `set -eu` instead.
- **Memory:** Kopia loads the full index into RAM when connecting. 512Mi was
  not enough even for a tiny repo; all jobs use 1Gi (verify) or 2Gi (backup).
- **Stale maintenance blobs:** `ignoring BLOB not found: kopia.maintenance_*`
  messages during `sync-to` are benign — they're stale references from
  compaction, not errors.
- **Independent backup vs. replication:** replication (`sync-to --delete`)
  mirrors corruption too. For in-cluster data, a second independent backup
  is safer — two repos with no shared failure mode.
- **Synology WebDAV 500 on writes (DavLockDB permissions):** the root cause
  of persistent 500 errors on PUT/MKCOL is the `DavLockDB` directory not being
  writable by all httpd workers. The WebDAV Server package runs httpd workers
  as multiple users (root + the WebDAV user), but the lock database directory
  at `/var/packages/WebDAVServer/target/var/run/httpd/` is `drwxr-xr-x root:root`
  — only root can write. Non-root workers get "Permission denied" on the lock
  database, causing every DAV write to fail with 500. Fix:
  ```bash
  sudo chmod 777 /var/packages/WebDAVServer/target/var/run/httpd/
  sudo chmod 666 /var/packages/WebDAVServer/target/var/run/httpd/DavLock.*
  sudo synopkg restart WebDAVServer  # or Package Center → Stop → Start
  ```
  This is a known Apache mod_dav issue (not Synology-specific), but Synology's
  package doesn't set the permissions correctly out of the box. The fix may
  not survive a DSM update or package reinstall — re-apply if 500s return.
  See https://serverfault.com/questions/320480 for background.
- **Synology WebDAV 500 on writes (transient):** if the 500s appear suddenly
  after previously working, the WebDAV Server daemon may be in a bad state.
  Restart it (Package Center → WebDAV Server → Stop → Start, or
  `synopkg restart WebDAVServer` via SSH). If that doesn't help, check the
  DavLockDB permissions above.
