# Distributed Systems Review: mcagent

**Reviewer**: Priya Venkatesh, CTO — Distributed Systems
**Scope**: PROJECT.md, PLAN.md, IDEAS.md, and current implementation
**Date**: 2026-03-15

---

## What Excites Me

The fundamental insight here is sound: file contention is the serialization bottleneck for multi-agent coding, and COW isolation is the right primitive to break it. I have spent years watching distributed storage teams rediscover this — the fastest synchronization is no synchronization at all. Giving each agent a full, independent filesystem copy and deferring reconciliation to git merge is exactly the pattern that works.

Three things stand out:

1. **The `ExecutionBackend` trait is well-factored.** It captures the essential lifecycle — create isolation, execute, diff, destroy — without leaking backend-specific concerns. The Docker backend's cleanup logic on `create_isolation` failure (lines 76-79 of `docker/backend.rs`) shows someone who has thought about partial failure. That is rare in early-stage code.

2. **GitButler as the merge reconciliation layer.** This is a genuinely good architectural choice. Rather than building a custom merge engine (which would be a multi-year commitment to get right), you delegate to a tool that already handles multi-branch coexistence. The stacked branch model maps cleanly onto task dependency ordering.

3. **The progression from Docker to WASI in IDEAS.md.** This is the right migration path. Docker is "good enough" isolation today, and WASI components give you provable sandboxing later. The fact that you have both the `DockerBackend` and the `WasiToolRunner` already coexisting in the codebase tells me the abstraction boundaries are in the right place.

---

## What Concerns Me

### 1. The `CowLayer::create` check-then-act is a textbook TOCTOU race

```rust
if agent_path.exists() {
    return Err(McAgentError::AgentAlreadyExists(agent_id.clone()));
}
std::fs::create_dir_all(agents_dir)?;
```

Is this idempotent? Two concurrent `create_agent` calls with the same `agent_id` could both pass the `exists()` check before either creates the directory. In practice, `AgentId::new()` uses UUID, so collisions are unlikely — but the 8-character truncation (`Uuid::new_v4().to_string()[..8]`) increases collision probability significantly compared to a full UUID. With 8 hex characters you have a 32-bit space, and by the birthday paradox you hit a 50% collision probability around 77,000 agents. That is not a theoretical concern for a system designed to run many agents over time.

More importantly: what if an external caller passes a specific `agent_id` via `AgentId::from_str`? The TOCTOU window is real.

**Recommendation**: Use atomic directory creation (`create_dir` instead of `create_dir_all`, which fails if the directory already exists) as the concurrency guard. Or use a file lock. The check-then-act pattern is not safe under concurrent access.

### 2. `std::mem::forget(cow_layer)` in `DockerBackend::create_isolation` is a resource leak risk

```rust
std::mem::forget(cow_layer);
```

I understand why this is here — `CowLayer` does not implement `Drop`, so you are preventing the value from being dropped and reconstructing it later from `backend_data`. But this design relies on the `destroy` method always being called. What if the MCP server crashes between `create_isolation` and a future `destroy` call? What if the `IsolationHandle` is dropped without `destroy` being called (process exit, panic, cancellation)?

You now have a leaked git worktree and a Docker container running `sleep infinity` with no one tracking them.

**Question**: Who cleans up orphaned isolation contexts on startup? Is there a reconciliation pass that finds worktrees/containers without a corresponding entry in `ServerState.handles`?

### 3. `ServerState` is in-memory only — no crash recovery

All agent state lives in `HashMap<String, Agent>` inside `ServerState`, behind an `Arc<RwLock<...>>`. If the MCP server process dies:

- All agent metadata is lost.
- COW layers (git worktrees) remain on disk with no index.
- Docker containers keep running.
- Budget usage data is gone.

This is the distributed systems problem I care about most: **what is the recovery model?** The IDEAS.md budget section mentions an append-only `ledger.jsonl`, but it is not implemented. Even a simple JSON file written after each state mutation would give you crash recovery. Without it, a single `kill -9` puts the system into an inconsistent state that requires manual cleanup.

**Recommendation**: Implement a write-ahead log or at minimum a state snapshot file. On startup, scan for orphaned worktrees and containers, reconcile against the persisted state, and clean up anything that does not belong.

### 4. The `RwLock<ServerState>` is held across await points

In `tools/mod.rs`, nearly every tool handler does:

```rust
let mut state = self.state.write().await;
// ... check budget ...
// ... get agent ...
// ... do work ...
```

The write lock is held for the entire duration of the tool execution. Since `commit_changes` calls `state.backend.diff(handle).await` and `state.gitbutler.commit(...).await` while holding the write lock, no other tool call can proceed until the commit finishes. This effectively serializes all agent operations through a single lock — destroying the parallelism that the COW architecture was designed to enable.

**Question**: What happens if two agents try to `commit_changes` concurrently? They serialize. What if `gitbutler.commit` hangs? Every other MCP tool call blocks.

**Recommendation**: Hold the lock only long enough to read or update the state maps. Clone the data you need, release the lock, do the expensive I/O, then reacquire the lock to update state. Consider per-agent locks instead of a global lock.

### 5. `destroy_agent` removes state before the backend cleanup succeeds

```rust
pub async fn destroy_agent(&mut self, agent_id: &str) -> Result<(), McAgentError> {
    let handle = self.handles.remove(agent_id)
        .ok_or_else(|| McAgentError::AgentNotFound(...))?;
    self.agents.remove(agent_id);
    self.budgets.remove(agent_id);
    self.budget_usage.remove(agent_id);
    self.backend.destroy(&handle).await
}
```

The in-memory state is removed before `self.backend.destroy(&handle)` is called. If `backend.destroy` fails (Docker daemon unreachable, filesystem permission error, etc.), the agent's metadata is already gone from the server state. You cannot retry `destroy_agent` because the handle has been removed. The agent is in a limbo state: not tracked by the server, but its resources still exist.

**Recommendation**: Move the state cleanup to after the `backend.destroy` call succeeds. If `destroy` fails, the agent should remain in the maps so the operation can be retried.

### 6. Agent creation is a multi-step operation with incomplete rollback

In `agent_create` (tools/mod.rs), the sequence is:

1. `state.create_agent(config)` — creates COW layer + updates maps
2. `state.gitbutler.create_branch(...)` — creates GitButler branch

If step 2 fails, the code logs a warning and continues:

```rust
if let Err(e) = branch_result {
    tracing::warn!("Failed to create GitButler branch (continuing): {e}");
}
```

This means you have an agent with an isolation context but no GitButler branch. When the agent later tries to `commit_changes`, the commit will go... where? The agent thinks it has a branch (stored in `agent.branch_name`), but GitButler does not know about it.

**Question**: Is this intentional? Should the agent be cleaned up if branch creation fails? Or should commit fall back to a regular git commit?

### 7. No message ordering or operation sequencing guarantees

The MCP server processes tool calls as they arrive. There is no mechanism to ensure that operations on the same agent are processed in order. If a client fires `write_file` followed immediately by `commit_changes`, and the write is slow while the commit is fast, the commit could execute before the write completes — committing stale state.

The MCP protocol itself may provide ordering guarantees per-client, but across multiple clients (or a client using concurrent tool calls), there is no protection.

**Question**: What ordering guarantees does this system provide? Per-agent FIFO? Total order? None? This should be documented, and if per-agent FIFO is intended, it should be enforced with per-agent operation queues.

---

## What Is Missing

### Startup reconciliation

There is no startup scan that finds existing git worktrees matching `mcagent/*`, Docker containers matching `mcagent-*`, or directories under `.mcagent/agents/`. On restart, the server starts with empty state and has no awareness of prior runs.

### Idempotent operations

None of the MCP tools are idempotent. Calling `workspace_init` twice creates directories (which is fine because `create_dir_all` is idempotent), but calling `agent_create` with the same parameters twice creates two different agents. There is no deduplication mechanism — no idempotency key, no content-based addressing.

### Timeout and cancellation handling

The `GitButlerCli` and `DockerBackend` shell out to external processes (`but`, `docker`, `git`) but never set timeouts. If `docker exec` hangs, the entire tool call hangs forever. If the MCP client cancels the request, the spawned process keeps running.

**Recommendation**: Add `tokio::time::timeout` around all subprocess invocations. Handle the cancellation case by killing the child process.

### Health checks and liveness

There is no mechanism to detect whether an agent's Docker container is still running, whether a git worktree is still valid, or whether a GitButler branch still exists. Operations assume the happy path and only discover problems at execution time.

### Conflict detection across agents

The PLAN.md mentions "conflict detection when COW layers overlap on the same files" but this is not implemented. Two agents could modify the same file in their respective COW layers, and the conflict would only be discovered at merge time. For stacked branches this is especially dangerous — a conflict in a base branch invalidates all branches stacked on top.

---

## Specific Recommendations

1. **Add a `reconcile_on_startup` method** to `ServerState` that scans for orphaned worktrees, containers, and agent directories. Register anything found as "orphaned" state that can be inspected and cleaned up.

2. **Shrink the RwLock critical sections.** Extract agent lookup and budget enforcement into a helper that clones the needed data and drops the lock. Then do I/O without holding the lock. This is the single most impactful change for enabling true parallelism.

3. **Fix `destroy_agent` ordering.** Call `backend.destroy()` first. Only remove from maps on success. Add a `Destroying` state to `AgentState` to prevent new operations on an agent being destroyed.

4. **Add timeouts to all subprocess calls.** Use a helper like:
   ```rust
   async fn run_with_timeout(cmd: Command, timeout: Duration) -> Result<Output, McAgentError>
   ```
   Default to 30 seconds for git/but commands, 60 seconds for docker operations.

5. **Persist agent state to disk.** Even a simple `agents.json` written after each mutation would allow crash recovery. The append-only ledger from IDEAS.md is the right long-term answer; a JSON snapshot is the pragmatic short-term answer.

6. **Use full UUIDs for AgentId** or at minimum increase the truncation to 12-16 characters. The 8-character truncation creates an unnecessarily small ID space.

7. **Add per-agent operation locks** (or a per-agent `tokio::sync::Mutex`) to enforce per-agent FIFO ordering without blocking operations on other agents.

8. **Document the consistency model.** State explicitly: "Operations on different agents are independent. Operations on the same agent are serialized by the server. The system does not guarantee ordering across concurrent MCP clients." Then enforce that contract.

---

## Summary

The architecture is sound. The layered separation (WASI sandbox, COW filesystem, GitButler integration, MCP server) is clean and composable. The `ExecutionBackend` trait is the right abstraction. The Docker backend shows awareness of partial failure in its `create_isolation` path.

The concerns are concentrated in three areas: **crash recovery** (no persistent state, no startup reconciliation), **concurrency** (global RwLock serializes all operations, TOCTOU in CowLayer, destroy-before-cleanup ordering), and **resilience** (no timeouts, no health checks, no idempotency). These are exactly the problems that surface the moment you move from "one agent" to "eight agents running concurrently for hours."

The foundation is good. The failure modes need attention.

NACK — state is not persistent across restarts, global RwLock serializes agent operations defeating COW parallelism, destroy_agent removes tracking state before backend cleanup can fail, no timeout or cancellation handling on subprocess invocations.

Signed-off-by: cto-distributed-systems@mcagent
