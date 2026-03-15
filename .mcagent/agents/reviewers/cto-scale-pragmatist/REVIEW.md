# Review: mcagent — PROJECT.md, PLAN.md, IDEAS.md

**Reviewer:** cto-scale-pragmatist@mcagent
**Date:** 2026-03-15
**Verdict:** Conditional NACK — exciting foundation, but not shippable without operational instrumentation

---

## What Excites Me

I have been waiting for something like this. The core insight — COW isolation + WASI sandboxing + GitButler multi-branch — is exactly right. I have lived through the "five agents stomping on the same file" problem. It is real, it costs hours, and it makes agents useless for anything beyond single-file changes.

Three things I genuinely want to see land:

1. **COW isolation per agent.** This is the single biggest unlock. Each agent gets a real filesystem path, external tools work unmodified, and you diff the layer to get the changeset. Brilliant. No custom VFS, no file-locking protocol, no coordination overhead. The filesystem *is* the isolation boundary. I could deploy agents against production repos today if this works.

2. **WASI sandboxing with explicit capabilities.** No ambient authority. Agents cannot reach the network unless you grant it. Agents cannot read files outside their preopened directories. This is the kill switch I want for every agent tool. If a tool goes haywire, it cannot exfiltrate data or corrupt the host. The Docker-now-WASI-later migration path in IDEAS.md is pragmatic — ship Docker, prove the model, then tighten the sandbox.

3. **Stacked PRs with dependency ordering.** Small, ordered PRs are the only way I have ever seen code review work at scale. If mcagent can produce a chain of 5 PRs where each one builds on the last, reviewers can reason about changes incrementally. This is worth the entire project even without the agent automation.

---

## What Concerns Me

### 1. Zero observability story

This is my biggest concern and it runs through all three documents. I see no mention of:

- **Metrics.** No counters, histograms, or gauges anywhere. How do I know how many agents are running? How long COW clone creation takes? What the p99 latency of a WASI tool invocation is? What the failure rate of branch commits is?
- **Tracing.** No span IDs, no trace context. When agent-03 fails after 20 minutes of work, how do I reconstruct what happened? Which MCP tool calls did it make? What order? How long did each take?
- **Structured logging.** The codebase is Rust. There is no mention of `tracing` crate integration, no log levels, no correlation IDs. When 8 agents are running concurrently and one hangs, I need to filter logs by agent ID, not grep through interleaved stdout.

If this ships without observability, the first team that runs 8 concurrent agents will have no idea what is happening inside the system. They will not know it is broken until their CI bill spikes or a COW layer fills the disk.

**Recommendation:** Add an observability section to PROJECT.md. Define the metrics every MCP tool emits. Require `tracing::instrument` on every public function in `mcagent-core`. Emit structured JSON logs with `agent_id`, `task_id`, and `tool_name` on every tool invocation.

### 2. No rollback story for COW layers or branches

The workflow says: create COW clone, agent works, diff, commit, push, create PR. What happens when:

- The COW clone fills the disk? (APFS reflinks are not free — writes allocate real blocks)
- An agent commits corrupt state to a branch?
- Two agents modify the same file in their respective COW layers, and both commit?
- The process crashes mid-commit and the COW layer is orphaned?

I see `Cleanup: destroy COW layers and branches for completed agents` in Goal 5, but there is no error-path cleanup. What is the cleanup strategy when things go wrong, not when they go right?

**Recommendation:** Add a COW layer lifecycle section: creation, health checks, disk space monitoring, orphan detection, and forced cleanup. Add a `cow_layer_disk_bytes` gauge per agent. Add a `cow_orphan_count` gauge. Run a background reaper on a timer.

### 3. APFS-only is a platform risk

The COW layer depends on APFS `clonefile`, which is macOS-only. The document acknowledges this implicitly by saying "APFS reflink (macOS)" in the Technology section, but does not address it. Every CI system I have used runs Linux. Every production server runs Linux.

If I cannot run this on Linux, I cannot run it in CI, and if I cannot run it in CI, I cannot trust it.

**Recommendation:** The PLAN.md or PROJECT.md needs to state the platform story explicitly. Options: overlayfs on Linux, btrfs reflink on Linux, Docker volume snapshots as fallback. Even if macOS is the first target, the abstraction boundary needs to exist now so the COW layer is swappable.

### 4. No feature flags or gradual rollout for new tools

IDEAS.md describes agents creating new WASI tools that other agents can use. This is powerful and terrifying. If agent-01 creates a buggy tool and agent-02 through agent-08 all pick it up, you have a cascading failure across the entire swarm.

Where is the feature flag? Where is the percentage rollout? Where is the tool approval workflow?

**Recommendation:** New agent-created tools should be quarantined by default. An `approved_tools` list in the workspace config gates which tools other agents can use. New tools go through a validation step (compile check, capability audit) before promotion. Add a `tool_invocation_errors_total` counter with `tool_name` label so you can catch a bad tool before it spreads.

### 5. Budget enforcement has no circuit breaker

The budget tracking in IDEAS.md is thorough — wall clock, tokens, cost, compute seconds, API calls. But the enforcement is linear: warn at 75%, pause at 90%, kill at 100%. This does not account for burst failures.

What if an agent enters a tight loop calling MCP tools 50 times per second? By the time you hit 75% warning, it has consumed the remaining 25% in the next 200 milliseconds. The kill-at-100% check only triggers if something is checking.

**Recommendation:** Add rate limiting, not just budget caps. `max_api_calls_per_minute = 30`. Add a circuit breaker: if a tool fails 5 times in 60 seconds, stop calling it. The budget system should be enforced in the MCP server's request handler as middleware, not as a periodic check.

---

## What is Missing

### Operational runbook

There is no runbook. When I deploy mcagent and it breaks at 3 AM, what do I do? The documents describe what the system does but not how to operate it. I need:

- How to list all running agents and their state
- How to kill a specific agent
- How to clean up orphaned COW layers
- How to check disk usage across all COW layers
- How to drain the system gracefully (finish current work, stop accepting new tasks)

### Health check endpoint

The MCP server needs a health check. Not just "is the process alive" but "is the COW backend reachable, is the WASI runtime initialized, is GitButler connected, how many agents are active." This is table stakes for any service that runs in production.

### Incident management integration

When an agent fails, what happens? The documents describe agent creation and happy-path completion. They do not describe failure modes. I want:

- Agent failure events emitted as structured logs with full context
- A `dead_letter` queue for failed tasks so they can be retried or inspected
- Webhook support for alerting (PagerDuty, Slack, etc.)

### Capacity planning

The IDEAS.md mentions `concurrent_agents = 8` as a project budget parameter. But there is no discussion of system-level capacity. Each COW clone is an APFS reflink — cheap at first, but writes allocate real blocks. 8 agents each running `cargo build` in their COW layer means 8 parallel compilations. That is 8x the disk I/O, 8x the CPU, and potentially 8x the RAM for the compiler.

What are the actual resource requirements? What is the recommended hardware for running N agents? Where are the bottlenecks?

### Disaster recovery for the `.mcagent/` directory

The `.mcagent/` directory holds agent templates, memory, budget ledgers, issue mirrors, and configuration. If this is lost, the entire system state is gone. Is it committed to the repo? Is it gitignored? Is it backed up? The documents do not say.

---

## Specific Recommendations

| Priority | Recommendation | Effort |
|----------|---------------|--------|
| **P0** | Add `tracing` crate integration with structured JSON output, agent_id and task_id on every span | 1-2 days |
| **P0** | Add metrics: `agent_count` gauge, `cow_layer_disk_bytes` gauge, `tool_invocation_duration_seconds` histogram, `tool_invocation_errors_total` counter | 1-2 days |
| **P0** | Add COW layer cleanup on error paths, orphan reaper, disk space monitoring | 2-3 days |
| **P1** | Abstract COW backend behind a trait so Linux (overlayfs/btrfs) support is addable without rewriting the core | 1 day |
| **P1** | Add rate limiting to MCP tool invocations as middleware | 1 day |
| **P1** | Add health check MCP tool: `system_health` returning component status | 0.5 days |
| **P1** | Add tool quarantine for agent-created WASI tools | 1-2 days |
| **P2** | Write an operational runbook covering common failure scenarios | 1 day |
| **P2** | Add webhook/alerting for agent failures | 1 day |
| **P2** | Document `.mcagent/` directory lifecycle: what is committed, what is ephemeral | 0.5 days |

---

## Bottom Line

The architecture is sound. The problem it solves is real. The combination of COW isolation, WASI sandboxing, and GitButler multi-branch is genuinely novel and I want to use it.

But right now this is a system designed to be built, not a system designed to be operated. There is no way to see inside it while it is running. There is no way to recover when things go wrong. There is no way to roll back a bad agent tool without killing the whole swarm.

Add observability, add error-path cleanup, add the COW backend abstraction for Linux, and I will approve this for production use. Without those, this is a compelling prototype that I would not let my team depend on.

How do we roll this back? Right now, we cannot. That needs to change before this ships.

---

Signed-off-by: cto-scale-pragmatist@mcagent
