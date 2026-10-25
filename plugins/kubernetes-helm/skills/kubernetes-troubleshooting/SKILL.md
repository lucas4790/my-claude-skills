---
name: kubernetes-troubleshooting
description: Use when a Kubernetes workload is not healthy on any cluster - CrashLoopBackOff, ImagePullBackOff, Pending, OOMKilled, failing probes, a rollout that never finishes, or a kubectl one-liner to find broken pods. Read-only first, then the smallest fix. Not for AKS-only questions such as node pool upgrades or workload identity (use azure-kubernetes-service), ACR pull permissions (use azure-container-registry) or Helm release errors (use helm-charts).
---

# Kubernetes troubleshooting

Find out what is wrong with read-only commands before changing anything. Most failures are visible in
the pod's events, its previous logs and its exit code.

## 0. Know where you are

```bash
kubectl config current-context
kubectl get ns "$NS"
```

Name the context and namespace explicitly in every command (`--context`, `-n`) when it is not a throwaway
cluster. A `kubectl config use-context` in another terminal silently retargets bare commands.

## 1. Find what is broken

```bash
# Everything not Running or Completed, with node and restarts
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded -o wide

# Pods that run but restart a lot, worst first
kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' \
  -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount,PHASE:.status.phase'

# What the cluster says happened, newest last
kubectl get events -n "$NS" --sort-by=.lastTimestamp
```

A pod that is `Running` with a high restart count does not match the first query; use the second.

## 2. Read the symptom

| Status | First look | Usual causes |
|---|---|---|
| `CrashLoopBackOff` | `kubectl logs "$POD" -n "$NS" --previous`, then `kubectl describe pod` (Last State, Exit Code) | app error at startup, missing env or config, wrong command, liveness probe killing a slow start, wrong CPU architecture (`exec format error`: arm64 image on amd64 nodes or the reverse) |
| `ImagePullBackOff` / `ErrImagePull` | the Events at the bottom of `kubectl describe pod` | wrong tag or registry, missing `imagePullSecrets`, private registry without access, rate limit |
| `Pending` | Events: `FailedScheduling` and its reason | not enough CPU or memory, taint without toleration, `nodeSelector` or affinity that matches no node, unbound PersistentVolumeClaim, namespace quota |
| `CreateContainerConfigError` | Events | a referenced ConfigMap, Secret or key does not exist |
| `OOMKilled` (exit 137) | `kubectl describe pod`, `kubectl top pod -n "$NS" --containers` | memory limit below real use; exit 137 without `OOMKilled` is a SIGKILL from something else |
| `Error` / exit 126, 127 | logs | 126: command not executable, 127: command not found in the image |
| `Evicted` | `kubectl describe pod` | node pressure (disk, memory); look at the node, not the pod |

Exit codes: 1 application error, 137 SIGKILL (OOM or forced stop), 143 SIGTERM (normal shutdown that
exceeded the grace period or was requested).

## 3. Probes

A liveness probe that fails while the app is still starting causes a restart loop that looks like a crash.
Prefer a `startupProbe` for slow starters and keep liveness cheap; readiness decides traffic, liveness decides
restarts.

```yaml
startupProbe:
  httpGet: {path: /healthz, port: 8080}
  periodSeconds: 5
  failureThreshold: 30
livenessProbe:
  httpGet: {path: /healthz, port: 8080}
  periodSeconds: 10
```

## 4. Stuck rollouts

```bash
kubectl rollout status deploy/"$NAME" -n "$NS" --timeout=60s
kubectl rollout history deploy/"$NAME" -n "$NS"
kubectl describe deploy "$NAME" -n "$NS"
kubectl get rs -n "$NS" -l app="$NAME"
```

A rollout stops when the new pods never become Ready (look at those pods, step 2), when a PodDisruptionBudget
or quota blocks it, or after `progressDeadlineSeconds` (condition `Progressing=False`). Going back is
`kubectl rollout undo deploy/"$NAME" -n "$NS"`; it changes the cluster, so say so before running it.

## 5. Debugging inside

`kubectl exec` into the container if the image has a shell; if it does not (distroless), attach an ephemeral
container: `kubectl debug -it "$POD" -n "$NS" --image=busybox:1.36 --target=app`. Both run code in the
workload: ask first on production.

## Rules

- Diagnose with `get`, `describe`, `logs`, `events`, `top`; only then propose a change, and show the exact command.
- Do not `kubectl delete pod` a pod that a StatefulSet or Job owns without saying what will happen to its identity or progress.
- The fix belongs in the manifest or chart, not in a `kubectl edit` on the live object; otherwise the next deploy undoes it.
- Do not paste secrets that `kubectl get secret -o yaml` or `describe` printed back into the chat.
