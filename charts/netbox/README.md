# NetBox

[NetBox](https://netboxlabs.com/docs/netbox/) is an IP address management (IPAM) and
data center infrastructure management (DCIM) tool.

This chart wraps the upstream
[netbox-community/netbox-chart](https://github.com/netbox-community/netbox-chart) and adds:

- a ConfigMap holding our `CustomDeviceValidator`, mounted into the NetBox package
  directory of the web and worker pods, and wired up via `CUSTOM_VALIDATORS`
- its own Ingress, built from a single `hostname` value
- Cyberlink defaults: external PostgreSQL, a Valkey instance per release, S3 for media,
  Entra ID sign-in, one Secret for all credentials, no housekeeping CronJob

Everything under the `netbox:` key in `values.yaml` is passed straight through to the
upstream chart. For the full list of available settings, see the
[upstream values.yaml](https://github.com/netbox-community/netbox-chart/blob/main/charts/netbox/values.yaml).

The design goal is one instance per namespace with as little per-instance configuration as
possible: a hostname and a PostgreSQL endpoint. PostgreSQL is expected to exist already —
the chart neither creates a server nor a database.

## Installing an instance

### 0. Register the app in Entra ID

One app registration per instance, because the redirect URI is per hostname:

- *Redirect URI* (type Web): `https://<hostname>/oauth/complete/azuread-tenant-oauth2/`
- a client secret — note it down, Entra shows it once
- note the *Application (client) ID* and the *Directory (tenant) ID*

Skip this if the instance should do local login only; see
[Entra ID sign-in](#entra-id-sign-in) below.

### 1. Create the database

On the external PostgreSQL server, one database and one role per instance:

```sql
CREATE ROLE netbox_prod LOGIN PASSWORD '...';
CREATE DATABASE netbox_prod OWNER netbox_prod;
```

### 2. Create the Secret

All credentials come from a Secret called `netbox-secrets` in the instance's namespace. It
is **not** part of the Helm release on purpose: `secret_key` and `api_token_peppers` have
to survive a reinstall, otherwise every session and every v2 API token is invalidated.

[hack/create-netbox-secret.sh](hack/create-netbox-secret.sh) creates it, generates what can
be generated and asks for the two passwords. Re-running it keeps the existing values:

```bash
./hack/create-netbox-secret.sh -n netbox-prod -e netbox-admin@cyberlink.ch \
    -c <entra-client-id> -t <entra-tenant-id>
```

It asks for the superuser password, the database password, the S3 keys and the Entra client
secret. The keys it writes, in case you would rather manage the Secret elsewhere:

| Key | Contents |
| --- | --- |
| `secret_key` | Django secret key, 50+ characters |
| `api_token_peppers` | JSON object, e.g. `{"1":"<50+ characters>"}` — required for v2 API tokens (NetBox 4.5+) |
| `email_password` | SMTP password. **Must exist**, may be empty (see below) |
| `username`, `password`, `email` | NetBox superuser |
| `api_token` | API token for the superuser, at most 40 characters |
| `db_password` | Password of the PostgreSQL role |
| `valkey_password` | Password for the bundled Valkey |
| `s3_access_key`, `s3_secret_key` | S3 credentials, injected as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` |
| `sso.yaml` | Entra ID settings, mounted as an extra config file. Optional |

`email_password` has to be present even if you do not send mail: the upstream chart
projects that key without `optional: true`, so a missing key leaves both the web and the
worker pod stuck in `ContainerCreating`.

`sso.yaml` is a YAML document with three settings:

```yaml
SOCIAL_AUTH_AZUREAD_TENANT_OAUTH2_KEY: "<application (client) id>"
SOCIAL_AUTH_AZUREAD_TENANT_OAUTH2_SECRET: "<client secret>"
SOCIAL_AUTH_AZUREAD_TENANT_OAUTH2_TENANT_ID: "<directory (tenant) id>"
```

### 3. Install the chart

In Rancher: *Apps → Repositories* → add `https://cyberlinkag.github.io/public-helm-charts`,
then *Apps → Charts → NetBox*. The form
([questions.yaml](questions.yaml)) asks for the hostname, the database endpoint, the S3
bucket and a handful of sizing options; everything else comes from the chart.

By CLI the same thing is:

```shell
helm repo add cyberlink https://cyberlinkag.github.io/public-helm-charts
helm install netbox cyberlink/netbox -n netbox-prod \
  --set hostname=netbox.example.com \
  --set netbox.externalDatabase.host=pg-prod.example.internal \
  --set netbox.externalDatabase.database=netbox_prod \
  --set netbox.externalDatabase.username=netbox_prod \
  --set netbox.storages.default.OPTIONS.bucket_name=netbox-prod \
  --set netbox.storages.default.OPTIONS.endpoint_url=https://s3.example.com
```

Or, as a values file per instance:

```yaml
hostname: netbox.example.com
ingress:
  certManagerIssuer: letsencrypt-prod
netbox:
  externalDatabase:
    host: pg-prod.example.internal
    database: netbox_prod
    username: netbox_prod
  storages:
    default:
      OPTIONS:
        bucket_name: netbox-prod
        endpoint_url: https://s3.example.com
```

## Chart-specific values

Everything not under `netbox:` belongs to this chart:

| Value | Default | Description |
| --- | --- | --- |
| `hostname` | `""` | FQDN of the instance. Required. Used for the Ingress rule and the certificate |
| `ingress.enabled` | `true` | Render the Ingress |
| `ingress.className` | `nginx` | `IngressClass` to use |
| `ingress.certManagerIssuer` | `""` | Set as the `cert-manager.io/cluster-issuer` annotation |
| `ingress.tlsSecretName` | `netbox-tls` | Secret the certificate is stored in |
| `ingress.path` / `ingress.pathType` | `/` / `Prefix` | Ingress path |
| `ingress.annotations` | `{}` | Additional annotations |

The Ingress belongs to this chart rather than the upstream one because the upstream takes
its hostname as a list (`ingress.hosts[]`, `ingress.tls[]`) and Rancher's `questions.yaml`
cannot fill in list values ([rancher/rancher#32336](https://github.com/rancher/rancher/issues/32336)).
`netbox.fullnameOverride` is pinned to `netbox` so the Ingress can name the Service; do not
change it without adjusting [templates/ingress.yaml](templates/ingress.yaml).

## Media storage (S3)

`netbox.persistence.enabled` is `false` and `netbox.storages.default` points at
`storages.backends.s3.S3Storage`. Only the bucket and the endpoint differ per instance;
both are required and are checked while rendering, so a missing value fails the install
instead of surfacing as a boto3 error on the first upload. NetBox merges this over its
`DEFAULT_STORAGES`, so `staticfiles` and `scripts` keep their defaults.

The credentials come from `s3_access_key` / `s3_secret_key` in the Secret and are injected
as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` — django-storages 1.14.6, the version in
NetBox 4.6, resolves both from the environment. They deliberately do **not** go into
`storages.OPTIONS`: that block is rendered into the ConfigMap in cleartext. Web pods and
worker pods both need them (`netbox.extraEnvs` and `netbox.worker.extraEnvs`, kept in sync
through a YAML anchor).

Useful extra `OPTIONS`: `addressing_style: path` for Ceph RGW and older Minio,
`location: media` for a prefix inside the bucket. Full list in the
[django-storages docs](https://django-storages.readthedocs.io/en/latest/backends/amazon-S3.html).

To go back to a local volume, set `netbox.storages: {}` and
`netbox.persistence.enabled: true` — then a `ReadWriteMany` storage class is needed for
more than one web replica.

## Entra ID sign-in

`netbox.remoteAuth.backends` is set to `social_core.backends.azuread_tenant.AzureADTenantOAuth2`
(the single-tenant backend), which NetBox ships through `social-auth-core`.
`netbox.remoteAuth.enabled` stays `false` on purpose — that switch turns on header-based
authentication, which is unrelated.

The three settings live in the `sso.yaml` key of the Secret and are mounted as an extra
config file (`netbox.extraConfig`), so the client secret never reaches a ConfigMap. NetBox
loads every `SOCIAL_AUTH_*` variable it finds in its configuration.

- **Local login keeps working.** NetBox appends its `ObjectPermissionBackend`, which extends
  Django's `ModelBackend`, so the superuser from the Secret can always log in next to the
  Entra button.
- **Redirect URI**: `https://<hostname>/oauth/complete/azuread-tenant-oauth2/`. The
  post-install notes print it.
- **Group membership** is not synced from Entra. `netbox.remoteAuth.defaultGroups` puts every
  SSO user into fixed groups on first login (they must exist in NetBox), which is what the
  `user_default_groups_handler` in NetBox's social auth pipeline does. Mapping Entra groups
  onto NetBox groups needs a custom `SOCIAL_AUTH_PIPELINE`; the `remoteAuth.groupSync*` and
  `superuserGroups` values only apply to the header-based backend.
- **HTTPS redirects** work without extra settings: NetBox sets
  `SECURE_PROXY_SSL_HEADER = ('HTTP_X_FORWARDED_PROTO', 'https')`, so the redirect URI is
  built as `https://` as long as the ingress sets that header.
- To turn SSO off for an instance, set `netbox.remoteAuth.backends` to
  `[netbox.authentication.RemoteUserBackend]` (the upstream default) and leave `sso.yaml`
  out of the Secret.

## Deliberate trade-offs

- **`netbox.allowedHosts` stays `["*"]`.** It is a list, so it cannot come from the Rancher
  form, and overriding it through `netbox.extraConfig` would break the liveness and
  readiness probes — those address the pod by IP whenever `allowedHosts[0]` is `"*"`. The
  Ingress is what restricts the hostname. If you want NetBox to check the `Host` header as
  well, set `netbox.allowedHosts` in the YAML tab — the probes then send the hostname
  instead of the pod IP, and `ALLOWED_HOSTS_INCLUDES_POD_ID` keeps the pod IP accepted.
- **Valkey is pinned by digest.** Docker Hub only carries the rolling `latest` tag for
  `bitnami/valkey` since Bitnami moved versioned tags behind Secure Images. Refresh
  `netbox.valkey.image.digest` deliberately with
  `docker buildx imagetools inspect bitnami/valkey:latest`, or mirror the image and point
  `netbox.valkey.image.registry`/`.repository` at your own registry.
- **`netbox-secrets` outlives the release.** Uninstalling the app leaves it behind, which is
  what makes a reinstall keep working. Delete the namespace to get rid of it.
- **`sso.yaml` is mounted with `optional: true`.** A missing key would otherwise repeat the
  `email_password` footgun and leave the pods in `ContainerCreating`. The cost is that a
  forgotten `sso.yaml` shows a working Entra button that fails on redirect — local login
  still works, so the instance is reachable.

## The custom device validator

Devices with the role *Rack Access Device* must have a name, a location, a rack and a
serial number starting with `QA`. The class lives in
[templates/custom-validators.yaml](templates/custom-validators.yaml) and is referenced
by its dotted path, `netbox.cyberlink_validators.CustomDeviceValidator`.

Because `CUSTOM_VALIDATORS` is set statically, the corresponding field in the NetBox UI
under *Admin → Configuration* is read-only.

## Custom scripts and reports

NetBox loads scripts and reports from the database, not from disk — mounting `.py` files
into `/opt/netbox/netbox/reports` does nothing. Upload them through the UI, through
`POST /api/extras/scripts/upload/`, or sync them from a Data Source.

## Upgrading

### From 7.0.0 to 8.0.0

8.0.0 moves media to S3 and turns on Entra ID sign-in. Coming from 6.x, read the next
section as well — it covers everything else that changed.

- Add `s3_access_key` and `s3_secret_key` to `netbox-secrets`, and set
  `netbox.storages.default.OPTIONS.bucket_name` and `.endpoint_url`. Rendering fails
  without them. Copy the contents of the old media PVC into the bucket first, otherwise
  existing image attachments 404; the PVC is not deleted by the upgrade, so there is time.
- To stay on a local volume, set `netbox.storages: {}` and `netbox.persistence.enabled: true`.
- Register the Entra app and add `sso.yaml` to the Secret, or switch
  `netbox.remoteAuth.backends` back to `[netbox.authentication.RemoteUserBackend]`. Local
  login keeps working either way.
- The Rancher form lost the storage class and media size fields and gained bucket, endpoint
  and region.

### From 6.x to 7.0.0

Chart 7.0.0 replaces our fork with the upstream chart and jumps NetBox from v4.0.3 to
v4.6.7. This is a breaking change in both values and infrastructure — read this whole
section before upgrading.

**Before you upgrade:**

- Back up the database. The NetBox migrations are not reversible.
- PostgreSQL 14 or newer is required (15+ as of NetBox 4.7).
- Create `netbox-secrets` as described above. In particular `api_token_peppers` is new —
  without it, v2 API tokens (NetBox 4.5+) do not work.
- Redis is replaced by a Valkey instance that ships with the release. Nothing carries over
  from the old Redis; both databases only hold the task queue and the cache. If you would
  rather keep an external server, set `netbox.valkey.enabled: false` and provide
  `netbox.tasksDatabase.host` / `netbox.cachingDatabase.host` plus their
  `existingSecretName` / `existingSecretKey`.
- The Ingress is now rendered by this chart. Set `hostname` instead of
  `ingress.hosts` / `ingress.tls`.
- `storageBackend` / `storageConfig` become `netbox.storages`. The old `AWS_*` keys turn
  into lowercase `OPTIONS` keys — `AWS_STORAGE_BUCKET_NAME` → `bucket_name`,
  `AWS_S3_ENDPOINT_URL` → `endpoint_url`, `AWS_DEFAULT_REGION` → `region_name` — and the
  access keys move into the Secret as `s3_access_key` / `s3_secret_key`. The bucket contents
  carry over unchanged.
- Entra ID sign-in is on by default. Register the app as described above and add `sso.yaml`
  to the Secret, or switch `netbox.remoteAuth.backends` back to
  `[netbox.authentication.RemoteUserBackend]`.

**Values that were renamed or removed:**

| 6.x | 7.0.0 |
| --- | --- |
| top-level keys | all moved under `netbox:` |
| `ingress.hosts`, `ingress.tls` | `hostname` (chart-owned Ingress) |
| `redis.*` | `netbox.valkey.*` |
| `tasksRedis.*` | `netbox.tasksDatabase.*` |
| `cachingRedis.*` | `netbox.cachingDatabase.*` |
| `externalDatabase.sslMode` | `externalDatabase.options.sslmode` |
| `externalDatabase.targetSessionAttrs` | `externalDatabase.options.target_session_attrs` |
| `storageBackend`, `storageConfig` | `storages` (dict of django-storages backends) |
| `remoteAuth.backend` (string) | `remoteAuth.backends` (list) |
| `extraContainers` | `sidecars` |
| `extraInitContainers` | `initContainers` |
| `metricsEnabled`, `serviceMonitor.*` | `metrics.enabled`, `metrics.serviceMonitor.*` |
| `jobResultRetention` | `jobRetention` |
| `enableLocalization` | `translationEnabled` |
| `skipStartupScripts` | removed — netbox-docker dropped startup scripts in 2.4.0 |
| `napalm.*` | removed — NAPALM moved to a plugin in NetBox 3.5 |

**Why the jump was needed:** the old chart rendered `STORAGE_BACKEND` unconditionally,
which makes NetBox 4.4 and newer refuse to start with `ImproperlyConfigured`. Several
other settings it rendered (`ENABLE_LOCALIZATION`, the `*_FORMAT` settings,
`JOBRESULT_RETENTION`, `NAPALM_*`) had been removed from NetBox and were silently
ignored.
