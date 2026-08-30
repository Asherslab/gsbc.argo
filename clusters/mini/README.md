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

### impact-kids photo store

Three more, all in the `impact-kids` namespace. The chart renders no Secret of
its own, so these must exist or the object store cannot start.

#### Where each value comes from

Two different kinds, and step 3 mixes them, which is the easy thing to get lost
in:

| Value | Origin |
|---|---|
| `APP_KEY`, `APP_SECRET` | **You invent them.** |
| `BACKUP_KEY`, `BACKUP_SECRET` | **You invent them.** |
| `<b2-key-id>`, `<b2-application-key>` | **Backblaze issues them**, when you create an application key in the B2 console. You cannot choose these. |

**SeaweedFS has no "create a key" step.** It is not a service that issues
credentials — whatever you write into `s3.json` below *becomes* the valid
credential, and nothing else will authenticate. So the first four are just random
strings you make up once and then reuse verbatim in the later steps.

Make them now. Avoid punctuation: they get signed into S3 headers and pasted into
shell and JSON by hand, so a quoting mistake is likelier than a short alphabet is
weak.

```
for n in APP_KEY APP_SECRET BACKUP_KEY BACKUP_SECRET; do
  echo "$n=$(openssl rand -hex 24)"
done
```

Keep that output somewhere for the next three commands, then discard it — after
step 3 the cluster is the only place these need to exist.

**1. SeaweedFS' identities document.** This is where the four invented values are
*defined*; substitute the real strings for the placeholders. Two identities, and
the split is the point: the backup reader holds a credential that cannot write to
or delete from the live bucket.

```
cat > /tmp/s3.json <<'JSON'
{
  "identities": [
    { "name": "impact-kids",
      "credentials": [ { "accessKey": "APP_KEY", "secretKey": "APP_SECRET" } ],
      "actions": [ "Read", "Write", "List", "Tagging", "Admin" ] },
    { "name": "backup",
      "credentials": [ { "accessKey": "BACKUP_KEY", "secretKey": "BACKUP_SECRET" } ],
      "actions": [ "Read:photos", "List:photos" ] }
  ]
}
JSON
kubectl -n impact-kids create secret generic s3-identities-secret \
  --from-file=s3.json=/tmp/s3.json
rm /tmp/s3.json
```

**2. The same app credential, as the gRPC service reads it.** Not a new one —
copy `APP_KEY` and `APP_SECRET` from step 1 exactly. SeaweedFS wants them in its
own JSON; the app wants them as environment variables, so the one credential is
written twice in two formats.

```
kubectl -n impact-kids create secret generic photos-secret \
  --from-literal=Photos__AccessKey=APP_KEY \
  --from-literal=Photos__SecretKey=APP_SECRET
```

**3. The backup job's two ends** — only needed once `backup.s3.enabled` is on.
**This is the one that mixes both kinds of credential:**

- the two `SEAWEED` lines are `BACKUP_KEY`/`BACKUP_SECRET` from step 1, i.e.
  yours. This is the *source*, and it is read-only.
- the two `B2` lines are the key id and application key **Backblaze gave you**.
  This is the *destination*, and it **must be able to write** or there is no
  backup. Give that key `listFiles` and `writeFiles` but **not `deleteFiles`**:
  `rclone copy` never issues a delete, and withholding it means neither end of
  the job can destroy the offsite copy.

```
kubectl -n impact-kids create secret generic s3-backup-secret \
  --from-literal=RCLONE_CONFIG_SEAWEED_ACCESS_KEY_ID=BACKUP_KEY \
  --from-literal=RCLONE_CONFIG_SEAWEED_SECRET_ACCESS_KEY=BACKUP_SECRET \
  --from-literal=RCLONE_CONFIG_B2_ACCESS_KEY_ID=<b2-key-id> \
  --from-literal=RCLONE_CONFIG_B2_SECRET_ACCESS_KEY=<b2-application-key>
```

So `APP_KEY`/`APP_SECRET` appear in (1) and (2), `BACKUP_KEY`/`BACKUP_SECRET` in
(1) and (3), and the Backblaze pair appears only in (3). A mismatch between the
copies is a 403 at runtime, not an install error — nothing checks that they
agree.

**Changing any of these later does not roll the pod.** SeaweedFS reads its
identities once at startup, and there is no rendered checksum for the chart to
hang an annotation on. Follow an edit with:

```
kubectl -n impact-kids rollout restart statefulset/s3-statefulset
```

Missing `photos-secret` is survivable by design — it is mounted `optional: true`,
so the app starts without photos rather than crash-looping, and every avatar
falls back to a coloured initial. Missing `s3-identities-secret` leaves the s3
pod unable to start.

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
