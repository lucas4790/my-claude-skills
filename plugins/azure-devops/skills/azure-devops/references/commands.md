# Command reference

`az` with the `azure-devops` extension (`az extension add --name azure-devops`). Log in with `az login`; the extension
reuses that session for `*.visualstudio.com` / `dev.azure.com` orgs. `ORG=https://movares-ta.visualstudio.com` below.

## Defaults and where they do not apply

```bash
az devops configure --defaults organization=$ORG project=Dataplatform
az devops configure --list
```

| Command group | `--org` | `--project` |
|---|---|---|
| `az pipelines *` | default honoured | default honoured |
| `az repos pr show / list / policy` | default honoured; pass `--org` when in doubt | **rejected** (`unrecognized arguments: --project`); the PR id is org-unique |
| `az repos list / show` | default honoured | default honoured |
| `az devops invoke` | **must pass `--org`** | via `--route-parameters project=...` |

`-o table` drops a column literally named `id`: always alias (`buildId:id`, `prId:pullRequestId`, `pipelineId:id`).
`-o tsv` keeps it.

## Pipelines and runs (read-only)

| Task | Command |
|---|---|
| List pipeline definitions | `az pipelines list --query "[].{pipelineId:id,name:name,path:path}" -o table` |
| Show one definition | `az pipelines show --id 898` |
| Latest runs of a pipeline | `az pipelines runs list --pipeline-ids 898 --top 5 --query "[].{buildId:id,result:result,status:status,branch:sourceBranch,queueTime:queueTime}" -o table` |
| Runs for a PR | `az pipelines runs list --branch refs/pull/31335/merge --top 5 ...` |
| Runs for a branch | `az pipelines runs list --branch refs/heads/main --top 5 ...` |
| Filter by outcome | `--result failed` / `--status inProgress` (also `--reason pullRequest`, `--requested-for <user>`, `--tags`) |
| Run details | `az pipelines runs show --id 240737 --query "{result:result,status:status,branch:sourceBranch,commit:sourceVersion,pipeline:definition.name,defId:definition.id,reason:reason,requestedFor:requestedFor.displayName,start:startTime,finish:finishTime}"` |
| Run artifacts | `az pipelines runs artifact list --run-id 240737` / `... artifact download --run-id 240737 --artifact-name <n> --path <dir>` |
| Timeline (stages/jobs/tasks) | `az devops invoke --area build --resource Timeline --route-parameters project=Dataplatform buildId=240737 --org $ORG --api-version 7.1 -o json` |
| List logs | `az devops invoke --area build --resource Logs --route-parameters project=Dataplatform buildId=240737 --org $ORG --api-version 7.1 -o json` |
| Read one log | `... --route-parameters project=Dataplatform buildId=240737 logId=135 ... \| jq -r '.value[]'` |
| Build changes (commits in the run) | `az devops invoke --area build --resource Changes --route-parameters project=Dataplatform buildId=240737 --org $ORG --api-version 7.1 -o json \| jq -c '.value[] \| {id, message, author: .author.displayName}'` |
| Variable groups | `az pipelines variable-group list -o table`; `az pipelines variable-group variable list --group-id <id>` (secrets are masked) |
| Agent pools / agents | `az pipelines pool list -o table`; `az pipelines agent list --pool-id <id> --query "[].{name:name,status:status,enabled:enabled}" -o table` |

Web URLs (construct by hand; `_links` is empty in CLI output):

- Build: `https://movares-ta.visualstudio.com/Dataplatform/_build/results?buildId=240737`
- Pipeline: `https://movares-ta.visualstudio.com/Dataplatform/_build?definitionId=898`

## Pull requests and repos (read-only)

| Task | Command |
|---|---|
| Show a PR | `az repos pr show --id 31335 --org $ORG --query "{status:status,title:title,src:sourceRefName,tgt:targetRefName,mergeStatus:mergeStatus,commit:lastMergeSourceCommit.commitId,draft:isDraft,repo:repository.name,by:createdBy.displayName}"` |
| PRs from a branch | `az repos pr list --repository Dataplatform.Infrastructure --source-branch fix/loki-storage-150gi --status all --query "[].{prId:pullRequestId,status:status,title:title}" -o table` |
| Open PRs in a repo | `az repos pr list --repository Dataplatform.Infrastructure --status active --top 20 --query "[].{prId:pullRequestId,title:title,src:sourceRefName,by:createdBy.displayName}" -o table` |
| PRs to review / mine | `--reviewer <email>` / `--creator <email>` |
| Policy and validation-build state | `az repos pr policy list --id 31335 --org $ORG --query "[].{policy:configuration.type.displayName,status:status,buildId:context.buildId}" -o table` |
| Reviewers and votes | `az repos pr reviewer list --id 31335 --org $ORG -o table` (vote: 10 approved, 5 approved with suggestions, 0 none, -5 waiting, -10 rejected) |
| Work items linked | `az repos pr work-item list --id 31335 --org $ORG -o table` |
| Repos in the project | `az repos list --query "[].{name:name,default:defaultBranch,url:remoteUrl}" -o table` |
| Branches / refs | `az repos ref list --repository Dataplatform.Infrastructure --filter heads/ --query "[].{name:name,commit:objectId}" -o table` |
| Branch policies | `az repos policy list --repository-id <guid> --branch main -o table` |

PR fields worth knowing: `status` (`active`, `completed`, `abandoned`), `mergeStatus` (`succeeded`, `conflicts`,
`queued`, `failure`), `sourceRefName` / `targetRefName` (full `refs/heads/...`), `lastMergeSourceCommit.commitId`
(branch head that was last validated), `lastMergeCommit.commitId` (the `refs/pull/<id>/merge` commit the build ran).

PR web URL: `https://movares-ta.visualstudio.com/Dataplatform/_git/Dataplatform.Infrastructure/pullrequest/31335`.

Clone: `git -c core.longpaths=true clone https://movares-ta.visualstudio.com/Dataplatform/_git/Dataplatform.Infrastructure`
(the `-c core.longpaths=true` matters on Windows; see pitfalls.md).

## `az devops invoke` in general

Any REST endpoint the extension does not wrap:

```bash
az devops invoke --area <area> --resource <resource> --route-parameters project=Dataplatform <k=v>... \
  --org $ORG --api-version 7.1 [--http-method GET|POST|PATCH] [--in-file body.json] [--query-parameters k=v] -o json
```

Useful `--area`/`--resource` pairs: `build`/`Timeline`, `build`/`Logs`, `build`/`Changes`, `build`/`Artifacts`,
`git`/`PullRequests`, `git`/`Commits`, `pipelines`/`runs`. Discover others with
`az devops invoke --help` and the REST docs (`https://learn.microsoft.com/rest/api/azure/devops/`).

## Write actions

These change shared state. Describe the exact command and its effect, get an explicit yes from the user, then run it.

| Action | Command |
|---|---|
| Queue a pipeline run | `az pipelines run --id 898 --branch refs/heads/<branch> [--variables k=v] [--parameters k=v]` |
| Retry / cancel a run | Rerun failed jobs is UI-only; cancel with `az pipelines build cancel --build-id 240737` |
| Tag a run | `az pipelines runs tag add --run-id 240737 --tags <tag>` |
| Create a PR | `az repos pr create --repository Dataplatform.Infrastructure --source-branch <b> --target-branch main --title "<t>" --description "<d>" [--draft] [--work-items <id>] [--reviewers <email>]` |
| Update / complete / abandon | `az repos pr update --id <id> --org $ORG --status completed --squash true --delete-source-branch true` (`--status abandoned`, `--auto-complete true`, `--title`, `--description`) |
| Vote | `az repos pr set-vote --id <id> --org $ORG --vote approve\|approve-with-suggestions\|reject\|reset\|wait-for-author` |
| Comment on a PR | No `az repos pr` subcommand exists for threads; POST via REST with the body in a file (cmd.exe caps argv at 8191 chars): `az devops invoke --area git --resource pullRequestThreads --route-parameters project=Dataplatform repositoryId=Dataplatform.Infrastructure pullRequestId=<id> --http-method POST --in-file thread.json --org $ORG --api-version 7.1` where `thread.json` is `{"comments":[{"content":"<text>","commentType":1}],"status":1}` |
| Set a variable | `az pipelines variable-group variable update --group-id <id> --name <n> --value <v>` |

Never paste secret values into commands or logs; mark them `--secret true` and let the user enter them in the UI.
