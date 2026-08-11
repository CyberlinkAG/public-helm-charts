# NetBox

[NetBox](https://netboxlabs.com/docs/netbox/) is an IP address management (IPAM) and
data center infrastructure management (DCIM) tool.

This chart wraps the upstream
[netbox-community/netbox-chart](https://github.com/netbox-community/netbox-chart) and adds:

- a ConfigMap holding our `CustomDeviceValidator`, mounted into the NetBox package
  directory of the web and worker pods, and wired up via `CUSTOM_VALIDATORS`
- its own Ingress, built from a single `hostname` value
- Cyberlink defaults: external PostgreSQL, a Valkey instance per release, one Secret for
  all credentials, no housekeeping CronJob

Everything under the `netbox:` key in `values.yaml` is passed straight through to the
upstream chart. For the full list of available settings, see the
[upstream values.yaml](https://github.com/netbox-community/netbox-chart/blob/main/charts/netbox/values.yaml).

The design goal is one instance per namespace with as little per-instance configuration as
possible: a hostname and a PostgreSQL endpoint. PostgreSQL is expected to exist already —
the chart neither creates a server nor a database.

## Installing an instance

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
./hack/create-netbox-secret.sh -n netbox-prod -e netbox-admin@cyberlink.ch
```

The keys it writes, in case you would rather manage the Secret elsewhere:

| Key | Contents |
| --- | --- |
| `secret_key` | Django secret key, 50+ characters |
| `api_token_peppers` | JSON object, e.g. `{"1":"<50+ characters>"}` — required for v2 API tokens (NetBox 4.5+) |
| `email_password` | SMTP password. **Must exist**, may be empty (see below) |
| `username`, `password`, `email` | NetBox superuser |
| `api_token` | API token for the superuser, at most 40 characters |
| `db_password` | Password of the PostgreSQL role |
| `valkey_password` | Password for the bundled Valkey |

`email_password` has to be present even if you do not send mail: the upstream chart
projects that key without `optional: true`, so a missing key leaves both the web and the
worker pod stuck in `ContainerCreating`.

### 3. Install the chart

In Rancher: *Apps → Repositories* → add `https://cyberlinkag.github.io/public-helm-charts`,
then *Apps → Charts → NetBox*. The form
([questions.yaml](questions.yaml)) asks for the hostname, the database endpoint and a
handful of sizing options; everything else comes from the chart.

By CLI the same thing is:

```shell
helm repo add cyberlink https://cyberlinkag.github.io/public-helm-charts
helm install netbox cyberlink/netbox -n netbox-prod \
  --set hostname=netbox.example.com \
  --set netbox.externalDatabase.host=pg-prod.example.internal \
  --set netbox.externalDatabase.database=netbox_prod \
  --set netbox.externalDatabase.username=netbox_prod
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
