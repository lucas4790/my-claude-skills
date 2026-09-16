# Build failures: timeline and logs in depth

All examples use build `240737` in org `https://movares-ta.visualstudio.com`, project `Dataplatform`
(verified 2026-09). Set `ORG=https://movares-ta.visualstudio.com` to keep commands short.

## Anatomy of a build-results URL

```
https://movares-ta.visualstudio.com/Dataplatform/_build/results?buildId=240737&view=logs&j=7bb042ae-...&t=5ab67c35-...
                                   ^project                                ^build      ^job record  ^task record
```

- `buildId`: the run id used by `az pipelines runs show --id` and every `invoke` route below.
- `j`: `id` of a timeline record with `type == "Job"`.
- `t`: `id` of a timeline record with `type == "Task"` whose `parentId` is `j`.
- `view=results` (or no `view`) is the summary page; `view=logs` is the log viewer.
- The `_links` object returned by `az pipelines runs show` is empty for this org, so build the URL by hand.

## Timeline

```bash
az devops invoke --area build --resource Timeline \
  --route-parameters project=Dataplatform buildId=240737 \
  --org $ORG --api-version 7.1 -o json > timeline.json
```

Record shape (fields that matter):

| Field | Meaning |
|---|---|
| `id`, `parentId` | Tree: Stage -> Phase -> Job -> Task. Stages have `parentId: null`. |
| `type` | `Stage`, `Phase`, `Job`, `Task` (also `Checkpoint` / `Checkpoint.Approval` for approvals). |
| `name` | Display name from YAML (`displayName`), e.g. `Deploy Loki on Kubernetes`. |
| `identifier` | YAML id of the stage/job when set (`Deploy_Sandbox`), handy for matching to source. |
| `state` | `pending`, `inProgress`, `completed`. |
| `result` | `succeeded`, `succeededWithIssues`, `failed`, `canceled`, `skipped`, `abandoned`. |
| `log.id` | Log id for `--resource Logs`; `null` for stages. |
| `issues[]` | `{type: "error"|"warning", message}` — the `##[error]`/`##[warning]` lines the task emitted. |
| `startTime`, `finishTime` | Duration; a task that fails instantly is usually a config/auth problem. |
| `task.name` | Task type (`HelmDeploy`, `AzureCLI`, `TerraformTaskV4`), tells you which runner produced the log. |
| `attempt` | > 1 after a retry of the stage/job. |
| `workerName` | Agent that ran the job; useful when a failure is agent-specific (disk full, stale tool cache). |
| `order` | Execution order among siblings. |

jq recipes:

```bash
# every failed record with its tree position
jq -c '.records[] | select(.result=="failed") | {type, name, id, parentId, logId: .log.id}' timeline.json

# failed tasks only, with the error messages ADO already extracted
jq -c '.records[] | select(.result=="failed" and .type=="Task")
       | {name, taskType: .task.name, logId: .log.id, issues: [.issues[]? | select(.type=="error") | .message]}' timeline.json

# the task named in the URL (t=...)
jq '.records[] | select(.id=="5ab67c35-e2ab-5479-6718-57549f57a92d")' timeline.json

# a job's tasks in execution order
jq -c '[.records[] | select(.parentId=="7bb042ae-e148-58f0-abd0-b9e2a5ce7a10")] | sort_by(.order)[] | {name, result, logId: .log.id}' timeline.json

# what was skipped because of the failure (stages with dependsOn)
jq -c '.records[] | select(.type=="Stage") | {name, result}' timeline.json
```

A `Job` marked `failed` with a `Task` child marked `failed` is one failure, not two: report the task. A failed `Job`
with no failed task usually means the agent died or the job timed out; read the job log (`log.id` of the job record).

## Logs

```bash
# list all logs of the build (id, lineCount, type)
az devops invoke --area build --resource Logs --route-parameters project=Dataplatform buildId=240737 \
  --org $ORG --api-version 7.1 -o json | jq -c '.value[] | {id, lineCount}'

# fetch one log as text
az devops invoke --area build --resource Logs --route-parameters project=Dataplatform buildId=240737 logId=135 \
  --org $ORG --api-version 7.1 -o json | jq -r '.value[]' > log-135.txt
```

Each line starts with a timestamp (`2026-09-16T15:34:25.0857067Z `); `##[error]`, `##[warning]`, `##[section]`,
`##[debug]` prefixes are ADO markers. Reading strategy for long logs:

```bash
wc -l log-135.txt
grep -n -E '##\[error\]|Error:|FAILED|fatal|panic:|Exit code [1-9]' log-135.txt | head
sed -n '1180,1230p' log-135.txt      # context around the first hit
tail -n 40 log-135.txt               # exit code and cleanup
```

Log 1 (`type: Container`) is the whole-build log; job logs contain all their tasks' output. Prefer the task log.

## Recognising common root causes

| Symptom in log | Likely cause | Check on the live system |
|---|---|---|
| `UPGRADE FAILED: cannot patch "<name>" with kind StatefulSet: ... Forbidden: updates to statefulset spec for fields other than ...` | Chart changed an immutable StatefulSet field (`volumeClaimTemplates`, `serviceName`, selector). Needs delete-and-recreate of the StatefulSet (PVCs survive) or a values revert. | `kubectl get sts -n <ns> <name> -o yaml`, `helm history <release> -n <ns>` |
| `UPGRADE FAILED: another operation (install/upgrade/rollback) is in progress` | Previous Helm run left the release `pending-upgrade`. | `helm history`; `helm rollback <release> <last-deployed-rev>` |
| `Error: timed out waiting for the condition` | Pods never became ready within `--timeout`. | `kubectl get pods -n <ns>`, `kubectl describe pod`, events |
| `error: You must be logged in to the server (Unauthorized)` / `Kubernetes cluster unreachable` | Kubeconfig/credential step missing or expired; AKS RBAC. | Does the job run `az aks get-credentials --admin` (or `KubeloginInstaller` + `kubelogin`) before `helm`? |
| `AuthorizationFailed` from `az` | Service connection identity lacks the role on that scope. | `az role assignment list --scope ... --assignee <sp>` |
| `Error: Error acquiring the state lock` (Terraform) | Stale lock from a cancelled run. | `terraform force-unlock <id>` after confirming no run is active |
| `##[error]The task has timed out.` | Task `timeoutInMinutes` exceeded. | Was it stuck (see last log lines) or just slow? |
| `No hosted parallelism has been purchased` / agent `offline` | Pool capacity, self-hosted agent down. | `az pipelines agent list --pool-id <id>` |
| Failure on `refs/pull/<id>/merge` only | Merge commit differs from the branch head; conflicts or a `main` change. | `az repos pr show --id <id>` -> `mergeStatus` |

Before editing pipeline YAML, verify the diagnosis against the live resource. A one-off cluster fix (delete a
StatefulSet, roll back a release, unlock state) plus a re-run is frequently the whole remedy; only make the pipeline
self-healing when the failure mode will recur.

## Re-running

Retrying a failed stage from the UI ("Rerun failed jobs") keeps the same build id and increments `attempt` on the
retried records. Queueing a new run (`az pipelines run` / `az pipelines build queue`) creates a new build id; ask the user
before doing either. A PR gets a fresh validation build automatically on the next push to its source branch.
