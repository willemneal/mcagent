# Enterprise & Compliance Review — mcagent

**Reviewer:** CTO Enterprise Guardian
**Scope:** IDEAS.md, PLAN.md, PROJECT.md
**Date:** 2026-03-15
**Verdict:** Conditional NACK — strong architecture, critical gaps in contract safety, audit trails, and migration strategy.

---

## What Excites Me

I want to be clear: this is a well-conceived project. The core architecture addresses real problems I have lived through — file contention between agents, uncontrolled blast radius, unreviewed bulk changes landing in production. The things that excite me:

**COW isolation is the right primitive.** Every agent getting its own filesystem snapshot via APFS reflink is exactly how I would want this to work. It means an agent cannot corrupt another agent's working state. In an enterprise context, this is the difference between "one agent had a bad run" and "one agent corrupted the workspace and took down five other agents mid-task." This is a genuinely good design decision.

**Stacked PRs with dependency ordering.** This is huge for reviewability. When I have 400 engineers, the number one complaint from my staff engineers is "I can't review this 2000-line PR." Small, ordered PRs that build on each other — this is exactly how I want humans to consume AI-generated changes. The reviewer builds understanding incrementally. I have been asking my own teams to do this for years.

**WASI sandboxing with explicit capabilities.** No ambient authority. Capabilities granted at instantiation. This is a security model I can actually present to a compliance auditor and explain. Docker is fine as a stepping stone, but the WASI direction is correct — provably sandboxed beats "we configured Docker correctly, we think."

**LLM-agnostic via MCP.** Not coupling to a single LLM vendor is strategically correct. I have seen too many projects become locked to a specific model's API and then scramble when pricing changes or the model is deprecated. MCP as the contract layer is smart.

---

## What Concerns Me

### 1. No API Versioning Strategy

This is my biggest concern. The project defines 17+ MCP tools that constitute a public API surface. There is no versioning scheme anywhere in the documents. No `v1/` prefix. No version field in tool responses. No compatibility policy.

What happens when you need to change the schema of `create_isolation`? Every orchestrator agent prompt that calls this tool — and every external integration — breaks. You need to answer this question *before* you ship, not after you have customers.

**Recommendation:** Define a versioning policy now. At minimum:
- Semantic versioning for the MCP server
- A `version` field in every tool response envelope
- A compatibility guarantee: tools in a major version will not remove fields or change field types
- A deprecation policy: deprecated tools/fields get a warning for 2 minor versions before removal

### 2. No Audit Trail for State-Changing Operations

The MCP server exposes tools that create isolation layers, execute commands in sandboxes, write files, destroy agent state, and commit to git branches. Not a single one of these tools mentions audit logging.

For any enterprise customer, this is a non-starter. SOC 2 Type II requires that all state-changing operations on customer-facing systems produce an audit trail. When an agent destroys a COW layer — who initiated it? When was it destroyed? Was the data preserved? Was the destruction authorized?

The IDEAS.md mentions budget ledger events, which is good — but budget tracking is not the same as an audit trail. Budget events track cost. Audit events track *who did what to which resource and whether they were authorized to do it*.

**Recommendation:** Every MCP tool that mutates state must emit an audit event containing:
- `actor` — which agent or user initiated the action
- `action` — the tool name and operation type (create/update/delete)
- `resource` — what was affected (agent ID, file path, branch name)
- `outcome` — success or failure, with error details on failure
- `timestamp` — UTC, immutable
- `authorization` — what capability or permission allowed this action

Store these in an append-only log. Make them queryable. Make them exportable for compliance teams.

### 3. APFS Reflink Is macOS Only

The entire COW filesystem layer depends on APFS `clonefile`. This is a macOS-only syscall. The PROJECT.md lists "APFS reflink — Copy-on-write clones (macOS)" as a core technology, but there is no mention of what happens on Linux or Windows.

If I am deploying this in my enterprise — and I have engineers on Linux and CI/CD pipelines running on Linux — this does not work. The architecture document presents COW as a foundational layer, but it is built on a platform-specific primitive with no fallback.

**Recommendation:** The COW layer needs a platform abstraction:
- macOS: APFS clonefile (current)
- Linux: btrfs reflink, or overlayfs, or a full-copy fallback
- CI/CD: Docker volume mounts or overlayfs
- Document which platforms are supported and which are degraded

### 4. No Data Retention or Cleanup Policy

COW layers contain full copies of the repository. Agent memory stores contain embeddings and potentially customer data. Budget ledgers contain cost data. None of these have a defined retention policy.

Under GDPR, if an agent processes a task that includes personal data (a customer's name in an issue title, PII in a bug report), that data now exists in:
- The COW layer's filesystem
- Potentially the agent's memory store
- The budget ledger's `detail` field
- Git commits on agent branches

What is the retention period? How does a customer exercise their right to deletion? How do you find all copies of their data across agent artifacts?

**Recommendation:** Define a data lifecycle:
- COW layers: destroyed after task completion, with configurable retention for debugging
- Agent memory: TTL per entry (I see this mentioned in IDEAS.md — good, but needs to be enforced, not optional)
- Budget ledger: retention period aligned with financial record-keeping requirements
- Git branches: pruning policy for completed agent branches

### 5. The Meta Mono-Repo Idea Is a Contract Nightmare

The IDEAS.md proposes forking customer repos to a `model-c-agent` GitHub org, spawning agents on the forks, and coordinating via PRs. This raises several red flags:

- **Data sovereignty:** Customer code is now in a third-party GitHub org. Where is that org hosted? Who has access? Is the fork deleted after the task?
- **License compliance:** Forking a private repo to another org may violate the customer's license terms or internal policies.
- **Credential exposure:** If the forked repo contains secrets in its history (yes, it should not, but it does — I have seen it in every enterprise codebase I have managed), those secrets are now in a fork you control.

**Recommendation:** If cross-repo orchestration is a goal, it should work with the customer's existing org and permissions. The agent should operate within the customer's GitHub org, not fork to an external one. At minimum, this needs a security review and legal sign-off before implementation.

### 6. No Error Recovery Contract

The PLAN.md mentions "Error handling and recovery patterns" as part of Goal 1, but there is no specification of what happens when things go wrong:

- What happens when an agent crashes mid-task? Is the COW layer preserved? Can it be resumed?
- What happens when two COW layers conflict on the same files? The plan mentions "conflict detection" but not conflict *resolution*.
- What happens when GitButler fails to commit? Is the agent's work lost?
- What happens when the MCP server crashes? Are in-flight operations durable?

Enterprise customers need to know the failure modes. "It might crash" is acceptable. "We don't know what happens to your data when it crashes" is not.

**Recommendation:** Document the failure modes and recovery procedures:
- Agent crash: COW layer preserved, resumable via `restore_agent` tool
- Conflict: specific merge strategy or escalation to human
- Server crash: in-flight operations journaled and replayable
- Budget exceeded: graceful shutdown with work preservation

---

## What Is Missing

### Migration Tooling

There is no mention of how users upgrade between versions of mcagent. When the `.mcagent/` directory format changes — and it will change — what happens to existing workspaces? A `mcagent migrate` command should be planned from day one.

### Configuration Schema Validation

The config files (`.mcagent/config.toml`, agent configs, budget configs) have no schema validation mentioned. What happens when a user provides an invalid config? What happens when a new version adds a required field? Config parsing should be tolerant: ignore unknown fields, provide defaults for new fields, emit warnings for deprecated fields.

### Rate Limiting and Back-Pressure

The budget system tracks cost, but there is no mention of rate limiting MCP tool calls. An agent in a tight loop could fire thousands of tool calls per minute. The budget system would catch this eventually (when cost thresholds are hit), but by then the damage is done. Rate limiting at the MCP server level — per agent, per tool — is essential for production use.

### Customer Impact Documentation

None of the documents describe how changes to mcagent itself will be communicated to users. When a tool's behavior changes, when a config field is deprecated, when a COW format changes — how do users find out? A changelog is the minimum. Release notes with migration guides for breaking changes is what I expect.

### Multi-Tenancy Considerations

If mcagent is used in a shared environment (a company-wide deployment serving multiple projects), there is no tenant isolation model. Can agents from project A access project B's COW layers? Memory stores? Budget data? The current design appears to be single-project, but the meta mono-repo idea implies multi-project coordination, which requires tenant boundaries.

---

## Specific Recommendations

1. **Add `api_version` to the MCP server handshake.** Clients should know what version of the tool API they are talking to. Breaking changes require a major version bump. Non-breaking additions are minor versions.

2. **Implement audit logging before the first external user.** Retrofitting audit trails is ten times harder than building them in from the start. I have done it both ways. Start with a simple append-only JSONL file and a `query_audit_log` MCP tool.

3. **Abstract the COW layer behind a trait.** `CowBackend` with implementations for APFS, btrfs, overlayfs, and full-copy. Test on Linux in CI from day one.

4. **Add a `mcagent doctor` command** that validates the workspace, checks config syntax, verifies COW backend availability, and reports the platform support level.

5. **Define the deprecation policy in a STABILITY.md file.** Something like: "MCP tools marked stable will not have breaking changes within a major version. Deprecated tools will emit warnings for at least 2 minor versions before removal."

6. **Add a `--dry-run` flag to destructive operations.** `destroy_isolation --dry-run` should report what would be deleted without deleting it. This is table stakes for enterprise adoption.

7. **Scope the agent memory system carefully.** Per-agent memory containing codebase patterns is fine. Per-agent memory containing customer data needs encryption at rest, access controls, and a deletion API.

8. **Do not ship the meta mono-repo fork feature without a security architecture review.** The liability exposure of hosting forks of customer code in an org you control is significant. This needs legal counsel, not just engineering review.

---

## Summary

The core architecture — COW isolation, WASI sandboxing, stacked PRs, MCP interface — is sound and addresses real problems well. I would be excited to adopt this in my organization.

However, the project is currently designed as a developer tool and not yet as enterprise software. The gaps in API versioning, audit trails, platform portability, data retention, and migration tooling would prevent me from deploying this in a production environment with compliance obligations.

None of these gaps are architectural — they are all additive. The foundation is strong. But they need to be addressed before this ships to customers who have SLAs, compliance requirements, and legal teams.

**My ask:** Add API versioning and audit logging to the PLAN.md as explicit goals before Goal 5 (End-to-End Integration). These are not features — they are infrastructure that every other feature depends on. Retrofitting them later is painful and error-prone. I have the scars to prove it.

---

Signed-off-by: cto-enterprise-guardian@mcagent
