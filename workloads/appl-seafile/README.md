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

## Files

| File | Purpose |
|------|---------|
| `ns.yaml` | Namespace |
| `seafile.yaml` | HelmRelease |
| `seafile-secret.yaml` | ExternalSecret |
| `seafile-data-pvc.yaml` | Longhorn PVC (frozen) + NFS PV/PVC |
| `redis.yaml` | Internal Redis |