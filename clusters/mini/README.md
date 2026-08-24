# mini — single-node k3s on the Mac mini

Sibling of `clusters/oci/`. Both live on `main`; each cluster's Argo CD watches
only its own `app-definitions/` path, so neither can act on the other's config.

## Layout

| Path | Purpose |
|---|---|
| `aoa.yaml` | app-of-apps, applied by `bootstrap-argo.sh mini` |
| `app-definitions/` | one Argo `Application` per component |
| `values/` | Helm overlays, merged **after** the shared `apps/<app>/values.yaml` |
| `app/` | extra manifests (issuers, tunnels, ingresses, LimitRange) |

## Differences from `clusters/oci/`

- **No Longhorn.** k3s `local-path` instead. Longhorn was 2.17Gi — 47% of all
  workload memory — for replica=1 on a single node, i.e. no redundancy at all.
- **cert-manager uses DNS-01**, not HTTP-01. Public records point at the tunnel,
  so ACME cannot reach an in-cluster solver.
- **Distinct tunnel names** (`*-mini`) and **temporary FQDNs**, so this cluster
  can run alongside OCI without touching production DNS.
- **Ingresses on the real hostnames**, for the on-site LAN path.
- **Requests/limits everywhere**, sized from measured OCI usage.
- Argo CD dex + notifications disabled, applicationset scaled to 0.

## Prerequisites (secrets, created out of band)

```
kubectl -n kube-system create secret generic cloudflare-api-token \
  --from-literal=api-token=<token>          # Zone:Read + DNS:Edit on both zones

kubectl -n cloudflare-operator-system create secret generic cloudflare-secrets \
  --from-literal=CLOUDFLARE_API_TOKEN=<token>

kubectl -n metabase create secret generic database-creds \
  --from-literal=connectionUri=<jdbc-uri>
```

Nothing that touches Cloudflare works until `cloudflare-secrets` exists — which
is the only reason an accidental sync of the OCI definitions here was harmless.

## Cutover

Two paths reach these services and they flip independently.

**LAN** — point on-site DNS for `kids.baptist.com.au` and
`kids-metabase.baptist.com.au` at the node's LAN address. Public DNS unchanged.
Certs come from DNS-01, so they are valid on both paths.

**Public**, per hostname, once verified on its `*-mini` name:

1. Delete the TunnelBinding on OCI — this removes the Cloudflare DNS record.
2. Change the `fqdn` here from the `-mini` name to the real one and sync.
3. The operator recreates the record against `*-tunnel-mini`.

Proxied CNAME, so propagation is seconds. Rollback is the same steps reversed.
Keep OCI running for a week afterwards.

## After cutover

Delete `clusters/oci/`, and bump k3s from the `v1.34` channel (pinned to match
OCI's 1.34.1 during migration) to `stable`.
