# Fluxer on OpenShift

[Fluxer](https://fluxer.app) (open-source chat and voice platform, AGPL-3.0) at
**https://fluxer.twodcube.dev**, deployed by two Argo CD Applications:

- `applications/fluxer.yaml` → `fluxer/` (everything except the Route)
- `applications/fluxer-route.yaml` → `fluxer-route/` (the Route; see "Why two apps")

Upstream documents only a Docker Compose install
([operator guide](https://docs.fluxer.app/operator/get-started/)). This directory is
a one-to-one translation of that documented stack
(`deploy/self-hosting/docker-compose.yml` plus the `docker-compose.proxy.yml`
"behind your own reverse proxy" overlay) onto OpenShift. The platform services are
swapped for the cluster's own where it already has one. Upstream's undocumented
Helm charts (`deploy/helm/`) were not used: they omit Postgres, S3, search and
LiveKit, and assume ingress-nginx.

## Compose service → Kubernetes resource

| Compose service | Here | Notes |
|---|---|---|
| `edge` (Caddy) | `edge.yaml` | Upstream Caddyfile, only hostnames prefixed; plain HTTP `:8080` behind the Route |
| `postgres` | `postgres.yaml` (Crunchy PGO `PostgresCluster`) | PG 16 as upstream, TLS, pgBackRest weekly full + daily incremental |
| `valkey`, `nats`, `meilisearch` | `valkey.yaml`, `nats.yaml`, `meilisearch.yaml` | StatefulSets with PVCs, same flags as Compose |
| `seaweedfs`, `seaweedfs-init` | `objectbucketclaims.yaml`, `bucket-policy-job.yaml` | NooBaa (ODF MCG) instead of SeaweedFS |
| `livekit` | `livekit.yaml` | Signalling via the edge, media via MetalLB `10.2.100.6` |
| `api`, `worker`, `gateway`, `media-proxy`, `push`, `admin` | one file each | |
| `app-proxy`, `static-proxy` | `app-proxy.yaml`, `static-proxy.yaml` | |
| `snowflakes`, `users`, `gifs`, `messages`, `unfurl` (+ `-shard`) | `svc-*.yaml` | Router + one shard each, as in Compose |
| `.env` | `configmap-env.yaml` + `externalsecret.yaml` | Non-secret config / 1Password secrets |

Images are pinned to the upstream CalVer tag **and** digest that `v1` pointed at
when they were last bumped (2026-10-22). Third-party images are pinned the same way.

**Upstream revision:** these manifests mirror `deploy/self-hosting/` of
[fluxerapp/fluxer](https://github.com/fluxerapp/fluxer) at commit
[`557efe1c7d238fb19a3cab9e99f4dc4f83c3b113`](https://github.com/fluxerapp/fluxer/tree/557efe1c7d238fb19a3cab9e99f4dc4f83c3b113/deploy/self-hosting)
(2026-10-17, the last change under `deploy/self-hosting/` at the time of the
2026-10-22 sync). Upstream builds each image when its component changes, so the
pinned images carry different revisions; the newest, `fluxer-api`, was built from
`65faf056b9fd264565db937e7d08b73bb9337d77` (2026-10-20, 30 commits later with no
change under `deploy/self-hosting/` in between). Each image records the commit it
was built from in its `org.opencontainers.image.revision` label. Update this
paragraph when upgrading. The first translation was made from
`20e347439362dedd361d606597fd272be3dad605` (2026-10-11).

## Deviations from Compose, and why

- **Names carry a `fluxer-` prefix** (`fluxer-api`, `fluxer-nats`, …) because the
  stack shares the `dev` namespace. Every internal URL in `configmap-env.yaml`, the
  Caddyfile and `livekit.yaml` uses those names.
- **`enableServiceLinks: false` on every pod is required, not cosmetic.** Kubernetes
  injects `<SERVICE>_PORT=tcp://…` style variables. A Service named `fluxer-api`
  would inject `FLUXER_API_PORT`, and `fluxer-push` would inject
  `FLUXER_PUSH_SERVICE_PORT`. Both are real Fluxer settings.
- **Postgres over TLS with verification.** PGO only accepts `hostssl`. Fluxer's Node
  and Rust clients verify the server against `FLUXER_POSTGRES_SSL_CA`, which comes
  from PGO's `fluxer-postgres-cluster-cert` Secret. `FLUXER_POSTGRES_URL` comes from
  `fluxer-postgres-pguser-fluxer`. The user is not a superuser: Fluxer only creates
  its own unqualified tables, and PGO's `autoCreateUserSchema` gives it a `fluxer`
  schema (Postgres 15+ forbids creating objects in `public`).
- **Object storage is NooBaa.** Each OBC gets an account limited to its own bucket.
  Fluxer uses one key pair for all four buckets, so `fluxer-cdn`'s account is
  Fluxer's identity. A Sync-hook Job grants that account access to the other three
  buckets through bucket policies, then proves read and write on all four with
  Fluxer's credentials. Both mechanisms are per the ODF 4.22 docs.
  - **Principals differ from the docs.** The ODF 4.22 docs show account-name
    principals. This cluster's NooBaa (ODF 4.22.5) rejects them as
    `MalformedPolicy: Invalid principal` and accepts the account's IAM ARN
    instead.
  - **Where the ARNs come from.** An OBC account cannot look up its own ID (S3
    ACL owners are generic, STS is NotImplemented, IAM is AccessDenied). The ID is
    only on the cluster-scoped ObjectBucket, which this namespace-scoped Argo CD
    cannot read, so the four ARNs are recorded in the `fluxer-s3-accounts`
    ConfigMap.
  - **If an OBC is recreated,** it gets a new account. The Job then fails the sync
    with the command that prints the new ARNs.
- **S3 TLS trust.** NooBaa's `s3.openshift-storage.svc` certificate is signed by the
  OpenShift service CA (`configmap-service-ca.yaml`). api and worker add it with
  `NODE_EXTRA_CA_CERTS`. media-proxy, the only Rust service that talks to S3, uses
  `SSL_CERT_FILE` (system bundle) plus `SSL_CERT_DIR` (service CA). Its TLS stack
  replaces the system store when `SSL_CERT_FILE` is set, so both are needed.
- **OpenShift `restricted-v2` SCC fixes, no SCC grants.** All images run as the
  random UID OpenShift assigns:
  - gateway: an emptyDir at `RELX_OUT_FILE_PATH`, because the Erlang release
    otherwise writes `vm.args` into a directory owned by UID 65532.
  - edge (official caddy image): adds back `NET_BIND_SERVICE`, because the binary
    has a file capability and exec fails without it.
  - Caddy images: emptyDirs for `/config` and `/data`.
- **NetworkPolicy** `fluxer-backends`: Valkey and NATS have no auth in upstream
  (Compose hides them on a private bridge network). Only `app=fluxer` pods may
  reach them, or Meilisearch.
- **Loopback-only health endpoint.** The gateway's `/_health/ready` answers only
  loopback callers and returns 403 to a kubelet `httpGet`. Its readiness probe
  therefore execs `curl 127.0.0.1`, like Compose and upstream's chart.
- **Data is protected from app deletion:** the OBCs (StorageClass reclaim policy
  `Delete`) and the PostgresCluster carry `argocd.argoproj.io/sync-options: Delete=false`.

## Why two apps

The Route uses `spec.tls.externalCertificate` with the cert-manager Secret
`fluxer-tls`, per the OCP 4.22 docs. The API server rejects such a Route until the
Secret exists and the router may read it. Argo CD dry-runs every resource of an
Application before applying any, and refuses the whole sync on any failure. One
app would therefore deadlock on a fresh install: the Route's dry-run fails, so the
Certificate never gets created. `fluxer-route` holds only the Route and retries
until the certificate is issued.

## Secrets

`externalsecret.yaml` reads the 1Password item **`fluxer`** (vault `Server`), one
field per secret, generated in the upstream installer's formats. Postgres and S3
credentials are not in 1Password; PGO and NooBaa generate them in-cluster.

## First-time setup checklist

1. **DNS:** create `fluxer.twodcube.dev` in Cloudflare. TLS does not depend on it;
   the certificate uses a DNS-01 challenge.
2. **Setup wizard:** an unconfigured instance lets anyone register, and the first
   account to finish the wizard becomes admin. For the first install, the Route
   carried a `haproxy.router.openshift.io/ip_allowlist` of RFC 1918 ranges until
   the wizard was done from the LAN. The annotation was removed afterwards (git
   history has it). Restore it before Fluxer starts against an empty database
   again, such as a rebuild without a Postgres restore.
   - **Setup token (upstream since 2026-10-13).** A new instance now refuses every
     registration until one presents `FLUXER_SETUP_TOKEN` (32–256 characters; the
     installer uses `openssl rand -hex 32`), and that registration becomes
     admin. Unset, the API generates one on its first start and logs it once. This
     instance's admin predates the feature, so the API does not know the admin
     bootstrap happened: on the first start of an image from 2026-10-13 or later
     it logs a generated token, and a registration that presents that token still
     gets the wildcard admin ACL. Close the gate by re-saving the instance setup as
     configured from the admin dashboard (`PATCH /admin/instance/config` with
     `app_public.setup.configured: true` records the bootstrap and burns the
     token), and treat `fluxer-api` logs as sensitive until then. The variable is
     deliberately not in `externalsecret.yaml`: a value set there replaces the
     generated token but does not close the gate.
3. **Account recovery:** email is disabled, so there is no email password reset.
   Register a passkey or a second admin before opening registration (upstream
   advice).
4. **Voice from outside the LAN:** forward `7881/tcp` and `7882/udp` on the router to
   `10.2.100.6`. LiveKit advertises the WAN address it learns over STUN. The default
   voice region comes from `FLUXER_LIVEKIT_DEFAULT_REGION`. If voice still does not
   connect, check the voice regions and servers in the admin dashboard.
5. **Optional:** a Klipy API key (`FLUXER_KLIPY_API_KEY`) for GIF search, and SMTP
   settings for email, including upstream's domain-routed fallback SMTP provider
   (`FLUXER_EMAIL_FALLBACK_*`, 2026-10-17). All are unset in Compose too.

## Operations

- **Upgrading Fluxer:** for each image, resolve the digest behind `v1` and its
  `org.opencontainers.image.version` label (that CalVer tag points at the same
  digest), then update `image:` in the matching file. Before bumping, diff
  upstream's `deploy/self-hosting/` (`docker-compose.yml`, `.env.example`,
  `Caddyfile`) from the upstream revision recorded above to the new images'
  `org.opencontainers.image.revision` for new or renamed settings, read the
  [upgrading guide](https://docs.fluxer.app/operator/upgrading/), and record the
  new revision above.
  Upstream rollbacks do not undo database migrations, so take a pgBackRest backup
  first.
- **Config changes to `fluxer-edge` or `fluxer-livekit`:** Caddy and LiveKit read
  their config only at start. Bump `fluxer.twodcube.dev/config-revision` in the pod
  template so the pod restarts.
- **Backups:** Postgres via pgBackRest (`postgres.yaml`). Valkey, NATS and
  Meilisearch are on PVCs. Upstream treats Valkey and NATS data as not disposable.
  Bucket contents live in NooBaa.
- **Tests:** `fluxer/tests/bucket-policy-script.test.sh` runs the bucket-policy
  script against a fake `aws` (needs `bash`, `yq`, `jq`). Argo CD ignores the
  `tests/` directory (directory sources are not recursive).
