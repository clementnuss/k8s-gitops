# OpenBao

OpenBao deployed in standalone mode on the `planchettes63` cluster.

- **Namespace**: `appl-openbao`
- **Mode**: standalone (single replica, file storage backend)
- **Storage**: 10Gi PVC on `longhorn-3-replicas` (replicated + backed up)
- **UI**: <https://openbao.n8r.ch> (traefik ingress, oauth2-proxy middleware, letsencrypt-prod cert)
- **Chart**: `openbao/openbao` v0.28.4, app `openbao:2.5.5`

## Auto-unseal

OpenBao starts sealed after every pod restart. We auto-unseal it with a
`postStart` lifecycle hook that reads a single unseal key from a manually
created Kubernetes Secret.

The Secret `openbao-unseal-key` is **not** committed to this repository. It
is created once, manually, after the first initialization (see below). The
hook tolerates the Secret being absent (the volume is marked `optional:
true`), so the very first boot — before initialization — proceeds without
error. It uses `bao status`'s exit code (0 = unsealed, 2 = sealed) to detect
the seal state, and `cat` to read the key file - `bao operator unseal`
handles the trailing newline from `jq -r` / `kubectl create secret
--from-file` fine.

### Threat model

The unseal key lives in-cluster as a Kubernetes Secret. Mitigations already
in place on this cluster:

- **etcd encryption at rest** with the `secretbox` algorithm (AES-GCM).
- **LUKS** full-disk encryption on the node SSDs.
- **Network exposure** is limited to the traefik ingress behind the
  `appl-n8r-oauth2-n8r` oauth2-proxy middleware.

The root token is never stored in the cluster. Keep it in Bitwarden only.

## First-time setup

These steps are run from your laptop. They handle raw key material — run
them yourself, never pipe them through an AI tool.

```bash
# 0. Install the bao CLI if you don't have it:
#    https://openbao.org/downloads/

# 1. Port-forward to the pod (openbao-0 must be Running, but will be
#    sealed/uninitialized — that's expected).
kubectl -n appl-openbao port-forward pod/openbao-0 8200:8200 &

# 2. Initialize with a single unseal key (KISS).
#    Save the root token to Bitwarden immediately after this step.
export BAO_ADDR=http://127.0.0.1:8200
bao operator init -key-shares=1 -key-threshold=1 -format=json > /tmp/openbao-init.json

# 3. Unseal the first time using jq to extract the key.
bao operator unseal "$(jq -r '.unseal_keys_b64[0]' /tmp/openbao-init.json)"

# 4. Create the in-cluster Secret so future restarts auto-unseal.
#    --from-file reads the key straight from jq output into the Secret data;
#    the key never passes through echo/cat.
jq -r '.unseal_keys_b64[0]' /tmp/openbao-init.json > /tmp/openbao-unseal-key
kubectl -n appl-openbao create secret generic openbao-unseal-key \
  --from-file=key=/tmp/openbao-unseal-key
shred -u /tmp/openbao-unseal-key

# 5. Save the root token to Bitwarden, then shred the init file.
#    (e.g. rbw add 'openbao root token' and paste the token)
shred -u /tmp/openbao-init.json
```

After step 4, any pod restart (node reboot, upgrade, reschedule) will
auto-unseal. Verify:

```bash
kubectl -n appl-openbao delete pod openbao-0
kubectl -n appl-openbao get pod -w   # should come back to 1/1 Ready
```

## Key rotation

Two kinds of keys to keep in mind.

### Master key / unseal keys

`bao operator rotate` rotates the master key and produces a **new** set of
unseal keys. The old keys stop working immediately. Data is re-encrypted
transparently — no downtime, reads/writes continue.

After rotation, update the in-cluster Secret so the postStart hook can
still auto-unseal:

```bash
export BAO_ADDR=http://127.0.0.1:8200   # port-forward as above
bao operator rotate -format=json > /tmp/openbao-rotate.json
bao operator unseal "$(jq -r '.unseal_keys_b64[0]' /tmp/openbao-rotate.json)"

# Update the Secret with a new key.
jq -r '.unseal_keys_b64[0]' /tmp/openbao-rotate.json > /tmp/openbao-unseal-key
kubectl -n appl-openbao delete secret openbao-unseal-key
kubectl -n appl-openbao create secret generic openbao-unseal-key \
  --from-file=key=/tmp/openbao-unseal-key
shred -u /tmp/openbao-unseal-key

# Store the new unseal keys in Bitwarden, then shred the local copy.
shred -u /tmp/openbao-rotate.json
```

### Root token

The root token is not rotated by `bao operator rotate`. To rotate it,
create a new root token and revoke the old one:

```bash
bao token create -policy=root           # copy new token to Bitwarden
bao token revoke <old-root-token>       # revoke the previous one
```

Worth doing periodically or after any suspected compromise.

### Secret-engine keys (e.g. transit)

Only relevant once you start using the transit secret engine. Rotate a
transit key with:

```bash
bao write -force transit/keys/<key-name>/rotate
```

Old ciphertext remains decryptable via key versions; new writes use the
latest version.

## Login via Dex (OIDC)

OpenBao uses Dex as its OIDC identity provider for human login. Dex
federates Google (the only upstream connector) and already fronts
oauth2-proxy and the other apps on the cluster. OpenBao becomes another
Dex static client - no new upstream IdP wiring needed.

Access control is handled at two layers:
1. **Dex** - the static client config determines which redirect URIs are
   allowed. Dex itself doesn't restrict *who* can log in (that's the
   connector's job + the client app's job).
2. **OpenBao** - the OIDC auth method **role** restricts which users can
   authenticate via `bound_claims` (a map of JWT claim -> required value(s))
   and which **policies** they get. This is equivalent to oauth2-proxy's
   `allowed-emails-file`.

### One-time configuration

These steps assume OpenBao is initialized, unsealed, and you have the root
token. Run them via port-forward from your laptop.

**Note**: these steps are also handled by the OpenTofu config in
`setup/openbao-tf/`. If you apply that, you can skip this section entirely.
The manual commands below are for reference or if you prefer not to use
OpenTofu.

```bash
# 1. Generate a client secret for OpenBao in Dex.
#    Store it in Bitwarden, then add the static client to the dex-secrets
#    Secret (see "Dex static client" section below).
CLIENT_SECRET=$(openssl rand -hex 24)
echo "$CLIENT_SECRET"   # copy to Bitwarden as 'openbao dex client secret'

# 2. Port-forward to OpenBao and log in with the root token.
kubectl -n appl-openbao port-forward pod/openbao-0 8200:8200 &
export BAO_ADDR=http://127.0.0.1:8200
bao login <root-token>

# 3. Enable the OIDC auth method at path "dex".
#    The path determines the UI callback URL: /ui/vault/auth/dex/oidc/callback
bao auth enable -path=dex oidc

# 4. Configure the OIDC auth method to point at Dex.
#    oidc_discovery_url is the ISSUER URL, NOT the full discovery path.
#    OpenBao appends /.well-known/openid-configuration itself.
bao write auth/dex/config \
  oidc_discovery_url="https://dex.n8r.ch" \
  oidc_client_id="openbao" \
  oidc_client_secret="$CLIENT_SECRET" \
  default_role="admin"

# 5. Make the auth method visible on the login screen for unauthenticated
#    users (so they can pick "Dex" from the dropdown without knowing the path).
bao write auth/dex/tune listing_visibility=unauth

# 6. Create the admin role.
#    - allowed_redirect_uris is a comma-separated string (not repeated flags).
#    - bound_claims restricts who can log in. Here only your Google email
#      is allowed. Add more emails to the list to grant more users access.
#    - token_policies (not "policies", which is deprecated) grants the
#      admin policy to successful logins.
#    - The CLI callback is http://localhost:8250/oidc/callback (default port).
#    - The UI callback is https://openbao.n8r.ch/ui/vault/auth/dex/oidc/callback
#      (path format: /ui/vault/auth/<mount-path>/oidc/callback).
bao write auth/dex/role/admin \
  user_claim="email" \
  allowed_redirect_uris="http://localhost:8250/oidc/callback,https://openbao.n8r.ch/ui/vault/auth/dex/oidc/callback" \
  oidc_scopes="openid,profile,email,groups" \
  bound_claims='{"email":["you@gmail.com"]}' \
  token_policies="admin"
```

### Dex static client

Add this to the `staticClients` list in the `dex-secrets` Secret (under
`config.staticClients`). The `id` must match the `oidc_client_id` passed
to OpenBao, and the `secret` must match `oidc_client_secret`:

```yaml
- id: openbao
  name: OpenBao
  secret: "<the CLIENT_SECRET you generated>"
  redirectURIs:
    - https://openbao.n8r.ch/ui/vault/auth/dex/oidc/callback
    - http://localhost:8250/oidc/callback
```

After editing, re-create the Secret and restart Dex:

```bash
kubectl -n appl-n8r rollout restart deployment/dex
```

### Admin policy

Create a policy that grants full access (equivalent to root, but
revocable and tied to the OIDC role):

```bash
cat <<'EOF' | bao policy write admin -
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
EOF
```

### Day-to-day login

**Browser (UI):**
Visit <https://openbao.n8r.ch> -> the login screen shows "Dex" in the
method dropdown (thanks to `listing_visibility=unauth`) -> select it ->
redirected to Dex -> Google -> back to OpenBao UI, authenticated.

**CLI (laptop):**
```bash
export BAO_ADDR=https://openbao.n8r.ch
bao login -method=oidc -path=dex   # opens browser, Dex/Google flow, done
bao kv get secret/foo              # authenticated
```

The token is cached in `~/.openbao-token` (or your token helper). No
root token needed for daily use - keep the root token in Bitwarden as a
break-glass option only.

### Adding another user

To let someone else log in via Dex/Google, add their email to the
`bound_claims` list:

```bash
bao write auth/dex/role/admin \
  user_claim="email" \
  allowed_redirect_uris="http://localhost:8250/oidc/callback,https://openbao.n8r.ch/ui/vault/auth/dex/oidc/callback" \
  oidc_scopes="openid,profile,email,groups" \
  bound_claims='{"email":["you@gmail.com","friend@gmail.com"]}' \
  token_policies="admin"
```

For finer-grained access, create a separate role with a restricted policy
(e.g. read-only) and point new users at that role.

### Troubleshooting

- **`oidc_discovery_url` errors**: pass the issuer URL only
  (`https://dex.n8r.ch`), NOT the full
  `https://dex.n8r.ch/.well-known/openid-configuration` path. OpenBao
  appends `/.well-known/openid-configuration` itself.
- **Redirect URI mismatches**: the redirect URIs in OpenBao's role and in
  Dex's static client must match exactly (http vs https, host, port,
  trailing slash). The CLI uses `http://localhost:8250/oidc/callback` by
  default; the UI uses `https://openbao.n8r.ch/ui/vault/auth/dex/oidc/callback`.
- **`bound_claims` with CLI**: if `bao write` chokes on the JSON map for
  `bound_claims`, write the whole role as a single JSON object via stdin:
  ```bash
  bao write auth/dex/role/admin - <<EOF
  {
    "user_claim": "email",
    "allowed_redirect_uris": ["http://localhost:8250/oidc/callback","https://openbao.n8r.ch/ui/vault/auth/dex/oidc/callback"],
    "oidc_scopes": ["openid","profile","email","groups"],
    "bound_claims": {"email": ["you@gmail.com"]},
    "token_policies": ["admin"]
  }
  EOF
  ```
- **Check logs**: `kubectl -n appl-openbao logs openbao-0` shows OIDC
  validation failures with useful detail.

## Backups

The OpenBao data lives on a 10Gi Longhorn PVC (`longhorn-3-replicas`).
Recurring Longhorn backups to your backup target are the primary
recovery mechanism. OpenBao does not make backward-compatibility
guarantees for its data store across major versions — back up the PVC
**before** any OpenBao upgrade.