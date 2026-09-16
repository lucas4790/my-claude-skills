# Pitfalls: Windows, Git Bash, and Azure Pipelines YAML

## Windows and Git Bash

### Git Bash rewrites `/subscriptions/...` into a Windows path

MSYS path conversion turns a leading `/` argument into `C:/Program Files/Git/subscriptions/...`, so
`az role assignment list --scope /subscriptions/<id>` silently queries a nonsense scope. Disable conversion for
that command:

```bash
MSYS_NO_PATHCONV=1 az role assignment list --scope /subscriptions/<sub>/resourceGroups/<rg> -o table
```

Same for any value starting with `/`: `--scope`, `--resource-id`, ADO paths like `--path /Platform` (ADO folder paths
use backslashes in output but forward slashes on input). PowerShell does not have this problem.

### Long paths when cloning ADO repos

Vendored charts and node_modules routinely exceed 260 characters. Clone with

```bash
git -c core.longpaths=true clone https://movares-ta.visualstudio.com/Dataplatform/_git/Dataplatform.Infrastructure
```

or set it once with `git config --global core.longpaths true`. Without it, `git checkout` reports
`Filename too long` and leaves the working tree partially populated. Prefer short clone locations
(`C:\src\<repo>`) over deep OneDrive folders.

### `python3` may be the Microsoft Store stub

On Windows, `python3` / `python` on PATH can resolve to `%LOCALAPPDATA%\Microsoft\WindowsApps\python3.exe`, a stub
that opens the Store (or exits 9009 in non-interactive shells). Scripts that call `python3` then fail with confusing
errors. Use the real interpreter by path, e.g.
`C:/Users/<you>/AppData/Local/Programs/Python/Python313/python.exe`, or `py -3`. Add `PYTHONUTF8=1` for scripts that
print non-ASCII (the default console code page is not UTF-8).

### cmd.exe argument length

`az` on Windows is `az.cmd`; arguments over 8191 characters (long `--description`, `--discussion`, `--content`) fail.
Put the payload in a file and use `az devops invoke --in-file`, or run from PowerShell 7 / Git Bash where the limit is
higher.

### Quoting `--query`

JMESPath expressions contain `{`, `[`, `"`. In Git Bash wrap the whole expression in double quotes and avoid inner
double quotes (`[?result=='failed']` uses single quotes, which JMESPath accepts). In PowerShell, use single quotes
outside and double quotes inside, or the stop-parsing token `--%` for complex expressions.

### Output encoding

`az ... -o table` prints Unicode; on a code page 437 console, accented names (`één`) show as `��n`. Use
`chcp 65001` or `-o json`.

## Azure Pipelines YAML

### `$(var)` macros expand inside inline scripts

Azure Pipelines replaces `$(name)` with the variable value **as text** before the script runs, in every task input
including `AzureCLI@2` `inlineScript`, `Bash@3` `script`, `PowerShell@2`. Consequences:

- Values with spaces or `$` break the script unless quoted: `helm upgrade --set foo="$(myValue)"`.
- Bash `$(cmd)` command substitution works only when no pipeline variable is called `cmd`; a variable named `date`
  would replace `$(date)` in your script.
- An undefined `$(foo)` stays literal, so bash then tries to run `foo` as a command.
- Secrets are not exposed as env vars automatically; map them explicitly: `env: { TOKEN: $(secretVar) }` and use
  `$TOKEN` in bash. This also avoids the quoting problems above and is the recommended style for all variables.

### `HelmDeploy@1` cannot retry or self-heal

`HelmDeploy@1` runs one Helm command and has no `retryCountOnTaskFailure` semantics that help with transient
Kubernetes errors, no pre-flight (`helm history`, stuck-release rollback), and hides the kubeconfig it generates.
For deploy steps that must recover from a `pending-upgrade` release, an immutable-field error, or a flaky API server,
use `AzureCLI@2` with an inline script:

```yaml
- task: AzureCLI@2
  displayName: Deploy Loki on Kubernetes
  inputs:
    azureSubscription: <service-connection>
    scriptType: bash
    scriptLocation: inlineScript
    inlineScript: |
      set -euo pipefail
      az aks get-credentials --resource-group "$RG" --name "$AKS" --admin --overwrite-existing
      status=$(helm status "$RELEASE" -n "$NS" -o json 2>/dev/null | jq -r .info.status || echo none)
      if [[ "$status" == pending-* ]]; then
        helm rollback "$RELEASE" -n "$NS" --wait
      fi
      for attempt in 1 2 3; do
        helm upgrade --install "$RELEASE" ./charts/loki -n "$NS" -f values.yaml --wait --timeout 10m && break
        echo "helm upgrade failed (attempt $attempt)"; sleep 30
      done
  env:
    RG: $(resourceGroup)
    AKS: $(aksName)
    RELEASE: logging-loki
    NS: logging
```

`--admin` works when the service connection identity has the AKS cluster admin role; otherwise use
`az aks get-credentials` without `--admin` plus `kubelogin convert-kubeconfig -l azurecli`. Keep `HelmDeploy@1` for
plain deploys where a failure should stop the pipeline; move to `AzureCLI@2` only where the recovery logic is needed.

### Immutable StatefulSet fields

Changing `volumeClaimTemplates` (e.g. storage size), `serviceName` or `selector` in a chart makes Helm fail with
`Forbidden: updates to statefulset spec for fields other than ...`. Options, in order of preference:

1. Resize the PVCs in place (`kubectl patch pvc ... -p '{"spec":{"resources":{"requests":{"storage":"150Gi"}}}}'`,
   storage class must allow expansion) and leave the template size alone, or
2. `kubectl delete sts <name> -n <ns> --cascade=orphan` (pods and PVCs stay), then re-run the deploy so the StatefulSet
   is recreated with the new template.

Confirm with the user before deleting anything in a cluster; do it from a local shell, not by adding destructive
steps to the pipeline.

### Validation builds run on a merge commit

PR builds check out `refs/pull/<id>/merge`, the merge of the PR head into the target branch. A build can fail for a
PR whose branch is green on its own when `main` moved. `az repos pr show` -> `mergeStatus: conflicts` is the tell;
otherwise compare `lastMergeSourceCommit.commitId` with the run's `sourceVersion` to see whether the failed build is
even for the latest push.

### Stage/job names in URLs vs YAML

The `j=` and `t=` ids in a build-results URL are timeline record GUIDs, not YAML names. Map them via the timeline
(`identifier` holds the YAML `stage`/`job` id when set; `name` holds `displayName`). See build-failures.md.
