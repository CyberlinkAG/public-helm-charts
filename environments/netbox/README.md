# NetBox environments

Use the same chart with three independent Helm releases, each named `netbox`, in
namespaces `netbox-dev`, `netbox-test` and `netbox-prod`. Fixed resource names in
the chart require separate namespaces. The files here are examples, not live
deployment configuration; replace all `.example.com` endpoints before use.

Each environment needs its own PostgreSQL database and role, S3 bucket and
credentials, and `netbox-secrets` Secret. The PostgreSQL server and S3 endpoint
may be shared. Give each database role and S3 credential access only to its own
environment. Valkey is deployed separately by each release. Configure an Entra
app per hostname as described in the [chart guide](../../charts/netbox/README.md).
Keep credentials out of this public repository.

## Initial installation

1. Adapt the environment values to your endpoints, database names and buckets.
   Set `ingress.certManagerIssuer` if using cert-manager; otherwise provision the
   TLS Secret yourself. Retain the existing production release name, namespace
   and resource settings when adopting an existing deployment.
2. Provision the databases and buckets, then create each namespace and its
   Secret using the chart's `hack/create-netbox-secret.sh` or your secret manager.
3. In Rancher Apps, install the chart separately in each namespace and supply
   the corresponding values in the YAML editor. Select a specific chart version.

CLI equivalent, run from the repository root after preparing the namespace and
Secret (start with dev):

```sh
helm repo add cyberlink https://cyberlinkag.github.io/public-helm-charts
helm repo update cyberlink
helm upgrade --install netbox cyberlink/netbox \
  --version 8.0.0 \
  --namespace netbox-dev \
  --values environments/netbox/dev.yaml \
  --wait --timeout 15m
```

`8.0.0` is the chart version in this checkout; verify it is published before using
the command. For test and prod, change both namespace and values filename.
These commands do not create the external databases, buckets or credentials.

## Releasing and promoting updates

1. Select the desired upstream chart version in `charts/netbox/Chart.yaml`.
   Check its NetBox image version and compatibility with PostgreSQL, plugins and
   the custom validator. `appVersion` in the wrapper is metadata, not an image
   selector; changing it alone does not upgrade NetBox.
2. Update the lock file with `helm dependency update charts/netbox`, bump the
   wrapper chart `version`, and align its `appVersion` with the selected image.
   Commit the lock file together with these changes.
3. Render and lint all environment values before publishing:

   ```sh
   helm dependency build charts/netbox --skip-refresh
   for env in dev test prod; do
     helm lint charts/netbox --values "environments/netbox/$env.yaml" || exit 1
     helm template netbox charts/netbox --namespace "netbox-$env" \
       --values "environments/netbox/$env.yaml" > /dev/null || exit 1
   done
   ```

4. Publish through the existing release workflow on `master`. Install the new
   explicit chart version in dev, then the exact same chart version in test,
   then prod. Environments may remain on different chart versions until each
   promotion is approved. Record each installed version in your deployment log.
   Never republish changed content under an existing version.
5. Before each upgrade, review the NetBox release notes and required upgrade
   path; back up the database and media, and preserve the Secret securely.
   For test, use a suitably sanitized production copy in the separate test
   database and bucket, with production integrations disabled.
6. Validate login (local and SSO), device validation, an attachment upload and
   download, API access and background jobs before promoting further.

Run upgrades with the explicit version and full environment values, without
`--reuse-values`, to avoid carrying obsolete defaults forward. Preserve any
existing site-specific overrides in the environment values first.

A Helm rollback does not restore the PostgreSQL database after NetBox migrations.
If an upgrade fails, stop application writes and follow the tested recovery
procedure with the matching previous chart, database backup and media state.
Do not assume an automatic Helm rollback makes a database upgrade reversible.

References: [Helm chart metadata](https://helm.sh/docs/topics/charts/),
[NetBox upgrade procedure](https://github.com/netbox-community/netbox/blob/main/docs/installation/upgrading.md).
