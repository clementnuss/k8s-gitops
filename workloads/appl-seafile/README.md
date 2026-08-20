# Seafile (appl-seafile)

Seafile Pro (≤3 users = free). Single container. MariaDB external (shared
`appl-mariadb`). Auth via Pocket ID (native OAuth2, no oauth2-proxy).

## Storage

| Path | Volume | Purpose |
|------|--------|---------|
| `/shared/seafile` | `seafile-data-nfs` (NFS) | conf, ccnet, seafile-data, seahub-data, pro-data |
| `/shared/seafile/logs` | `emptyDir` | logs — ephemeral, gone on pod restart |

Entire `/shared/seafile` tree lives on the NAS (`/volume1/nfs-share/seafile/`).
Logs shadowed with `emptyDir`. `SEAFILE_LOG_TO_STDOUT=true` sends important
logs to stdout for `kubectl logs` / Vector.

NFS PV/PVC declared in `seafile-data-pvc.yaml` (server `192.168.63.10`,
`nfsvers=3`, `hard`, `noac`, `lookupcache=none`).

## Authentication

Single flow for both web and devices: Seafile speaks OAuth2/OIDC directly to
Pocket ID (`id.n8r.ch`). No oauth2-proxy, no forwardAuth, no ingress split.

```
browser/SeaDrive → https://drive.n8r.ch/oauth/
                 → id.n8r.ch (Pocket ID)
                 → /oauth/callback/
                 → Seafile issues API token
```

Pocket ID handles user allowlisting (allowed groups), so no
`authenticated-emails-file` or similar on the Seafile side.

### Pocket ID client setup

In Pocket ID (`id.n8r.ch`), create an OIDC client:
- **Name**: Seafile
- **Launch URL**: `https://drive.n8r.ch`
- **Callback URL**: `https://drive.n8r.ch/oauth/callback/`

Copy the Client ID and Client Secret into OpenBao at
`k8s/appl-seafile/seafile-secret` as `SEAFILE_OAUTH_CLIENT_ID` and
`SEAFILE_OAUTH_CLIENT_SECRET`. The ExternalSecret in `seafile-secret.yaml`
syncs them into the `seafile-secret` Kubernetes Secret, and `envFrom`
injects them into the container.

## Post-boot setup

After first successful boot (admin init, schema created), do once:

### 1. Clean up init-only settings

- Remove `INIT_SEAFILE_ADMIN_EMAIL` env var from `seafile.yaml`
- Remove `INIT_SEAFILE_ADMIN_PASSWORD` from OpenBao

### 2. Append OAuth2 config to `seahub_settings.py`

```sh
kubectl -n appl-seafile exec -it deploy/seafile -- sh -c 'cat >> /shared/seafile/conf/seahub_settings.py' <<'PY'
import os

SECRET_KEY = os.environ['SEAFILE_SECRET_KEY']

ENABLE_SUDO_MODE = False
LANGUAGE_CODE = 'fr'

ENABLE_OAUTH = True
OAUTH_CREATE_UNKNOWN_USER = True
OAUTH_ACTIVATE_USER_AFTER_CREATION = True
OAUTH_ENABLE_INSECURE_TRANSPORT = False

OAUTH_CLIENT_ID = os.environ['SEAFILE_OAUTH_CLIENT_ID']
OAUTH_CLIENT_SECRET = os.environ['SEAFILE_OAUTH_CLIENT_SECRET']
OAUTH_REDIRECT_URL = 'https://drive.n8r.ch/oauth/callback/'

OAUTH_PROVIDER = 'pocket-id'
OAUTH_PROVIDER_DOMAIN = 'pocket-id'
OAUTH_AUTHORIZATION_URL = 'https://id.n8r.ch/authorize'
OAUTH_TOKEN_URL = 'https://id.n8r.ch/api/oidc/token'
OAUTH_USER_INFO_URL = 'https://id.n8r.ch/api/oidc/userinfo'
OAUTH_SCOPE = ['openid', 'profile', 'email']

OAUTH_ATTRIBUTE_MAP = {
    'sub': (True, 'uid'),
    'name': (False, 'name'),
    'email': (False, 'contact_email'),
}

CLIENT_SSO_VIA_LOCAL_BROWSER = True
PY
```

> **SECRET_KEY**: the seafile-pro-mc image auto-generates a `SECRET_KEY`
> line on first boot. Comment it out so the env-based one above takes
> effect:
> ```sh
> kubectl -n appl-seafile exec deploy/seafile -- \
>   sed -i 's/^SECRET_KEY = /# SECRET_KEY = /' /shared/seafile/conf/seahub_settings.py
> ```
> `SEAFILE_SECRET_KEY` lives in OpenBao at `k8s/appl-seafile/seafile-secret`,
> synced via the existing ExternalSecret's `dataFrom` (no manifest change).
> Preserve the original value when moving it, or all sessions are invalidated.

> **Endpoint URLs**: verify the authorization, token, and userinfo endpoints
> in the Pocket ID client's "OIDC Data" section. The URLs above are the
> standard Pocket ID v2 paths; adjust if your instance differs.

### 3. Restart Seafile

```sh
kubectl -n appl-seafile rollout restart deploy/seafile
```

### 4. Verify

- Open `https://drive.n8r.ch` → redirected to Pocket ID → back → logged in.
- In SeaDrive, add server `https://drive.n8r.ch`, sign in → browser opens →
  Pocket ID → back → SeaDrive gets a token and syncs.

## NFS migration

Move `/shared/seafile` from Longhorn to NFS (logs excluded via emptyDir):

```sh
kubectl -n appl-seafile scale deploy/seafile --replicas=0

kubectl -n appl-seafile run seafile-data-migrate --rm -i \
  --restart=Never --image=alpine:3.20 \
  --overrides='{
    "spec": {
      "securityContext": {"seccompProfile": {"type": "RuntimeDefault"}},
      "containers": [{
        "name": "migrate",
        "image": "alpine:3.20",
        "command": ["sh", "-c", "apk add --no-cache rsync && rsync -aH --numeric-ids --delete --exclude=logs /src/seafile/ /dst/ && echo done"],
        "securityContext": {
          "runAsUser": 0, "runAsGroup": 0,
          "allowPrivilegeEscalation": false,
          "capabilities": {"drop": ["ALL"]},
          "seccompProfile": {"type": "RuntimeDefault"}
        },
        "volumeMounts": [
          {"name": "src", "mountPath": "/src", "readOnly": true},
          {"name": "dst", "mountPath": "/dst"}
        ]
      }],
      "volumes": [
        {"name": "src", "persistentVolumeClaim": {"claimName": "seafile-shared"}},
        {"name": "dst", "persistentVolumeClaim": {"claimName": "seafile-data-nfs"}}
      ]
    }
  }'

kubectl -n appl-seafile scale deploy/seafile --replicas=1
```

The `seafile-shared` Longhorn PVC remains as a frozen backup; delete it once
NFS is confirmed working.

## SeaSearch (full-text search)

SeaSearch (`seafileltd/seasearch:1.0-latest`) is a lightweight file content
indexer, replacing Elasticsearch. Deployed as a standalone Deployment + Service
(`seasearch.yaml`) on port 4080, with a 20Gi Longhorn PVC at `/data`.

The `seasearch_token` in `seafevents.conf` is injected at boot by an init
container (`init-seasearch` in `seafile.yaml`) that base64-encodes
`SEASEARCH_ADMIN_USER:SEASEARCH_ADMIN_PASSWORD` from the `seafile-secret` and
`sed`-replaces the placeholder. The token never lives in the config file on disk.

### Setup

1. Add `SEASEARCH_ADMIN_USER` and `SEASEARCH_ADMIN_PASSWORD` to OpenBao at
   `k8s/appl-seafile/seafile-secret`.

2. Let Flux sync `seasearch.yaml` (Deployment + Service + PVC).

3. Append to `/shared/seafile/conf/seafevents.conf`:

```sh
kubectl -n appl-seafile exec -it deploy/seafile -- sh -c 'cat >> /shared/seafile/conf/seafevents.conf' <<'EOF'
[SEASEARCH]
enabled = true
seasearch_url = http://seasearch.appl-seafile.svc.cluster.local:4080
seasearch_token = placeholder
interval = 10m
index_office_pdf = true

[INDEX FILES]
enabled = false
EOF
```

4. Restart Seafile:

```sh
kubectl -n appl-seafile rollout restart deploy/seafile
```

5. Verify: upload a file, wait ~10m, search for its content in the web UI.

### Notes

- `SS_FIRST_ADMIN_USER` / `SS_FIRST_ADMIN_PASSWORD` (init env vars in
  `seasearch.yaml`) are only needed on first boot. Remove them after the
  admin account is created.
- `index_office_pdf = true` enables full-text indexing of Office/PDF content
  (Pro 13.0 feature).
- Redis is used as the cache (no memcached needed). The `WARNING:root:Memcached
  has not been set up` in the logs is harmless.

## OnlyOffice (online document editing)

OnlyOffice Document Server (`onlyoffice/documentserver:8.1.0`) for
viewing/editing Office files in the browser. Deployed as a standalone
Deployment + Service + Ingress (`onlyoffice.yaml`), exposed at
`https://office.n8r.ch/`. Separate hostname because OnlyOffice's internal
nginx serves from `/` and doesn't support subpath deployment cleanly.

JWT-secured (shared secret between Seafile and OnlyOffice). The
`ONLYOFFICE_JWT_SECRET` env var is injected from the `seafile-secret`
Kubernetes Secret, synced from OpenBao via the existing ExternalSecret.

### Setup

1. Add `ONLYOFFICE_JWT_SECRET` to OpenBao at `k8s/appl-seafile/seafile-secret`
   (`pwgen -s 40 1`).

2. Add a DNS record for `office.n8r.ch` (if not using a wildcard CNAME).

3. Let Flux sync `onlyoffice.yaml`.

4. Verify OnlyOffice is running: `https://office.n8r.ch/welcome`
   should show "Document Server is running".

5. Append to `seahub_settings.py`:

```sh
kubectl -n appl-seafile exec -it deploy/seafile -- sh -c 'cat >> /shared/seafile/conf/seahub_settings.py' <<'PY'
ENABLE_ONLYOFFICE = True
ONLYOFFICE_APIJS_URL = 'https://office.n8r.ch/web-apps/apps/api/documents/api.js'
ONLYOFFICE_JWT_SECRET = os.environ['ONLYOFFICE_JWT_SECRET']
PY
```

6. Restart Seafile:

```sh
kubectl -n appl-seafile rollout restart deploy/seafile
```

7. Verify: open a `.docx` file in the Seafile web UI → should open the
   OnlyOffice editor inline.

## Files

| File | Purpose |
|------|---------|
| `ns.yaml` | Namespace |
| `seafile.yaml` | HelmRelease (with init-seasearch container) |
| `seafile-secret.yaml` | ExternalSecret |
| `seafile-data-pvc.yaml` | Longhorn PVC (frozen) + NFS PV/PVC |
| `redis.yaml` | Internal Redis |
| `seasearch.yaml` | SeaSearch Deployment + Service + PVC |
| `onlyoffice.yaml` | OnlyOffice Deployment + Service + PVC + Ingress (office.n8r.ch) |