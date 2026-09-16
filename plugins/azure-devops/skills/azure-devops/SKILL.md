---
name: azure-devops
description: Work with Azure DevOps (ADO) through the az CLI — pipelines, builds, pull requests, repos. Use whenever the user pastes an Azure DevOps URL (dev.azure.com or *.visualstudio.com, `_build/results?buildId=`, `/pullrequest/`), mentions a build id, run id or PR number, or asks why a build or pipeline failed, to fetch a build log, to check a PR's status or validation build, to list or queue pipeline runs, or to clone an ADO repo. Also trigger on Dutch phrasings such as "pipeline faalt", "build is rood", "haal de log op", "waarom faalt de build", "PR status", "welke stap ging fout". Covers the build-failure workflow (URL -> build id -> timeline -> failed task -> log -> root cause) and the Windows / Git Bash pitfalls of az.
---

# Azure DevOps via `az`

Read-only inspection of pipelines, builds and PRs with the `az` CLI (`azure-devops` extension).
Defaults for the Movares org; override `--org` / `--project` for another org.

```bash
az devops configure --defaults organization=https://movares-ta.visualstudio.com project=Dataplatform
az devops configure --list      # verify
```

Some commands ignore the defaults: `az devops invoke` needs `--org`, and `az repos pr show/list` take `--org`
but reject `--project`. Always alias `id` in `--query` (`buildId:id`): `-o table` silently drops a column named `id`.

## Workflow: why did this build fail?

Start from whatever the user gives you (URL, build id, PR number, branch) and walk down to the log.

1. **Get the build id.**
   - URL `.../_build/results?buildId=240737&view=logs&j=<jobId>&t=<taskId>`: `buildId` is the build; `j` and `t` are the job and task **record ids in the timeline** (step 3).
   - PR number: validation builds run on `refs/pull/<id>/merge`.
     ```bash
     az pipelines runs list --branch refs/pull/31335/merge --top 5 \
       --query "[].{buildId:id,result:result,status:status,queueTime:queueTime,pipeline:definition.name}" -o table
     ```
   - Branch: `--branch refs/heads/<name>`; pipeline: `--pipeline-ids <defId>` (find ids with `az pipelines list -o table`).
2. **Confirm the run.** `az pipelines runs show --id 240737 --query "{result:result,branch:sourceBranch,commit:sourceVersion,pipeline:definition.name,reason:reason}"`.
   `_links` is empty in this output; the web URL is `https://movares-ta.visualstudio.com/Dataplatform/_build/results?buildId=240737`.
3. **Find the failed task in the timeline.** Records have `id`, `parentId`, `type` (Stage/Phase/Job/Task), `name`, `result`, `log.id`, `issues[]`.
   ```bash
   az devops invoke --area build --resource Timeline \
     --route-parameters project=Dataplatform buildId=240737 \
     --org https://movares-ta.visualstudio.com --api-version 7.1 -o json \
     | jq -c '.records[] | select(.result=="failed" and .type=="Task")
              | {name, id, parentId, logId: .log.id, issues: [.issues[]?.message]}'
   ```
   `issues[].message` is usually the `##[error]` line itself; often enough to name the root cause before reading the log.
   With a `t=` from the URL, `select(.id=="<taskId>")` instead.
4. **Read the log.**
   ```bash
   az devops invoke --area build --resource Logs \
     --route-parameters project=Dataplatform buildId=240737 logId=135 \
     --org https://movares-ta.visualstudio.com --api-version 7.1 -o json | jq -r '.value[]'
   ```
   Logs can run to thousands of lines: `grep -n -E '##\[error\]|Error:|FAILED'` first, then read around the hit. Job-level logs (`type=="Job"`) wrap all steps; task logs are the useful ones. Details and jq recipes: [references/build-failures.md](references/build-failures.md).
5. **Look at the live system before proposing pipeline changes.** A deploy step fails because of cluster/resource state as often as pipeline YAML: `kubectl get/describe`, `helm history`, `az resource show`. Fix the cause, not the symptom.
6. **Report**: pipeline, build id, stage/job/task name, the error line, root cause, proposed fix. Link the build URL.

## Pull requests

```bash
az repos pr show --id 31335 --org https://movares-ta.visualstudio.com \
  --query "{status:status,src:sourceRefName,tgt:targetRefName,mergeStatus:mergeStatus,commit:lastMergeSourceCommit.commitId,draft:isDraft}"
az repos pr list --repository Dataplatform.Infrastructure --source-branch <branch> --status all \
  --query "[].{prId:pullRequestId,status:status,title:title}" -o table
az repos pr policy list --id 31335 --org https://movares-ta.visualstudio.com -o table   # policy / validation-build state
```

`lastMergeSourceCommit.commitId` is the commit the validation build tested; compare it with `sourceVersion` of the run
to know whether the failure is for the latest push. PR web URL: `https://movares-ta.visualstudio.com/Dataplatform/_git/<repo>/pullrequest/<id>`.

## Write actions: confirm with the user first

Queueing runs, creating / completing / abandoning PRs, setting votes and variables change shared state.
State what you are about to do and wait for an explicit yes. Commands in [references/commands.md](references/commands.md#write-actions).

## Pitfalls (Windows, Git Bash, pipeline YAML)

- **Cloning ADO repos**: `git -c core.longpaths=true clone <url>`; vendored paths exceed MAX_PATH otherwise.
- **Git Bash mangles `/subscriptions/...`** into a Windows path: prefix `MSYS_NO_PATHCONV=1 az ... --scope /subscriptions/...`.
- **`python3` on Windows** may be the Microsoft Store stub that opens the Store. Call the real interpreter by path.
- **`$(var)` macros expand inside `AzureCLI@2` inline scripts** as plain text before bash runs. Bash `$(cmd)` substitution still works unless a pipeline variable shares the name; values with spaces need quotes: `"$(var)"`. Prefer mapping variables to `env:` and using `$VAR`.
- **`HelmDeploy@1` cannot retry**; for self-healing deploy steps use `AzureCLI@2` with an inline script: `az aks get-credentials --admin`, then `helm` / `kubectl` with your own retry loop.
- `-o table` drops any column literally named `id`; alias it (`buildId:id`, `prId:pullRequestId`).

More in [references/pitfalls.md](references/pitfalls.md).

## References

- [references/build-failures.md](references/build-failures.md): timeline record model, log endpoints, jq recipes, reading Helm/kubectl/Terraform failures.
- [references/commands.md](references/commands.md): command tables for pipelines, runs, PRs, repos, `az devops invoke`, plus write actions.
- [references/pitfalls.md](references/pitfalls.md): Windows / Git Bash / YAML gotchas with examples.
