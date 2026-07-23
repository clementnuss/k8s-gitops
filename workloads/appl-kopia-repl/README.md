# Kopia backup & replication

Two kinds of Kopia jobs live in this repo, split by namespace according to
whether they need in-cluster data.

## Architecture

```
appl-kopia-repl/        Replication jobs (sync-to, no in-cluster data)
appl-n8r/immich/        App backup jobs (snapshot create, need the app's PVC)
appl-n8r/paperless-ngx/ (existing) app backup to WebDAV
```

### Why the split

- **Replication** (`kopia repository sync-to`) is pure WebDAV→WebDAV. It has
  no coupling to any app namespace, so it lives in `appl-kopia-repl` where the
  two endpoint secrets (`webdav-syno-nuss-roy`, `webdav-syno-coeuve`) are
  defined once and shared by all replication jobs.
- **App backups** (`kopia snapshot create`) need the app's data, usually via a
  PVC mount or `kubectl exec`. PVCs can't be mounted cross-namespace, so these
  jobs live in the app's own namespace next to the data they back up.

The `openbao` ClusterSecretStore is cluster-scoped, so an ExternalSecret in any
namespace can read from the same OpenBao paths.

## Secrets

### Endpoint secrets (shared, in `appl-kopia-repl`)

| ExternalSecret | Namespace | OpenBao path | Keys |
|---|---|---|---|
| `webdav-syno-nuss-roy` | appl-kopia-repl | `k8s/appl-kopia-repl/webdav-syno-nuss-roy` | `KOPIA_WEBDAV_URL`, `KOPIA_WEBDAV_USER`, `KOPIA_WEBDAV_PASS` |
| `webdav-syno-coeuve` | appl-kopia-repl | `k8s/appl-kopia-repl/webdav-syno-coeuve` | same three |
| `backblaze-s3` | appl-kopia-repl | `k8s/appl-kopia-repl/backblaze-s3` | `KOPIA_S3_BUCKET`, `KOPIA_S3_ENDPOINT`, `KOPIA_S3_ACCESS_KEY`, `KOPIA_S3_SECRET_KEY` |
| `webdav-syno-nuss-roy` | appl-n8r | `k8s/appl-kopia-repl/webdav-syno-nuss-roy` (same path) | same three |
| `webdav-syno-coeuve` | appl-n8r | `k8s/appl-kopia-repl/webdav-syno-coeuve` (same path) | same three |
| `backblaze-s3` | appl-n8r | `k8s/appl-kopia-repl/backblaze-s3` (same path) | same four |

These hold the transport-level credentials for each storage endpoint (two
Synology NASes over WebDAV, one Backblaze B2 bucket over S3). The OpenBao path
is the same regardless of namespace — both `appl-kopia-repl` and `appl-n8r`
sync from `k8s/appl-kopia-repl/<endpoint>`, so there is a single source of
truth per endpoint. Jobs map them into `KOPIA_*` env vars via `secretKeyRef`
(not `envFrom`, because endpoint secrets use distinct key names that are
mapped explicitly).

### Per-repo secrets

Each repo has its own ExternalSecret with `KOPIA_REPO_PATH` (the subpath under
the WebDAV base URL) and `KOPIA_PASSWORD` (the repo password). These use
`envFrom` since the key names are unique.

| ExternalSecret | Namespace | OpenBao path | Keys |
|---|---|---|---|
| `kopia-repl-fw-laptop` | appl-kopia-repl | `k8s/appl-kopia-repl/fw-laptop` | `KOPIA_REPO_PATH`, `KOPIA_PASSWORD` |
| `paperless-kopia` | appl-n8r | `k8s/appl-n8r/paperless-ngx/kopia` | `KOPIA_REPO_PATH`, `KOPIA_PASSWORD` |
| `immich-kopia` | appl-n8r | `k8s/appl-n8r/immich/kopia` | `KOPIA_REPO_PATH`, `KOPIA_PASSWORD` |

App namespaces only own "which repo" (path + password). The endpoint creds
live in `appl-kopia-repl`'s OpenBao paths and are synced into each app
namespace via ExternalSecrets pointing at those same paths. When the same
kopia parameters (path + password) are used on both NASes, a single per-repo
secret is shared by both backup jobs — only the endpoint secret differs.

## Jobs

| Job | Namespace | Type | Schedule | Source | Destination |
|---|---|---|---|---|---|
| `kopia-sync-fw-laptop` | appl-kopia-repl | Replication | daily 03:00 | syno-nuss-roy (WebDAV) | syno-coeuve (WebDAV) |
| `kopia-verify-fw-laptop` | appl-kopia-repl | Verify | Sun 04:00 | — | syno-coeuve |
| `paperless-backup-nuss-roy` | appl-n8r | Independent backup | daily 02:30 | paperless-ngx-export PVC | syno-nuss-roy (WebDAV) |
| `paperless-verify-nuss-roy` | appl-n8r | Verify | Sun 04:30 | — | syno-nuss-roy |
| `paperless-backup-coeuve` | appl-n8r | Independent backup | daily 03:00 | paperless-ngx-export PVC | syno-coeuve (WebDAV) |
| `paperless-verify-coeuve` | appl-n8r | Verify | Sun 04:00 | — | syno-coeuve |
| `immich-backup-s3` | appl-n8r | Independent backup | daily 03:00 | immich-library PVC | Backblaze B2 (S3) |
| `immich-backup-coeuve` | appl-n8r | Independent backup | daily 03:30 | immich-library PVC | syno-coeuve (WebDAV) |
| `immich-verify-coeuve` | appl-n8r | Verify | Sun 04:00 | — | syno-coeuve |

Schedules are staggered to avoid overlapping `document_exporter --delete` runs
(paperless jobs share one export PVC) and to keep backup/verify windows apart.
`concurrencyPolicy: Forbid` only guards within a single CronJob.

## How to add a new repo

### Pattern A: Replicate an existing repo (sync-to)

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

### Pattern B: Back up in-cluster data to a new repo (snapshot create)

Use this when the data lives in the cluster (a PVC) and you want an independent
second backup at the destination. The job lives in the app's namespace so it
can mount the PVC directly.

1. **Pre-create the destination folder** on the target NAS:
   ```bash
   mkdir -p /volume1/backup/<repo-name>
   ```

2. **Write the per-repo secret to OpenBao** (path + password only — endpoint
   creds are shared, not per-repo):
   ```bash
   bao kv put secret/k8s/<namespace>/<app>/kopia-<endpoint> \
     KOPIA_REPO_PATH="<repo-name>" \
     KOPIA_PASSWORD="<new-repo-password>"
   ```

3. **Ensure the target endpoint is synced into the app's namespace.** If the
   app's namespace doesn't already have a `webdav-syno-<endpoint>` ExternalSecret,
   copy `appl-n8r/webdav-syno-coeuve.yaml` (or `-nuss-roy.yaml`) into the
   namespace's top-level directory. These point at the same OpenBao path as
   `appl-kopia-repl`, so no new OpenBao secret is needed.

4. **Copy `appl-n8r/immich/backup-coeuve-externalsecret.yaml`** into the app's
   directory. Update `metadata.name`, `target.name`, `namespace`, and
   `extract.key` to match the app.

5. **Copy `appl-n8r/immich/backup-coeuve.yaml`** into the app's directory.
   Update:
   - Both CronJob `metadata.name` and `namespace`
   - `envFrom.secretRef.name` to match the per-repo ExternalSecret
   - The `env.secretKeyRef.name` entries to point at the shared endpoint
     secret (`webdav-syno-coeuve` or `webdav-syno-nuss-roy`)
   - The `volumes.data.persistentVolumeClaim.claimName` to the app's PVC
   - `--override-username` / `--override-hostname` if you care about
     per-host labeling in Kopia

6. **Commit & test:**
   ```bash
   kubectl -n <namespace> create job --from=cronjob/<job-name> manual-1
   kubectl -n <namespace> logs job/manual-1 -f
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
  (Pattern B) is safer — two repos with no shared failure mode.
- **Synology WebDAV 500 on writes:** if `kopia repository create` or
  `snapshot create` fails with HTTP 500 on PUT requests, the WebDAV Server
  package on the NAS may be in a bad state. Restart it (Package Center →
  WebDAV Server → Stop → Start, or `synoservicectl --restart pkgctl-WebDAVServer`
  via SSH). This is a Synology issue, not a Kopia or network issue.