---
name: component-documentation
description: Analyze a platform component and produce complete operational documentation — purpose, architecture, deployment order, configuration per environment, availability, monitoring, backup and recovery, runbook procedures, risks and ownership, with section packs for edge/ingress, telemetry, alerting, security tooling, cluster services and Terraform infrastructure. Use when asked to document, audit, review, explain or onboard someone onto any component of an infrastructure repository — an ingress or API gateway, a logging/metrics/profiling pipeline, an alerting setup, a security scanner, a certificate authority, a storage class, or a Terraform stack — even when the user only says "document this chart", "write up how X works", "how does traffic/data get here", "maak een INGRESS.md", "leg vast wat dit doet", or names a tool (Emissary, NGINX, Traefik, cert-manager, Loki, Prometheus, Alloy, Grafana, Pyroscope, OpenCost, Alertmanager, Falco, Trivy).
---

# Platform Component Documentation

Act as a senior platform engineer and technical writer. The output must let four different
readers succeed: a new engineer learning the component, an operator during an incident, a
security reviewer assessing exposure, and an auditor tracing the architecture.

The section structure — core sections plus the packs that apply to this component type — is in
[references/document-template.md](references/document-template.md). Read it before writing.
This file describes how to get the facts that fill it.

## The one rule that matters

**Never write a fact you have not read in a file or observed in a running system.** The template
asks for things many components simply do not have (a WAF, an RPO/RTO, retention limits, named
owners). The failure mode of this skill is a confident, well-formatted document full of
plausible inventions — which is worse than no document, because it will be trusted during an
incident and cited in an audit.

When a fact is not established, write one of these verbatim instead of guessing:

- `**Not present**` / `**Niet aanwezig**` — verified absent; say where you looked.
- `**Unknown**` / `**Onbekend**` — not verifiable from the sources available.
- `**Unknown — ask <team/role>**` — knowable, but not from code.

A section that is honestly half unknown is a working backlog. An invented section is a
liability. Collect every unknown into the *Risks and technical debt* section as well.

## Step 0 — Scope and classify

Establish two things before searching.

**Which component?** If the user named one, use it. If they asked for "the repo" or were vague,
list the candidates from the component map below and ask which one — do not silently document
all of them. Documenting several means **one document per component**, never one giant file.

**Which family?** The family decides which section packs apply. Classify by what the component
*does*, not by which directory it sits in:

| Family | Recognise it by | Extra packs |
|---|---|---|
| **Edge / ingress** | terminates external traffic, holds hostnames and certificates | DNS, TLS & certificates, routing table, exposure & security controls |
| **Telemetry pipeline** | collects, ships, stores or renders metrics/logs/traces/profiles | data flow, retention & storage, cardinality & cost, query access |
| **Alerting / notification** | evaluates rules and delivers messages | rule inventory, routing & grouping, silencing, rule tests |
| **Security tooling** | detects, scans or enforces policy | what it detects, rule sources, exceptions, findings flow |
| **Cluster service** | serves other workloads in-cluster (PKI, storage, RBAC, bootstrap) | consumers, lifecycle & rotation, blast radius |
| **Cloud infrastructure** | Terraform-managed cloud resources | resource inventory, state backend, identities & permissions, drift |

A component can span two families. The API gateway is edge *and* a cluster service; document
both packs rather than picking one.

## Step 1 — Locate the evidence

Work from code first; the repository is the source of truth for intent. Use a live system only
to confirm what code cannot tell you (actual replica counts, real issued certificates, load
balancer IPs, current retention).

Always:

| Looking for | Search for |
|---|---|
| What it is and which version | chart name and pinned version in the CI/CD template, plus a central versions file |
| How it is deployed and in what order | the pipeline template that installs it, and the stage/job that template runs in |
| Per-environment differences | `*.values.yaml`, `*.tfvars`, `*.auto.tfvars` next to the chart or module |
| What it depends on | which job the deploying job `dependsOn`, and which secrets/CRDs/namespaces it assumes exist |
| Availability posture | `replicaCount`, `PodDisruptionBudget`, `topologySpreadConstraints`, probes, resource limits |
| Whether it is monitored | scrape configs, dashboards and alert rules that name this component |
| Who may reach it | `NetworkPolicy`, RBAC objects, namespace labels |
| Secrets it uses | Key Vault references, `overrideValues` on the Helm command line, Secret templates |

Then the family-specific sweep:

| Family | Also search for |
|---|---|
| Edge / ingress | `Ingress`, `HTTPRoute`, `Host`, `Listener`, `Mapping`, `IngressRoute`, `Certificate`, `ClusterIssuer`, `tlsSecret`, DNS records in Terraform, `loadBalancerSourceRanges`, WAF/Front Door/Application Gateway resources |
| Telemetry pipeline | scrape/relabel/drop rules, `retention`, `persistence`, storage class and volume size, datasource definitions, TLS between components |
| Alerting / notification | `groups:`/`rules:` files, `route:`/`receiver:` config, `for:` durations, recording rules the alerts join on, unit tests under `tests/` |
| Security tooling | rule files and their upstream source, exclusions and exceptions, where findings land (metrics, logs, dashboards) |
| Cluster service | who consumes it (grep the secret/configmap/class name across the repo), rotation and expiry settings |
| Cloud infrastructure | `backend` blocks, `azurerm_role_assignment`, managed identities, `variables.tf` descriptions, what the pipeline passes as `-var-file` |

Live checks, when a cluster is reachable and the user has authorised it:

```bash
kubectl -n <ns> get all
kubectl -n <ns> get pdb,networkpolicy,servicemonitor
kubectl get certificate,clusterissuer -A
helm -n <ns> get values <release>          # what is actually deployed, not what is in git
```

## Step 2 — Reconcile intent against reality

Note every place where the code and the running system disagree, and every reference that points
at something that no longer exists — a renewal job naming a deleted `Certificate`, a scrape job
for a removed exporter, a DNS record without a backing host, a values key the chart no longer
reads. These mismatches are the highest-value content in the whole document: they are exactly
what nobody remembers and what breaks at 03:00. Put them in *Risks and technical debt* with the
file and line.

Two recurring traps worth checking explicitly:

- **A Helm values key that the chart silently ignores** because it is nested wrong or was renamed
  upstream. Verify keys against `helm show values <chart> --version <pinned>` before trusting
  them; a wrong key does not error, it just does nothing.
- **A component that looks monitored but is not** — generic per-namespace alerts firing while
  the component's own signals (request rate, queue depth, ingestion errors, certificate expiry)
  are scraped by nothing.

Also record the things that **look** wrong but are correct, with the reason. A future reader will
otherwise "fix" them.

## Step 3 — Write

Follow [references/document-template.md](references/document-template.md): every core section,
plus the packs for this component's family. Standards:

- **Why before how.** Every configuration choice gets a sentence of rationale. If the rationale
  is unknown, say so — that is a finding.
- **Tables over prose** for anything enumerable. Prose only for reasoning.
- **One Mermaid diagram** of the real components, and a flow diagram (request path, data path,
  or dependency chain, whichever fits the family). No idealised boxes that do not exist; draw
  absent-but-expected hops as dashed and label them as absent.
- **Expand every acronym on first use** (TLS, ACME, CA, CRD, PDB, RBAC, WAF, RPO, RTO, SPOF).
- **Assume zero prior knowledge** of this environment, but competence in Kubernetes.
- **Link to files, do not paste them.** Relative Markdown links from the document's own location;
  verify every link and heading anchor resolves before finishing.
- **Call out security and operational risk explicitly**, in its own sentence, not softened.
- **Match the language of the surrounding documentation** — do not introduce a second language
  into a repository that already picked one.
- Run the repository's Markdown linter if there is one, or at least keep table delimiter rows and
  fenced-code languages consistent with neighbouring documents.

## Step 4 — Place it and keep it alive

One canonical location per component. **If the component already has a document, update it** —
never create a second one next to it.

- A component with its own chart directory: that directory's `README.md`.
- A cross-cutting subject that spans charts and pipelines (ingress and TLS, the whole
  observability stack): `docs/<SUBJECT>.md`.

Add a pointer from the repository README, and from the chart README to the `docs/` file when both
exist. End the document with the instruction that changes to this component update the document
in the same pull request — documentation that is not updated with the change becomes a second
source of truth, which is worse than one.

## Repository-specific knowledge

A per-repository component map (directories → family → namespace → existing doc) speeds this
skill up considerably, but it belongs in that repository — a project-level skill or `CLAUDE.md`
— not here. When one exists, read it first and verify it before relying on it.
