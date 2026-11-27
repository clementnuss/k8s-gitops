# kopiur backups

| What | Repo (`infra/kopiur/`) | Replicas | Policies |
|---|---|---|---|
| Longhorn PVCs | `kopia-main` (syno-nuss-roy) | Backblaze, syno-coeuve | `kopia-main` in `<namespace>/kopiur.yaml` |
| NAS folders (seafile, s3, music) | `kopia-nas` (Backblaze) | syno-coeuve | `kopia-nas` in `appl-seafile/`, `appl-s3/`, `appl-n8r/kopiur.yaml` |
| immich | `immich-backup` (Backblaze, own repo) | syno-coeuve | `appl-n8r/immich/kopiur.yaml` |

kopiur refuses cross-namespace PVC selectors (a mover can only mount PVCs in
its own namespace), so every namespace carries its own identical
`kopiur.yaml`. Some live in the private-k8s-workloads repo (ajoverts,
composteuse, ferme-roy, zaco).

## Adding a namespace

1. Copy any `workloads/appl-*/kopiur.yaml`, change the two `namespace:` fields.
2. Annotate the namespace with
   `kopiur.home-operations.com/privileged-movers: "true"`: movers run as
   root with `DAC_OVERRIDE` (read-only), which baseline Pod Security admits.

## Skipping a PVC

Label it `backup.n8r.ch/skip: "true"` (bjw-s app-template: `persistence.<name>.labels`).
StatefulSet `volumeClaimTemplates` labels are immutable: for those, add a
selector expression in that namespace's `kopiur.yaml` instead.

## Later

- **rustdesk** (`appl-rustdesk`): not backed up. It runs on the edge node
  (OCI VPS, no CNI, hostNetwork only), where a regular mover pod can't run.
  The PVC should hold the server keypair: losing it means re-keying clients.
- **fw-laptop sync** (`appl-kopia-repl`): still a hand-written
  `kopia repository sync-to` CronJob. Could become a kopiur
  `RepositoryReplication` once the laptop repo is a `ClusterRepository`.
- **Restore test**: no kopiur restore has been exercised yet.
- **Postgres**: check the CNPG barman backup of `appl-postgres` is complete.
- **Velero**: schedules are gone; remove `infra/velero/`, the
  `backup.velero.io/backup-volumes` annotations, renovate rules, and the
  `velero-planchettes` buckets.
- **Old kopia repos**: delete the legacy immich repo (Backblaze) and the
  paperless repos (both NASes) once kopiur history is long enough.
