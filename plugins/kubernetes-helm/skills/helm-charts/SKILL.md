---
name: helm-charts
description: Use when writing, reviewing, linting, rendering, upgrading or debugging Helm charts and releases - values and templates, helm lint and helm template checks, upgrade --atomic, a release stuck in pending-upgrade or "another operation is in progress", failed hooks, immutable-field errors. Not for pods that fail after a successful deploy (use kubernetes-troubleshooting) or AKS-specific setup (use azure-kubernetes-service).
---

# Helm charts and releases

Helm 3. Render and lint locally before anything touches a cluster; look at the release state before
fixing a failed one.

## Check a chart before it ships

```bash
helm lint ./chart --strict -f values-prod.yaml
helm template myrelease ./chart -n "$NS" -f values-prod.yaml > rendered.yaml
kubeconform -strict -summary -ignore-missing-schemas rendered.yaml
```

`helm template` does not talk to the cluster, so `lookup` returns nothing and server-side validation is
skipped. For a closer check against the live API use `helm upgrade --install ... --dry-run=server`
(Helm 3.13 or later). If the `helm-diff` plugin is installed, `helm diff upgrade myrelease ./chart -n "$NS" -f values-prod.yaml`
shows what would change. `kubeconform` is a separate tool; skip that line if it is not installed.

## Upgrade safely

```bash
helm upgrade --install myrelease ./chart -n "$NS" --create-namespace \
  -f values-prod.yaml --atomic --timeout 5m
```

`--atomic` waits for readiness and rolls back on failure. This command changes the cluster: show it and
the target context before running it.

- Pin chart versions (`--version`) and image tags; never deploy `latest`.
- `--reuse-values` keeps old values and ignores new chart defaults. Prefer keeping a values file in git, or
  `--reset-then-reuse-values` (Helm 3.14 or later) when you must carry over live values.
- Helm does not upgrade or delete CRDs placed in `crds/`. Upgrade CRDs separately.

## Release stuck: "another operation (install/upgrade/rollback) is in progress"

The last release revision is in a `pending-*` state, usually because a previous `helm` process was killed
(CI cancelled, laptop closed).

```bash
helm history myrelease -n "$NS"
helm status myrelease -n "$NS"
pgrep -a helm
```

1. Make sure no `helm` process or CI job is still running against this release.
2. If an earlier revision is `deployed`, roll back to it: `helm rollback myrelease <revision> -n "$NS"`.
   This replaces the pending state with a new revision and does not remove anything else.
3. If the stuck revision is `pending-install` on a first install and nothing in it is needed,
   `helm uninstall myrelease -n "$NS"` and install again.
4. Last resort, only after 1 and when rollback also fails: Helm 3 stores each revision in a Secret named
   `sh.helm.release.v1.myrelease.v<N>`; deleting the Secret of the stuck revision removes that revision
   from Helm's records without touching the running objects. Say so before doing it and keep a copy of the
   Secret first (it contains rendered values, so do not paste it anywhere).

Do not start with `helm uninstall` on a release that serves traffic.

## Common upgrade failures

| Message | Cause | Fix |
|---|---|---|
| `field is immutable` | changed a Deployment `spec.selector`, a Job template or a Service `clusterIP` | delete and recreate that object (plan the downtime), or keep the old value |
| `rendered manifests contain a resource that already exists` | an object exists without Helm's ownership labels | adopt it with the `app.kubernetes.io/managed-by: Helm` label and `meta.helm.sh/release-name` and `meta.helm.sh/release-namespace` annotations, or delete it |
| `context deadline exceeded` / `timed out waiting for the condition` | pods never became Ready | `helm status`, then diagnose the pods (use kubernetes-troubleshooting) |
| hook job failed | a `helm.sh/hook` Job exited non-zero | `kubectl logs job/<name>`; set `helm.sh/hook-delete-policy` so reruns start clean |

## Write charts that behave

Template snippets (Go templates, not YAML, so they are shown as text):

```text
checksum/config: {{ include (print $.Template.BasePath "/configmap.yaml") . | sha256sum }}
image: "{{ .Values.image.repository }}:{{ required "image.tag is required" .Values.image.tag }}"
value: {{ .Values.timeout | quote }}
```

- The `checksum/config` annotation on the pod template restarts pods when the ConfigMap changes.
- Use `required` for values that have no safe default, and `quote` strings that look like numbers or booleans.
- Give every Deployment resource `requests` and `limits`, probes and a `securityContext` through values, with defaults in `values.yaml`.
- Keep `values.yaml` flat and commented; put environment differences in `values-<env>.yaml`, not in templates.
- Commit `Chart.lock` and run `helm dependency build` rather than `update` in CI.
- No secrets in values files in git: use an external secret operator, SOPS or a CI secret injected at deploy time.
- Run the checks above in CI so a broken template fails the pull request, not the deploy.
