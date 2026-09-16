# Document structure

Two layers: **core sections**, which every component gets, and **section packs**, added
according to the family determined in Step 0. Keep a section even when most of it is unknown —
a thin section is a visible gap; a deleted section is an invisible one.

Markers, used verbatim: `**Not present**` / `**Niet aanwezig**` (verified absent),
`**Unknown**` / `**Onbekend**`, `**Unknown — ask <team/role>**`. Match the document's language.

---

## Core sections

### Summary

For a reader who will read nothing else.

- What the component does and which problem it solves for this organisation.
- Which technology, which version, which chart or module.
- Which environments it runs in, and any environment where it is deliberately absent.

Call out anything that would mislead someone applying general knowledge of the tool — a
non-standard resource model, a fork, a replaced default. State it here, not three sections down.

### Architecture

A Mermaid diagram of the real components, then prose covering what talks to what, where state
lives, and where trust boundaries sit. Draw absent-but-expected hops dashed and label them.

Follow with a source table:

| Onderdeel | Namespace | Bron | Uitgerold door |
|---|---|---|---|

Name the version variable rather than repeating the number in prose, and link the central
versions file.

### Deployment order

Numbered steps of the pipeline that installs it, **with the reason each wait, patch or ordering
constraint exists**. A wait step whose purpose is not written down gets deleted by the next
person who finds it slow. State which job it depends on and what it assumes already exists.

### Configuration per environment

| Omgeving | <key setting> | <key setting> | … |
|---|---|---|---|

Include every setting that differs between environments, and flag anything where a
non-production environment is configured like production (a production endpoint, a shared
resource group, a real credential).

### Availability and resilience

| Maatregel | Waarde |
|---|---|

Replicas, PodDisruptionBudget (PDB), topology spread, probes, resource limits, zone spread.

Answer explicitly: what happens when a node fails, when a pod fails, when the thing this
component depends on fails. Name the single points of failure (SPOF) plainly.

### Monitoring

Whether **this component itself** is observable: are its own metrics scraped, are its logs
collected, is there a dashboard, which alerts fire on it and where do they go.

| Alert | Trigger | Ontvanger |
|---|---|---|

Generic per-namespace alerts are not component monitoring. If the component's own signals are
scraped by nothing, say so — it is one of the most common and most costly gaps.

### Backup and recovery

Strategy, frequency, retention. Recovery procedure for the realistic failure modes, including
state that is *not* in git (issued certificates, account keys, persistent volumes, cloud state).

Give RPO (recovery point objective) and RTO (recovery time objective) where known. "Everything
is redeployed from git" is a legitimate strategy; then the RTO is the pipeline duration and the
RPO is zero for everything that is actually in git — name what is not.

### Operational procedures

Numbered, copy-pasteable steps for the tasks people actually perform: the most common change,
the most common failure, and how to verify the component is healthy. Each procedure states where
it is performed (pipeline, repository, cluster) and what confirms success.

Include a subsection **"Dingen die fout lijken maar het niet zijn"** listing configuration that
looks wrong to a knowledgeable reader but is correct, with the reason. This prevents the next
person from "fixing" it.

### Risks and technical debt

| Risico | Impact | Bewijs | Voorgestelde actie |
|---|---|---|---|

Every mismatch from Step 2, every unknown from the sections above, plus single points of
failure, manual processes and scaling limits. Evidence is a file and line, not an assertion.

### Ownership

| Gebied | Eigenaar |
|---|---|

Adapt the rows to the component. Unknown owners stay visible as `**Unknown — ask …**`; an email
address found in a config file is a contact, not necessarily an owner — say which it is.

### References

Charts, modules, pipelines, dashboards, runbooks, upstream documentation. Prefer relative links
to files in this repository over descriptions of them.

### Maintenance footer

One closing line: changes to this component update this document in the same pull request.

---

## Section pack — Edge / ingress

### Network flow

`Client → DNS → Firewall/WAF → Load Balancer → Ingress Controller → Service → Pod`, as a diagram
plus prose. Document public endpoints, private endpoints and internal traffic paths separately,
and state **where TLS terminates** and whether traffic is re-encrypted behind that point.

### Ingress controllers

| Property | Value |
|---|---|
| Name / Namespace / Version / Replicas | |
| Load Balancer Type | |
| High Availability Configuration | |

Explain why this controller was chosen over the alternatives, and how failover works at pod,
node and zone level.

### DNS configuration

| Record | Type | Zone | Wijst naar | Beheerd in |
|---|---|---|---|---|

Domains, subdomains, wildcard records, internal and external zones, plus who owns them and how a
change is requested and approved.

### TLS and certificates

| Certificate | Namespace | Issuer | Secret | Dekt | Vernieuwing |
|---|---|---|---|---|---|

Answer: where are certificates stored, how are they rotated and by what, is cert-manager used
and which certificates fall outside it, which TLS versions are accepted. For every certificate
authority, state whether it is publicly trusted or internal, and what trusts it. Explain the
issuer topology — why there is more than one, if there is.

### Exposure and security controls

Authentication (OAuth, OIDC, Entra ID, SAML, mutual TLS, or none at the edge — if authentication
happens in the applications instead, that is a material architectural fact, state it).
Authorization (network policies, RBAC, IP restrictions). Traffic protection (WAF, DDoS, rate
limiting, bot protection) — absent controls are findings. Secrets and where they live.

### Routing table

| Hostname | Namespace | Service | Poort | Pad |
|---|---|---|---|---|

Then rewrite rules, redirects, protocol negotiation, sticky sessions and session affinity. If
routes are also created from other repositories, say so and give the command that lists the live
set — an incomplete table presented as complete is worse than an honest pointer.

---

## Section pack — Telemetry pipeline

### Data flow

Where data enters, what transforms it, where it lands, who reads it. Diagram plus prose. Name
every drop, filter and relabel rule that silently removes data, and which namespaces or targets
they exclude — an exclusion nobody knows about looks like an outage.

### Retention and storage

| Signaal | Waar opgeslagen | Retentie | Volume | Storage class |
|---|---|---|---|---|

State whether retention is configured or defaulted, and what happens when the volume fills.

### Cardinality and cost

Which labels are attached and by what, which of them are unbounded, and any known cardinality
incident. For cost-relevant components, what drives the bill.

### Query access

Who can read the data, through which interface, with which credentials, and whether queries are
authenticated. Include the datasource wiring if a visualisation layer reads from it.

---

## Section pack — Alerting / notification

### Rule inventory

| Alert | Expressie (kort) | `for:` | Severity | Bron |
|---|---|---|---|---|

Group by rule file. Note which recording rules the alerts depend on — an alert that joins on a
missing recording rule silently never fires.

### Routing and grouping

Route tree, matchers, receivers, `group_by`, `repeat_interval`, and which label drives the
routing. State what happens to an alert that matches no specific route.

### Silencing and inhibition

Configured silences, mute timings, inhibition rules, and how an operator adds one during an
incident.

### Tests

Which rules have unit tests, where they live, how to run them, and which rules are untested.

---

## Section pack — Security tooling

### What it detects

Scope and technique, in plain terms: what classes of problem it finds and what it structurally
cannot find. Be explicit about the blind spots — a scanner believed to cover more than it does
is a security risk in itself.

### Rule sources and versions

Upstream rule sets, local additions, how rules are updated, and whether updates are pinned or
floating.

### Exceptions

| Uitzondering | Reden | Toegevoegd door | Vervaldatum |
|---|---|---|---|

Exceptions without an expiry date become permanent; flag them.

### Findings flow

Where findings surface (metrics, logs, dashboard, ticket), who is expected to act, and what the
response expectation is. A detector nobody watches is not a control.

---

## Section pack — Cluster service

### Consumers

| Consument | Wat het gebruikt | Gevolg bij uitval |
|---|---|---|

Find consumers by grepping the secret, ConfigMap, storage class or issuer name across the whole
repository — the dependency is rarely declared anywhere.

### Lifecycle and rotation

Creation, renewal, rotation and expiry of whatever the service hands out. Name what is automatic
and what is a human action, and what warns before an expiry.

### Blast radius

What stops working when this component is down, and whether existing consumers keep running on
cached or already-issued state.

---

## Section pack — Cloud infrastructure (Terraform)

### Resource inventory

| Resource | Type | Doel | Omgeving |
|---|---|---|---|

### State backend

Storage account, container, key, and which pipeline job runs `apply` with which `-var-file`.
State whether locking is in place and who can apply outside the pipeline.

### Identities and permissions

Managed identities, service principals, role assignments and group memberships this module
creates or depends on. Call out anything with broad scope or a shared production resource group.

### Drift and manual changes

Known drift, resources created outside Terraform, and anything that must be imported. If nothing
is known, say the drift status is unverified rather than implying the state is clean.
