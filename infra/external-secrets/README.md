# External Secrets Operator

External Secrets Operator (ESO) syncs secrets from OpenBao into Kubernetes
Secrets. Workloads reference the synced Secrets as usual; ESO keeps them
up to date.

## Architecture

```
OpenBao (KV v2)  <--  External Secrets Operator  -->  Kubernetes Secrets
  secret/data/*         authenticates via k8s SA         consumed by pods
                      (auth/kubernetes, role=eso)
```

- **OpenBao** stores all secrets in the KV v2 engine at `secret/`.
- **ESO** authenticates to OpenBao via the Kubernetes auth method
  (`auth/kubernetes`, role `external-secrets`). No static tokens.
- **ClusterSecretStore** `openbao` is the single store pointing at the
  OpenBao in-cluster service.
- **ExternalSecret** resources (one per app) declare which OpenBao keys
  to sync and into which k8s Secret.

## Secret organization in OpenBao

Use a path convention that mirrors namespaces/apps:

```
secret/data/<namespace>/<app>/<key>
```

Examples:
```
secret/data/appl-n8r/dex/connectors       # dex google clientID+secret
secret/data/appl-n8r/oauth2-proxy/config  # oauth2-proxy client secret
secret/data/appl-emqx/emqx-tls            # EMQX TLS cert+key
secret/data/appl-openbao/dex-client       # openbao's dex client secret
```

Write a secret:
```bash
bao kv put secret/appl-n8r/dex/connectors \
  clientID="xxx.apps.googleusercontent.com" \
  clientSecret="GOCSPX-xxx"
```

Read it back:
```bash
bao kv get secret/appl-n8r/dex/connectors
```

List all secrets:
```bash
bao kv list secret/
bao kv list secret/appl-n8r/
```

## Using ESO in an app

Create an `ExternalSecret` in the app's directory. It references the
`openbao` ClusterSecretStore, maps OpenBao keys to k8s Secret keys, and
ESO creates/updates the target Secret.

Example - `workloads/appl-n8r/dex/externalsecret.yaml`:
```yaml
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: dex-secrets
  namespace: appl-n8r
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: dex-secrets          # the k8s Secret ESO creates
    creationPolicy: Owner
  data:
    - secretKey: helm-values.yaml   # key in the k8s Secret
      remoteRef:
        key: appl-n8r/dex           # path in OpenBao KV (no secret/ prefix)
        property: helm-values.yaml  # key inside that OpenBao secret
```

The app's HelmRelease references `dex-secrets` via `valuesFrom` exactly
as it does today with SOPS - no change to the HelmRelease.

## Migration from SOPS

The current flow: SOPS-encrypted `*.sops.yaml` files in git, Flux
decrypts them via the `sops-age` key and creates k8s Secrets.

The new flow: secrets live in OpenBao, ESO syncs them into k8s Secrets.
No encrypted files in git.

### Per-app migration steps

For each app that uses a SOPS-encrypted secret:

1. **Read the current secret value** from the SOPS file or the cluster
   and write it to OpenBao:
   ```bash
   # Port-forward to OpenBao
   kubectl -n appl-openbao port-forward pod/openbao-0 8200:8200 &
   export BAO_ADDR=http://127.0.0.1:8200
   bao login -method=oidc -path=dex

   # Write the secret to OpenBao (example for dex)
   bao kv put secret/appl-n8r/dex/connectors \
     clientID="..." \
     clientSecret="..."
   ```

2. **Create an ExternalSecret** in the app's directory (e.g.
   `workloads/appl-n8r/dex/externalsecret.yaml`).

3. **Remove the SOPS file** (e.g. `dex-secrets.sops.yaml`) from the repo.

4. **Remove the Flux `decryption` block** if this was the last SOPS
   secret in that Kustomization. (The `infrastructure` and `workloads`
   Kustomizations in `infra/flux-system/gotk-sync.yaml` have
   `decryption: provider: sops` - this can stay until ALL secrets are
   migrated.)

5. **Verify** ESO created the Secret:
   ```bash
   kubectl -n appl-n8r get externalsecret dex-secrets
   # READY should be True
   kubectl -n appl-n8r get secret dex-secrets
   ```

### What stays in SOPS

Some secrets should NOT move to OpenBao:

- **The SOPS age key itself** (`sops-age` secret in `flux-system`) -
  used by Flux to decrypt. If everything migrates to ESO, this can
  eventually be removed.
- **The OpenBao unseal key** - already a plain k8s Secret, not SOPS.
- **TLS certificates** managed by cert-manager - those are issued
  in-cluster and don't need to go through OpenBao.

### Gradual migration

Migration is per-app. SOPS and ESO coexist until all secrets are moved.
The Flux `decryption: provider: sops` block on the Kustomizations can
stay in place - it's a no-op for directories with no SOPS files.

## Files

| File | Purpose |
|------|---------|
| `infra/flux-system/repo/external-secrets.yaml` | HelmRepository for ESO chart |
| `infra/external-secrets/ns.yaml` | Namespace `external-secrets` |
| `infra/external-secrets/external-secrets.yaml` | HelmRelease for ESO |
| `infra/external-secrets/clustersecretstore.yaml` | ClusterSecretStore pointing at OpenBao |
| [`iac`](https://github.com/clementnuss/iac) -> `openbao/main.tf` | Kubernetes auth method + ESO policy + role (in OpenTofu) |