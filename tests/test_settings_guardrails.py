"""settings/claude-guardrails.json: which commands its permissions.ask rules catch.

`matches` follows Claude Code's documented Bash/PowerShell rule matching (code.claude.com/docs/en/permissions,
"Wildcard patterns" and "PowerShell"): `*` matches any text including spaces, everything else is literal, a
trailing ` *` that is the rule's only wildcard also matches the bare command, and PowerShell rules ignore case.
It checks the rules say what we mean; it is not Claude Code, so it does not model compound-command splitting,
wrapper stripping or PowerShell alias canonicalization.
"""
import json
import re
from pathlib import Path

import pytest

GUARDRAILS = Path(__file__).resolve().parent.parent / "settings" / "claude-guardrails.json"
ASK = json.loads(GUARDRAILS.read_text(encoding="utf-8"))["permissions"]["ask"]
RULE = re.compile(r"^(Bash|PowerShell)\((.*)\)$")
INFRA = ("kubectl ", "helm ", "terraform ")


def parse(rule: str) -> tuple[str, str]:
    m = RULE.match(rule)
    assert m, f"not a Bash/PowerShell rule: {rule}"
    return m.group(1), m.group(2)


def matches(pattern: str, command: str, ignore_case: bool = False) -> bool:
    flags = re.DOTALL | (re.IGNORECASE if ignore_case else 0)
    rx = ".*".join(re.escape(part) for part in pattern.split("*"))
    if re.fullmatch(rx, command, flags):
        return True
    return pattern.count("*") == 1 and pattern.endswith(" *") and \
        re.fullmatch(re.escape(pattern[:-2]), command, flags) is not None


def asks(tool: str, command: str) -> bool:
    return any(t == tool and matches(p, command, ignore_case=(tool == "PowerShell"))
               for t, p in map(parse, ASK))


# --- structure --------------------------------------------------------------------------------------

def test_rules_are_unique_and_well_formed():
    assert len(ASK) == len(set(ASK))
    for rule in ASK:
        parse(rule)


def test_every_infra_rule_is_mirrored_for_powershell():
    bash = {p for t, p in map(parse, ASK) if t == "Bash" and p.startswith(INFRA)}
    ps = {p for t, p in map(parse, ASK) if t == "PowerShell" and p.startswith(INFRA)}
    assert bash and bash == ps


def test_every_infra_subcommand_rule_has_a_global_flags_twin():
    for tool, pattern in map(parse, ASK):
        prog, _, rest = pattern.partition(" ")
        if pattern.startswith(INFRA) and not rest.startswith("*"):
            twin = f"{tool}({prog} * {rest})"
            assert twin in ASK, f"{tool}({pattern}) has no global-flags twin {twin}"


# --- what asks ----------------------------------------------------------------------------------------

ASKS = [
    "kubectl delete pod web-0",
    "kubectl -n prod delete deployment api",
    "kubectl --context prod-aks delete ns team-a",
    "kubectl apply -f manifests/",
    "kubectl apply -k overlays/prod --server-side",
    "kubectl replace --force -f pod.yaml",
    "kubectl patch deploy api -p '{\"spec\":{\"replicas\":0}}'",
    "kubectl edit cm app-config",
    "kubectl scale deploy api --replicas=0",
    "kubectl drain aks-node-1 --ignore-daemonsets",
    "kubectl taint nodes n1 dedicated=gpu:NoSchedule",
    "kubectl rollout undo deploy/api",
    "kubectl -n prod rollout restart deploy/api",
    "helm uninstall ingress-nginx -n ingress",
    "helm delete my-release",
    "helm --kube-context prod uninstall api",
    "helm install api ./chart -f values-prod.yaml",
    "helm upgrade --install api ./chart",
    "helm -n prod upgrade api ./chart",
    "helm rollback api 3",
    "terraform apply",
    "terraform apply -auto-approve",
    "terraform apply tfplan",
    "terraform -chdir=envs/prod apply",
    "terraform -chdir=envs/prod apply -auto-approve",
    "terraform destroy",
    "terraform -chdir=envs/dev destroy",
    "terraform destroy -target=azurerm_resource_group.rg",
    "terraform import azurerm_resource_group.rg /subscriptions/x/resourceGroups/rg",
    "terraform taint azurerm_linux_virtual_machine.vm",
    "terraform untaint azurerm_linux_virtual_machine.vm",
    "terraform force-unlock 1234-abcd",
    "terraform state rm module.aks",
    "terraform -chdir=envs/prod state mv a b",
    "terraform state push terraform.tfstate",
    "terraform workspace delete feature-x",
]

DOES_NOT_ASK = [
    "kubectl get pods -A",
    "kubectl -n prod describe deploy api",
    "kubectl diff -f manifests/",
    "kubectl logs deploy/api --since=1h",
    "kubectl config delete-context old",       # kubeconfig only; delete-context is one word
    "kubectl config set-context --current --namespace=prod",
    "kubectl rollout status deploy/api",
    "kubectl rollout history deploy/api",
    "helm list -A",
    "helm template api ./chart",
    "helm lint ./chart",
    "terraform plan",
    "terraform plan -destroy",
    "terraform -chdir=envs/prod plan -out tfplan",
    "terraform validate",
    "terraform fmt -check -recursive",
    "terraform state list",
    "terraform state show module.aks",
    "terraform workspace list",
    "terraform output -json",
]

KNOWN_OVER_ASK = [
    "kubectl auth can-i delete pods",           # read-only, but `delete` follows other words
    "helm diff upgrade api ./chart",            # helm-diff plugin: shows the upgrade, changes nothing
]


@pytest.mark.parametrize("tool", ["Bash", "PowerShell"])
@pytest.mark.parametrize("command", ASKS)
def test_state_changing_commands_ask(tool, command):
    assert asks(tool, command), f"{tool}: {command}"


@pytest.mark.parametrize("tool", ["Bash", "PowerShell"])
@pytest.mark.parametrize("command", DOES_NOT_ASK)
def test_read_only_commands_do_not_ask(tool, command):
    assert not asks(tool, command), f"{tool}: {command}"


@pytest.mark.parametrize("command", KNOWN_OVER_ASK)
def test_documented_over_asks_still_ask(command):
    # Listed in the $comment and README; if this starts failing, update both.
    assert asks("Bash", command)


def test_powershell_rules_ignore_case():
    assert asks("PowerShell", "KUBECTL Delete pod x")
    assert not asks("Bash", "KUBECTL Delete pod x")


def test_existing_git_rules_unchanged():
    assert asks("Bash", "git push origin main")
    assert asks("Bash", "git -C repo reset --hard")
    assert not asks("Bash", "git status")
