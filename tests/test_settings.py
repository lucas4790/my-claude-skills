"""settings/*.json: structure of every file, the read-only and guardrail invariants, and a small model of how
Claude Code matches permission rules (https://code.claude.com/docs/en/permissions, checked against 2.1.292).

The model is not Claude Code: it covers what the docs promise, so a rule that only matches in a newer or older
version is never asserted. What it does not model (quoted or escaped verbs, bash -c, xargs with flags, variables,
aliases) is the part the README calls a backstop; MISSED below pins those spellings, and KNOWN_FALSE_POSITIVES the
read-only commands that ask anyway, so the docs stay honest.
Everything reads the checkout's settings/ and README.md; nothing is written and no network or claude CLI is used.
"""
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

REPO = Path(__file__).resolve().parent.parent
SETTINGS = REPO / "settings"

# every settings/*.json and the top-level keys it may have; a new file must be registered here
KNOWN_FILES = {
    "permissions.json": {"$comment", "permissions"},
    "permissions-trusted-repo.json": {"$comment", "permissions"},
    "claude-guardrails.json": {"$comment", "permissions", "env", "attribution"},
    "cloud-guardrails.json": {"$comment", "permissions"},
    "project-plugins.json": {"enabledPlugins", "extraKnownMarketplaces"},
}
PERMISSION_KEYS = {"allow", "ask", "deny"}
GUARDRAILS = ("claude-guardrails.json", "cloud-guardrails.json")
RULE_RE = re.compile(r"(Bash|PowerShell)\(([^\s](?:.*[^\s])?)\)", re.S)


def load(name: str) -> dict:
    return json.loads((SETTINGS / name).read_text(encoding="utf-8"))


def rules(name: str, kind: str) -> list:
    return load(name).get("permissions", {}).get(kind, [])


def specs(rule_list, tool: str = "Bash") -> list:
    """The specifiers of the rules for one tool: 'Bash(git push *)' -> 'git push *'."""
    out = []
    for r in rule_list:
        m = RULE_RE.fullmatch(r)
        if m and m.group(1) == tool:
            out.append(m.group(2))
    return out


# --- a model of the documented matching --------------------------------------------------------------------
def matches(spec: str, command: str, ignore_case: bool = False) -> bool:
    """A * matches any text (spaces too). A trailing ' *' that is the rule's only wildcard also matches the bare
    command ('ls *' matches 'ls' and not 'lsof'; 'a * b *' does not match 'a b'). Whitespace runs collapse."""
    pattern = re.sub(r"[ \t]+", " ", spec.strip())
    command = re.sub(r"[ \t]+", " ", command.strip())
    if pattern.endswith(" *") and pattern.count("*") == 1:
        regex = re.escape(pattern[:-2]) + "( .*)?"
    else:
        regex = ".*".join(re.escape(part) for part in pattern.split("*"))
    return re.fullmatch(regex, command, re.S | (re.I if ignore_case else 0)) is not None


def split_commands(command: str) -> list:
    """Splits at && || ; | |& & and newlines outside quotes: a rule has to match each part on its own."""
    parts, cur, quote, i = [], [], None, 0
    while i < len(command):
        c = command[i]
        if quote:
            cur.append(c)
            if c == quote:
                quote = None
        elif c in "'\"":
            quote = c
            cur.append(c)
        elif command.startswith(("&&", "||", "|&"), i):
            parts.append("".join(cur))
            cur = []
            i += 1
        elif c in ";&|\n":
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(c)
        i += 1
    parts.append("".join(cur))
    return [p.strip() for p in parts if p.strip()]


ASSIGNMENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*=\S*\s+")
WRAPPERS = [re.compile(p) for p in (r"timeout (?:-\S+ )*\d+\S* ", r"time ", r"nice (?:-n \d+ )?", r"nohup ",
                                    r"stdbuf (?:-\S+ )+", r"command ", r"builtin ", r"xargs (?!-)")]


def variants(sub: str, assignments: bool) -> list:
    """The command as written and with wrappers stripped. A deny or ask rule also matches past any leading
    VAR=value; an allow rule only past known-safe variables, which the model leaves out (assignments=False)."""
    out, cur = [sub], sub
    while True:
        for pat in ([ASSIGNMENT] if assignments else []) + WRAPPERS:
            m = pat.match(cur)
            if m:
                cur = cur[m.end():]
                out.append(cur)
                break
        else:
            return out


def decide(command: str, allow=(), ask=(), tool: str = "Bash") -> str:
    """'ask' when any part of the command matches an ask rule (they win), 'allow' when every part matches an
    allow rule, otherwise 'prompt' (nothing matches: the permission mode decides). The Bash tool also matches an ask
    rule against the whole command line (docs: Bash rules match the whole command text; seen in 2.1.292), so a
    leading wildcard reaches past a pipe or &&; the model does not assume that of the PowerShell tool."""
    ci = tool == "PowerShell"
    ask_specs, allow_specs = specs(ask, tool), specs(allow, tool)
    subs = split_commands(command)
    for text in ([command.strip()] if tool == "Bash" else []) + subs:
        if any(matches(s, v, ci) for v in variants(text, True) for s in ask_specs):
            return "ask"
    if subs and all(any(matches(s, v, ci) for v in variants(sub, False) for s in allow_specs) for sub in subs):
        return "allow"
    return "prompt"


# --- structure of every file ---------------------------------------------------------------------------------
def test_every_settings_json_is_registered():
    on_disk = {p.name for p in SETTINGS.glob("*.json")}
    assert on_disk == set(KNOWN_FILES), f"register new files in KNOWN_FILES: {sorted(on_disk ^ set(KNOWN_FILES))}"


@pytest.mark.parametrize("name", sorted(KNOWN_FILES))
def test_file_has_only_known_keys(name):
    data = load(name)  # a parse error fails here
    assert isinstance(data, dict)
    assert set(data) <= KNOWN_FILES[name], sorted(set(data) - KNOWN_FILES[name])
    perm = data.get("permissions", {})
    assert set(perm) <= PERMISSION_KEYS, sorted(set(perm) - PERMISSION_KEYS)
    if "$comment" in KNOWN_FILES[name]:
        assert isinstance(data["$comment"], str) and len(data["$comment"]) > 200


@pytest.mark.parametrize("name", sorted(n for n, keys in KNOWN_FILES.items() if "permissions" in keys))
def test_rule_syntax_and_no_duplicates(name):
    perm = load(name).get("permissions", {})
    seen = {}
    for kind, lst in perm.items():
        assert isinstance(lst, list) and all(isinstance(r, str) for r in lst), kind
        assert len(lst) == len(set(lst)), f"{name} {kind}: duplicate {sorted({r for r in lst if lst.count(r) > 1})}"
        for r in lst:
            m = RULE_RE.fullmatch(r)
            assert m, f"{name} {kind}: not Bash(...) or PowerShell(...) without padding: {r!r}"
            spec = m.group(2)
            assert "\\" not in spec and not spec.endswith(":*"), f"{r!r}: the model knows neither escapes nor :*"
            if kind == "allow":  # Claude Code warns about a wildcard before the subcommand of an allow rule
                assert spec.count("*") == 0 or (spec.count("*") == 1 and spec.endswith(" *")), r
            assert seen.setdefault(r, kind) == kind, f"{name}: {r} is in {seen[r]} and {kind}"


@pytest.mark.parametrize("name", GUARDRAILS)
def test_guardrails_only_ask(name):
    perm = load(name)["permissions"]
    assert set(perm) == {"ask"}, f"{name}: guardrails add ask rules only (no allow, no deny)"


def test_permissions_json_stays_read_only():
    mutating = {
        "terraform": {"apply", "destroy", "import", "refresh", "taint", "untaint", "force-unlock", "init", "workspace"},
        "kubectl": {"apply", "create", "delete", "replace", "edit", "patch", "scale", "set", "label", "annotate",
                    "taint", "cordon", "uncordon", "drain", "rollout", "run", "exec", "cp", "debug", "port-forward"},
        "helm": {"install", "upgrade", "uninstall", "delete", "rollback", "push", "plugin", "repo"},
        "az": {"create", "delete", "update", "set", "add", "remove", "reset", "start", "stop", "restart", "scale",
               "upgrade", "purge", "recover", "restore", "import", "move", "invoke", "run", "deploy", "login", "rest",
               "get-credentials"},
        "git": {"push", "commit", "reset", "clean", "checkout", "merge", "rebase", "add", "rm", "config"},
        "rm": None,
    }
    for r in rules("permissions.json", "allow"):
        spec = RULE_RE.fullmatch(r).group(2)
        tool, *rest = spec.split()
        assert tool != "rm", r
        bad = set(rest) & (mutating.get(tool) or set())
        assert not bad, f"permissions.json allows a mutating verb {sorted(bad)}: {r}"
    # and by the model: none of the cloud-guardrails commands below is allowed without asking
    allow = rules("permissions.json", "allow") + rules("permissions-trusted-repo.json", "allow")
    for cmd in ["git push origin main", "rm -rf build", *ASK_CHANGE]:
        assert decide(cmd, allow=allow) != "allow", cmd


# --- cloud-guardrails.json -------------------------------------------------------------------------------------
CLOUD = rules("cloud-guardrails.json", "ask")

# one spelling per verb, plain and with flags before or between the words; they change state, so no allow rule may
# cover them
ASK_CHANGE = [
    "terraform apply", "terraform apply -auto-approve", "terraform -chdir=infra apply",
    "terraform -chdir=infra apply -auto-approve", "terraform destroy", "terraform -chdir=infra destroy",
    "terraform -chdir=infra destroy -auto-approve", "terraform refresh", "terraform -chdir=x refresh",
    "terraform refresh -target=azurerm_x.y",
    "terraform import azurerm_resource_group.rg /subscriptions/0/resourceGroups/rg",
    "terraform -chdir=x import a.b id", "terraform taint a.b", "terraform untaint a.b",
    "terraform force-unlock -force 123", "terraform state rm azurerm_x.y", "terraform -chdir=x state rm azurerm_x.y",
    "terraform state mv a b", "terraform state push x.tfstate", "terraform workspace new prod",
    "terraform workspace select prod", "terraform -chdir=x workspace select prod", "terraform workspace delete old",
    "kubectl apply -f x.yaml", "kubectl --context prod apply -f x.yaml", "kubectl -n x delete pod y",
    "kubectl --context prod -n x delete pod y", "kubectl delete ns x", "kubectl create ns x", "kubectl replace -f x",
    "kubectl edit deploy/x", "kubectl patch deploy x -p '{}'", "kubectl scale deploy x --replicas=0",
    "kubectl -n x scale deploy x --replicas=0", "kubectl autoscale deploy x --min=1 --max=3",
    "kubectl set image deploy/x c=img", "kubectl label pod x a=b", "kubectl annotate pod x a=b",
    "kubectl taint nodes n k=v:NoSchedule", "kubectl cordon n", "kubectl uncordon n",
    "kubectl drain n --ignore-daemonsets", "kubectl --context prod drain n", "kubectl expose deploy x --port 80",
    "kubectl run x --image=img", "kubectl exec -it pod -- sh", "kubectl -n x exec pod -- cat /etc/passwd",
    "kubectl cp x:/y ./y", "kubectl debug node/n -it --image=busybox", "kubectl port-forward svc/x 8080:80",
    "kubectl rollout restart deploy/x", "kubectl -n x rollout restart deploy/x", "kubectl rollout undo deploy/x",
    "kubectl rollout pause deploy/x", "kubectl rollout resume deploy/x", "kubectl rollout -n x restart deploy/x",
    "kubectl rollout --namespace x undo deploy/x", "kubectl rollout -n x pause deploy/x",
    "kubectl rollout -n x resume deploy/x",
    "kubectl config use-context prod", "kubectl config set-context --current --namespace=x",
    "kubectl config set clusters.x.server y", "kubectl config unset users.x", "kubectl config delete-context x",
    "kubectl config delete-cluster x", "kubectl config rename-context a b",
    "kubectl --kubeconfig k config use-context x", "kubectl config --kubeconfig=k use-context prod",
    "kubectl config -v=2 set-context x", "kubectl config --kubeconfig k unset users.x",
    "kubectl config --kubeconfig k delete-context x", "kubectl config --kubeconfig k rename-context a b",
    "helm install r c", "helm upgrade --install r c -n x", "helm --kube-context prod upgrade r c",
    "helm -n x upgrade r c", "helm uninstall r", "helm -n x uninstall r", "helm delete r", "helm rollback r 1",
    "helm push chart.tgz oci://x", "helm plugin install https://x", "helm plugin update x",
    "helm plugin --debug install https://x", "helm plugin --debug update x",
    "az group delete -n x --yes", "az group delete --name x", "az aks nodepool delete -g rg --cluster-name c -n np",
    "az role assignment create --assignee x --role y --scope z", "az role assignment delete --ids x",
    "az aks update -g rg -n c", "az aks scale -g rg -n c --node-count 3",
    "az aks nodepool scale -g rg --cluster-name c -n np --node-count 0",
    "az aks nodepool add -g rg --cluster-name c -n np", "az aks upgrade -g rg -n c --kubernetes-version 1.30",
    "az aks stop -g rg -n c", "az aks start -g rg -n c", "az aks get-credentials -g rg -n c",
    "az aks get-credentials -g rg -n c --admin", "az aks rotate-certs -g rg -n c",
    "az aks command invoke -g rg -n c --command 'kubectl delete pod x'",
    "az aks enable-addons -g rg -n c -a monitoring", "az aks disable-addons -g rg -n c -a monitoring",
    "az aks update-credentials -g rg -n c --reset-service-principal", "az keyvault set-policy -n kv --object-id x",
    "az keyvault delete-policy -n kv --object-id x", "az keyvault secret set --vault-name kv -n x --value y",
    "az keyvault secret restore --vault-name kv --file f", "az keyvault purge -n kv", "az keyvault recover -n kv",
    "az account set --subscription prod", "az login", "az login --service-principal -u a -p b --tenant c",
    "az rest --method delete --url https://management.azure.com/x", "az rest --url https://x", "az upgrade",
    "az upgrade --yes", "az pipelines run --name x", "az pipelines build queue --definition-name x",
    "az repos pr create --title x", "az boards work-item update --id 1 --state Done",
    "az devops invoke --area x --resource y", "az deployment group create -g rg --template-file x.bicep",
    "az resource delete --ids x", "az resource move --ids x --destination-group y", "az vm restart -g rg -n vm",
    "az vm deallocate -g rg -n vm", "az vm identity assign -g rg -n vm",
    "az vm run-command invoke -g rg -n vm --command-id RunShellScript", "az acr import --name r --source x",
    "az webapp deploy --name w -g rg --src-path x.zip", "az extension add --name x", "az extension remove --name x",
    "az ad sp credential reset --id x", "az ad sp create-for-rbac -n x",
    "az aks nodepool delete-machines -g rg --cluster-name c -n np --machine-names m",
]
# commands that print secret values or tokens; four of the allow rules of permissions.json cover some of them
ASK_SECRET = [
    "terraform state pull", "terraform -chdir=x state pull", "terraform state pull -no-color",
    "terraform output -json", "terraform output -raw db_password", "terraform -chdir=x output -json",
    "terraform show -json tfplan", "terraform -chdir=x show -json plan.out",
    "kubectl get secret", "kubectl get secret x -o yaml", "kubectl get secrets -A",
    "kubectl -n x get secret y -o jsonpath='{.data}'", "kubectl --context prod get secrets",
    "kubectl get cm,secret -n x", "kubectl get --raw /api/v1/namespaces/x/secrets", "kubectl config view --raw",
    "kubectl config view --flatten --raw", "kubectl config view --flatten", "kubectl config view --minify --flatten",
    "kubectl config --kubeconfig k view --raw", "kubectl config -v=2 view --flatten",
    "helm get values r", "helm get values r -n x -o yaml", "helm --kube-context prod get values r",
    "helm get manifest r", "helm get hooks r", "helm get all r", "helm get -n x values r",
    "helm get --namespace x manifest r", "helm get --kube-context prod hooks r", "helm get -n x all r",
    "az keyvault secret show --vault-name kv -n x", "az keyvault secret download --vault-name kv -n x -f y",
    "az account get-access-token", "az account get-access-token --resource https://x",
    "az storage account keys list -g rg -n sa", "az redis list-keys -g rg -n r", "az acr credential show -n r",
    "az webapp config appsettings list -g rg -n w", "az acr login -n r --expose-token",
    "az acr login --expose-token -n r",
]
# Bash only: compound commands, assignments and the wrappers the docs list
ASK_SHELL = [
    "cd infra && terraform apply -auto-approve", "terraform plan -out=p; terraform apply p",
    "terraform plan | tee x && terraform apply", "kubectl get pods -o name | xargs kubectl delete",
    "kubectl get pods || kubectl --context prod delete pod x", "echo hi\nhelm upgrade r c",
    "TF_VAR_x=1 terraform apply", "FOO=bar kubectl -n x delete pod y", "AWS_PROFILE=x az group delete -n x",
    "timeout 30 kubectl apply -f x", "time terraform destroy", "nice -n 5 helm upgrade r c", "nohup terraform apply",
    "command kubectl delete pod x", "kubectl get secret x -o yaml | base64 -d",
    "az account get-access-token | jq -r .accessToken",
]
# documented gaps: these spellings and verbs get past the rules (README: a backstop, not a sandbox)
MISSED = [
    "terraform 'apply'", "kubectl 'delete' pod x", "terraform \\apply", "terraform ap''ply",
    "bash -c 'terraform apply'", "sh -c \"kubectl delete pod x\"", "eval \"terraform apply\"",
    "kubectl get pods -o name | xargs -n1 kubectl delete", "terraform $VERB", "terraform ${V:-apply}",
    "./terraform apply", "/usr/bin/kubectl delete pod x", "terraform.exe apply", "kubectl.exe delete pod x",
    "sudo terraform apply", "env FOO=1 terraform apply", "watch -n1 kubectl delete pod x",
    "kubectl get Secret x -o yaml",
    "terraform test", "terraform init -migrate-state", "terraform state replace-provider a b", "terraform login",
    "terraform output db_password", "helm test r", "helm repo add x https://y", "kubectl attach pod -it",
    "kubectl proxy", "kubectl auth reconcile -f x.yaml", "kubectl certificate approve csr1",
    "az vm resize -g rg -n vm --size x", "az storage account show-connection-string -n sa -g rg",
    "az storage account generate-sas --account-name sa", "az webapp deployment list-publishing-profiles -n w -g rg",
]
# read-only commands that a rule asks about anyway (README: false positives)
KNOWN_FALSE_POSITIVES = [
    "kubectl --context prod auth can-i create pods", "kubectl -n x auth can-i delete deployments",
    "kubectl -n x logs deploy/web -c debug --tail 5", "helm -n x diff upgrade r ./chart",
    "kubectl get secretproviderclass -A", "az group show -n set -o json",
]
# the same, Bash only: Claude Code also matches a rule against the whole command line
KNOWN_FALSE_POSITIVES_BASH = [
    "kubectl get pods -A | grep -i secret", "kubectl -n x get pods | grep run | head",
    "az account show && npm run build", "az group list -o tsv && git add .",
]
# none of these may match a cloud guardrail
READ_ONLY = [
    "terraform version", "terraform validate", "terraform fmt -check", "terraform plan",
    "terraform plan -out=apply.tfplan", "terraform plan -out apply.tfplan", "terraform -chdir=x plan -var env=apply",
    "terraform plan -target=module.apply_x", "terraform plan -destroy", "terraform show", "terraform show tfplan",
    "terraform output", "terraform output db_name", "terraform output -no-color", "terraform state list",
    "terraform state show azurerm_x.y", "terraform providers", "terraform -chdir=x plan", "terraform init",
    "terraform init -upgrade", "terraform workspace list", "terraform workspace show",
    "kubectl get pods", "kubectl get pods -n x -o wide", "kubectl get deploy,svc -A", "kubectl describe pod x",
    "kubectl describe secret x", "kubectl logs x -f --since=1h", "kubectl logs proxy-abc",
    "kubectl logs job/delete-old", "kubectl top nodes", "kubectl version --client", "kubectl api-resources",
    "kubectl config current-context", "kubectl config get-contexts", "kubectl config get-contexts -o name",
    "kubectl config view", "kubectl config view --minify", "kubectl explain pod.spec", "kubectl diff -f x.yaml",
    "kubectl auth can-i create pods", "kubectl auth can-i delete deployments -n x", "kubectl get pods -l app=delete",
    "kubectl get events --field-selector reason=Killing", "kubectl rollout status deploy/x",
    "kubectl -n x rollout status deploy/x", "kubectl rollout history deploy/x",
    "kubectl get pods --sort-by=.metadata.creationTimestamp", "kubectl -n x get pods",
    "kubectl --context prod get pods", "kubectl get configmap x -o yaml", "kubectl get pods -o name | head",
    "helm list -A", "helm list -n x", "helm status r", "helm history r", "helm get notes r", "helm get metadata r",
    "helm get -n x notes r", "helm get --namespace x metadata r", "helm show values bitnami/x",
    "helm search repo upgrade", "helm search hub install", "helm lint chart", "helm template r chart", "helm version",
    "helm repo list", "helm env", "helm -n x list",
    "az account show", "az account list", "az group show -n x", "az group list", "az group show -n delete-me",
    "az resource list --tag env=prod", "az aks show -g rg -n c", "az aks list",
    "az aks nodepool list -g rg --cluster-name c", "az keyvault show -n kv", "az keyvault list",
    "az keyvault secret list --vault-name kv", "az keyvault key list --vault-name kv", "az identity show -n x -g rg",
    "az role assignment list --assignee x", "az role definition list", "az network vnet show -g rg -n v",
    "az acr show -n r", "az acr repository list -n r", "az monitor metrics list --resource x --metric y",
    "az pipelines runs list", "az pipelines runs show --id 1", "az pipelines list", "az pipelines show --name x",
    "az repos pr show --id 1", "az repos pr list", "az repos list", "az boards work-item show --id 1",
    "az devops configure -l", "az aks get-versions -l westeurope", "az aks get-upgrades -g rg -n c",
    "az vm list-ip-addresses", "az network public-ip list", "az monitor diagnostic-settings list --resource x",
    "az ad sp list --display-name x", "az storage queue list --account-name sa",
    "az servicebus queue show -n q --namespace-name n -g rg", "az version",
    "git status", "jq . x.json", "ls -la",
]

# flags that stand before the verb, per tool: every probe above is also run in this spelling
FLAGS = {"terraform": "-chdir=infra", "kubectl": "--context prod -n x", "helm": "--kube-context prod -n x"}


def flags_before(cmd: str):
    tool, _, rest = cmd.partition(" ")
    return f"{tool} {FLAGS[tool]} {rest}" if tool in FLAGS and rest and not rest.startswith("-") else None


ASK_PLAIN = ASK_CHANGE + ASK_SECRET  # run for both tools
ASK_FLAGS = [c for c in map(flags_before, ASK_PLAIN) if c]
ASK_ALL = list(dict.fromkeys(ASK_PLAIN + ASK_FLAGS))

# the allow rules of permissions.json that an ask rule of cloud-guardrails.json overrides on purpose (README, $comment):
# each with commands that the allow rule would run unprompted and the guardrail asks about
OVERLAPS = {
    "Bash(kubectl get *)": ["kubectl get secret x -o yaml", "kubectl get secrets -A", "kubectl get cm,secret -n x",
                            "kubectl get --raw /api/v1/namespaces/x/secrets"],
    "Bash(helm get *)": ["helm get values r", "helm get manifest r", "helm get hooks r", "helm get all r",
                         "helm get -n x values r", "helm get --namespace x manifest r"],
    "Bash(terraform output *)": ["terraform output -json", "terraform output -raw db_password"],
    "Bash(terraform show *)": ["terraform show -json tfplan"],
}


@pytest.mark.parametrize("cmd", ASK_ALL)
def test_cloud_asks_bash(cmd):
    assert decide(cmd, ask=CLOUD) == "ask"


@pytest.mark.parametrize("cmd", ASK_ALL)
def test_cloud_asks_powershell(cmd):
    assert decide(cmd, ask=CLOUD, tool="PowerShell") == "ask"
    assert decide(cmd.upper(), ask=CLOUD, tool="PowerShell") == "ask"  # PowerShell rules ignore case


@pytest.mark.parametrize("cmd", ASK_SHELL)
def test_cloud_asks_compound_and_wrapped_commands(cmd):
    assert decide(cmd, ask=CLOUD) == "ask"


@pytest.mark.parametrize("cmd", MISSED)
def test_cloud_known_gaps_stay_documented(cmd):
    assert decide(cmd, ask=CLOUD) != "ask", "now matched: update MISSED and the README backstop paragraph"


@pytest.mark.parametrize("tool", ["Bash", "PowerShell"])
@pytest.mark.parametrize("cmd", KNOWN_FALSE_POSITIVES)
def test_cloud_known_false_positives_stay_documented(cmd, tool):
    assert decide(cmd, ask=CLOUD, tool=tool) == "ask", "no longer asked: update KNOWN_FALSE_POSITIVES and the README"


@pytest.mark.parametrize("cmd", KNOWN_FALSE_POSITIVES_BASH)
def test_cloud_known_false_positives_of_the_whole_command_line(cmd):
    assert decide(cmd, ask=CLOUD) == "ask", "no longer asked: update KNOWN_FALSE_POSITIVES_BASH and the README"
    assert all(decide(part, ask=CLOUD) != "ask" for part in split_commands(cmd)), "a part of the chain asks on its own"


@pytest.mark.parametrize("tool", ["Bash", "PowerShell"])
@pytest.mark.parametrize("cmd", READ_ONLY)
def test_cloud_leaves_read_only_commands_alone(cmd, tool):
    assert decide(cmd, ask=CLOUD, tool=tool) != "ask", cmd


def test_cloud_every_bash_rule_has_a_powershell_mirror():
    bash, ps = specs(CLOUD, "Bash"), specs(CLOUD, "PowerShell")
    assert bash and sorted(bash) == sorted(ps)
    assert len(bash) + len(ps) == len(CLOUD), "only Bash(...) and PowerShell(...) rules"


def test_cloud_flags_before_twins():
    s = set(specs(CLOUD))
    for spec in s:
        m = re.fullmatch(r"(terraform|kubectl|helm) (.*)", spec)
        if not m:
            continue  # az rules have no flags-before form: any text may stand before the verb
        tool, rest = m.groups()
        if rest.startswith("-* "):
            body = rest[3:]
            plain = f"{tool} {body}" if body.endswith("*") else f"{tool} {body} *"
            assert plain in s, f"{spec}: plain twin {plain!r} missing"
        else:
            assert f"{tool} -* {rest}" in s, f"{spec}: flags-before twin missing"


def test_cloud_every_rule_is_pinned_by_a_command():
    """Deleting any one rule must turn one of the probe commands from asked into not asked, so a verb in the README
    table cannot lose its rule unnoticed. A probe counts for a rule when no other rule asks about it."""
    covered = {"helm -* plugin* install *"}  # nothing to pin: the .* of `helm -* install *` already spans 'plugin'
    every = specs(CLOUD)
    for spec in every:
        others = [o for o in every if o != spec]
        if spec in covered:
            assert any(matches(o, "helm -n x plugin install x") for o in others)
            continue
        assert any(matches(spec, c) and not any(matches(o, c) for o in others) for c in ASK_ALL), (
            f"{spec!r}: add a command to ASK_CHANGE or ASK_SECRET that only this rule asks about")


def test_cloud_overrides_only_the_documented_allow_rules():
    allow = rules("permissions.json", "allow") + rules("permissions-trusted-repo.json", "allow")
    for rule, cmds in OVERLAPS.items():
        assert rule in allow, rule
        for cmd in cmds:
            assert decide(cmd, allow=[rule]) == "allow", f"{cmd} no longer runs unprompted under {rule}"
            assert decide(cmd, allow=allow, ask=CLOUD) == "ask", cmd
    # every other way to use each allow rule stays allowed: probe each rule with typical arguments
    for rule in allow:
        spec = RULE_RE.fullmatch(rule).group(2)
        tails = ["", " -n foo", " pods -o wide", " foo --output json -g rg --name x"] if spec.endswith(" *") else [""]
        for tail in tails:
            cmd = spec[:-2] + tail if spec.endswith(" *") else spec
            if decide(cmd, ask=CLOUD) == "ask":
                pytest.fail(f"{rule} is overridden for {cmd!r}: list it in OVERLAPS, the README and the $comment")


def test_cloud_docs_name_every_overlap():
    comment = load("cloud-guardrails.json")["$comment"]
    readme = (REPO / "README.md").read_text(encoding="utf-8")
    assert "cloud-guardrails.json" in readme
    assert "do not reword it" in (SETTINGS / "user-instructions.md").read_text(encoding="utf-8").replace("\n  ", " ")
    for rule in OVERLAPS:
        spec = RULE_RE.fullmatch(rule).group(2)
        assert spec in comment, f"{spec!r} missing from the $comment of cloud-guardrails.json"
        assert f"`{spec}`" in readme, f"`{spec}` missing from the README"


def test_cloud_readme_az_row_matches_the_az_rules():
    """The az row of the README table and the az rules name the same verbs: none without a rule, none without a mention."""
    section = (REPO / "README.md").read_text(encoding="utf-8").split("#### Cloud guardrails", 1)[1].split("\n## ", 1)[0]
    row = next(line for line in section.splitlines() if line.startswith("| `az` |"))
    named = re.findall(r"`([^`]+)`", " ".join(row.strip("|").split("|")[1:]))
    assert len(named) > 30, named

    def candidates(token: str) -> set:  # the rule shapes the table can stand for
        out = {f"az {token} *", f"az * {token} *"}
        if " --" in token:  # 'acr login --expose-token' is the rule 'az acr login *--expose-token*'
            head, flag = token.split(" --", 1)
            out.add(f"az {head} *--{flag}*")
        return out

    az_specs = {s for s in specs(CLOUD) if s.startswith("az ")}
    for token in named:
        assert candidates(token) & az_specs, f"the README az row names `{token}` and no rule asks about it"
    for spec in az_specs:
        assert any(spec in candidates(t) for t in named), f"`{spec}` is a rule that the README az row does not name"


def readme_merge_script() -> str:
    """The bash block of README 'Cloud guardrails', with its curl line swapped for a copy of the local file
    (named by $CLOUD_FILE, so the script text holds no path)."""
    readme = (REPO / "README.md").read_text(encoding="utf-8")
    assert "#### Cloud guardrails" in readme, "README lost its 'Cloud guardrails' section"
    found = re.search(r"```bash\n(.*?)```", readme.split("#### Cloud guardrails", 1)[1], re.S)
    assert found, "README 'Cloud guardrails' has no bash block"
    script, n = re.subn(r'curl -fsSL \S+/cloud-guardrails\.json -o "\$src"', 'cp "$CLOUD_FILE" "$src"', found.group(1))
    assert n == 1, "the README snippet no longer downloads settings/cloud-guardrails.json with one curl line"
    return script


@pytest.mark.skipif(not (shutil.which("bash") and shutil.which("jq")), reason="needs bash and jq")
def test_readme_merge_snippet_unions_the_ask_rules(tmp_path):
    cfg = tmp_path / "cfg"
    cfg.mkdir()
    existing = {"model": "x", "permissions": {"allow": ["Bash(ls)"], "ask": ["Bash(git push *)", "Bash(terraform apply *)"]}}
    (cfg / "settings.json").write_text(json.dumps(existing), encoding="utf-8")
    env = {"PATH": os.environ["PATH"], "CLAUDE_CONFIG_DIR": str(cfg), "TMPDIR": str(tmp_path),
           "CLOUD_FILE": str(SETTINGS / "cloud-guardrails.json")}
    script = readme_merge_script()
    for _ in range(2):  # the second run changes nothing
        r = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
        assert r.returncode == 0 and not r.stderr, r.stderr
        merged = json.loads((cfg / "settings.json").read_text(encoding="utf-8"))
        assert merged["model"] == "x" and merged["permissions"]["allow"] == ["Bash(ls)"]
        assert merged["permissions"]["ask"][:2] == existing["permissions"]["ask"]  # existing entries first
        assert merged["permissions"]["ask"][2:] == [r for r in CLOUD if r != "Bash(terraform apply *)"]  # no duplicate
    (cfg / "settings.json").write_text("{ not json", encoding="utf-8")
    r = subprocess.run(["bash", "-c", script], env=env, capture_output=True, text=True)
    assert "not merged" in r.stderr and (cfg / "settings.json").read_text(encoding="utf-8") == "{ not json"


# --- the model itself ----------------------------------------------------------------------------------------
@pytest.mark.parametrize("spec,cmd,expected", [
    ("ls *", "ls", True), ("ls *", "ls -la", True), ("ls *", "lsof", False), ("ls*", "lsof", True),
    ("git log * main", "git log --oneline main", True), ("git log * main", "git log main", False),
    ("* --help *", "npm --help x", True), ("* --help *", "npm --help", False),
    ("terraform * apply *", "terraform apply", False), ("terraform * apply *", "terraform -chdir=x apply -x", True),
    ("terraform -* apply", "terraform -chdir=x apply", True), ("terraform -* apply *", "terraform -chdir x apply -y", True),
    ("terraform -* apply *", "terraform plan -out apply.tfplan", False), ("npm test", "npm  test", True),
    ("npm test", "npm test --watch", False), ("az * delete *", "az aks nodepool delete -n x", True),
])
def test_model_wildcards(spec, cmd, expected):
    assert matches(spec, cmd) is expected


def test_model_case_and_splitting():
    assert matches("terraform apply *", "TERRAFORM Apply -x", ignore_case=True)
    assert not matches("terraform apply *", "TERRAFORM Apply -x")
    assert split_commands("a && b || c; d | e |& f & g\nh") == list("abcdefgh")
    assert split_commands("echo 'a && b' && \"c;d\"") == ["echo 'a && b'", '"c;d"']
    ask, allow = ["Bash(kubectl delete *)"], ["Bash(kubectl get *)"]
    assert decide("kubectl get pods && kubectl delete pod x", allow=allow, ask=ask) == "ask"
    assert decide("kubectl get pods && kubectl top nodes", allow=allow, ask=ask) == "prompt"
    assert decide("kubectl get pods | head", allow=allow + ["Bash(head)"], ask=ask) == "allow"
    assert decide("FOO=1 kubectl delete pod x", allow=allow, ask=ask) == "ask"  # ask matches past VAR=value
    assert decide("FOO=1 kubectl get pods", allow=allow, ask=ask) == "prompt"  # allow does not (model: unsafe variable)
    assert decide("timeout 5 kubectl get pods", allow=allow, ask=ask) == "allow"
    assert decide("xargs kubectl delete pod", ask=ask) == "ask"
    assert decide("xargs -n1 kubectl delete pod", ask=ask) == "prompt"
    # an ask rule with a leading wildcard also sees the whole command line (Bash tool); a part of the chain does not
    wide = ["Bash(kubectl -* run *)"]
    assert decide("kubectl -n x get pods | grep run | head", ask=wide) == "ask"
    assert decide("kubectl -n x get pods", ask=wide) == "prompt" and decide("grep run", ask=wide) == "prompt"
