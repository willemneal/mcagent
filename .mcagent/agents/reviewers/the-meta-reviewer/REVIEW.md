# Meta-Review: PROJECT.md, PLAN.md, IDEAS.md

Reviewing: the full project vision, implementation plan, and future ideas.
Scope: sandbox isolation, budget enforcement, crate boundaries, AGENT.md quality, and whether the plan actually delivers on the vision.

---

## What Excites Me

The core thesis is correct: agent isolation is a real problem, and nobody has solved it well. The combination of CowLayer (git worktrees) + Docker + WASI + GitButler is genuinely interesting. Specifically:

1. **Git worktrees as COW isolation.** This is the right call for a cross-platform solution. The original APFS reflink approach in PROJECT.md was macOS-only; the actual implementation in `mcagent-cowfs` uses `git worktree add`, which works everywhere git works. The fallback to directory copy for non-git contexts is pragmatic. This is how you ship.

2. **The `ExecutionBackend` trait is clean.** Five methods, all taking `&IsolationHandle`, all returning `Result<_, McAgentError>`. The trait lives in `mcagent-core`, backends live in their own crates. No circular dependencies. This is correct crate separation. The Docker backend composes CowLayer for filesystem + Docker for process isolation, which is exactly the layering I want to see.

3. **Budget enforcement is wired into the MCP tools.** Every filesystem and execution tool calls `enforce_budget()` before doing work and `record_api_call()` after. The budget system has real teeth: `BudgetStatus::Exceeded` returns an error that prevents the tool call. This is not aspirational -- it is implemented and enforced.

4. **The IDEAS.md budget tracking extension is well-thought-out.** The ledger-based approach with append-only JSONL, the 75%/90%/100% enforcement tiers, and the billing aggregation by agent type -- this is how you build cost observability for a system that will burn real money running LLM agents.

5. **Agent-to-agent communication channels in IDEAS.md.** The `conflict` channel for flagging overlapping changes is critical. Without it, two agents editing the same file will produce merge conflicts that no automated system can resolve well. This needs to exist before the system is used at scale.

---

## What Concerns Me

### P0: Path Traversal is Not Fully Mitigated

The MCP tools (`read_file`, `write_file`, `list_directory`, `search_files`) all do this:

```rust
let file_path = agent.working_dir.join(&params.path);
if !file_path.starts_with(&agent.working_dir) {
    return err("Path traversal not allowed".to_string());
}
```

Can an agent escape this sandbox? **Yes.** The `join` + `starts_with` check works for literal `..` components, but it does NOT handle symlinks. If an agent creates a symlink inside its worktree pointing to `/etc/passwd` or another agent's worktree, then reads through that symlink, the `starts_with` check passes (the logical path is inside the worktree) but the physical read escapes the sandbox.

The fix: canonicalize the path before the prefix check. But canonicalization fails on nonexistent paths, so you need a two-step approach -- canonicalize the parent, then append the filename:

```rust
let file_path = agent.working_dir.join(&params.path);
let canonical = file_path.canonicalize()
    .or_else(|_| {
        // For new files, canonicalize parent + raw filename
        file_path.parent()
            .ok_or_else(|| McAgentError::Other("invalid path".into()))?
            .canonicalize()
            .map(|p| p.join(file_path.file_name().unwrap_or_default()))
    })
    .map_err(|e| McAgentError::filesystem(&file_path, e))?;
let canonical_root = agent.working_dir.canonicalize()
    .map_err(|e| McAgentError::filesystem(&agent.working_dir, e))?;
if !canonical.starts_with(&canonical_root) {
    return Err(McAgentError::SandboxViolation { path, agent_id });
}
```

This is the single most important finding in this review. Without this fix, no other sandbox guarantee holds. NACK on shipping without it.

Also: `McAgentError` has no `SandboxViolation` variant. It should. Sandbox escapes should be distinguishable from generic errors in logging, metrics, and alerting. Right now a path traversal attempt produces the same error type as "file not found."

### P0: `diff_filesystem` Walks the Base Directory

In `mcagent-cowfs/src/layer.rs`, the `diff_filesystem` fallback method walks `self.base_path` to find deleted files:

```rust
for entry in walkdir::WalkDir::new(&self.base_path)
    .into_iter()
    .filter_entry(|e| !is_hidden(e))
```

This walks the **real project directory**, not the agent's copy. An agent that triggers the filesystem diff fallback (by being in a non-git context) can observe which files exist in the base project. This is a read-only information leak. It does not allow writes, but it violates the principle that agents should only see their own worktree.

Assess: Is the diff output returned to the agent? Yes -- `agent_status` calls `backend.diff(handle)` and returns the file paths to the caller. An agent calling `agent_status` on itself would see file paths from the base directory in the "Deleted" list, leaking the base directory structure.

### P1: `compile_tool` Has No Sandbox Scoping

The `compile_tool` MCP tool takes a raw `source_path` string with no agent scoping and no path validation:

```rust
async fn compile_tool(
    &self,
    Parameters(params): Parameters<CompileToolParams>,
) -> Result<CallToolResult, rmcp::ErrorData> {
    let state = self.state.read().await;
    match state.wasi_runner.compile_tool(std::path::Path::new(&params.source_path)) {
```

There is no budget check, no agent ID, and no path containment. Any agent (or any MCP client) can compile arbitrary files from the host filesystem into WASI tools. This is a sandbox escape via the build system -- an attacker can read file contents by compiling a Rust source file that `include_str!`s arbitrary paths.

This tool needs:
- An `agent_id` parameter
- Budget enforcement
- Path validation against the agent's working directory
- Or: restrict to the `.mcagent/tools/` directory exclusively

### P1: `create_tool` Writes to a Global Directory

The `create_tool` MCP tool writes source code to the shared tools directory with no agent scoping. An agent can overwrite another agent's tools. If agent A creates a tool named `read_file`, agent B might execute it expecting the built-in behavior and instead run arbitrary code.

This is an agent-to-agent attack vector. Tool creation should be scoped to the agent's worktree, or tools should be namespaced by agent ID.

### P1: `std::mem::forget(cow_layer)` in DockerBackend

The Docker backend calls `std::mem::forget(cow_layer)` after creating the container to prevent the CowLayer from being dropped. This means if the process crashes between `create_isolation` and the eventual `destroy` call, the COW layer (git worktree + branch) is leaked permanently. There is no recovery mechanism, no cleanup-on-startup, and no way to enumerate orphaned worktrees.

This is not a sandbox escape, but it is a resource leak that will accumulate over time. The fix is to implement `Drop` on `CowLayer` if you want auto-cleanup, or store worktree metadata in `.mcagent/state/` for crash recovery.

### P1: PROJECT.md Claims APFS, Code Uses Git Worktrees

PROJECT.md says "Copy-on-Write filesystems -- Each agent gets an instant, isolated clone of the repo (via APFS reflink)." The actual implementation uses `git worktree add`, which is a fundamentally different isolation mechanism. APFS reflink creates a physical copy-on-write clone of all files. Git worktrees share the `.git` directory and create a new checkout.

This matters because:
- Worktrees share the git object store, so agents can potentially observe each other's commits via `git log --all`
- Worktrees share the reflog, which leaks branch activity across agents
- Worktrees share hooks, which an agent could modify to affect other agents

PROJECT.md should be updated to reflect the actual implementation, and the shared `.git` state should be assessed for information leakage between agents.

### P2: Budget Does Not Track Token Usage

The budget system tracks API calls via `record_api_call()`, but `record_tokens()` is never called anywhere in the MCP server. The `input_tokens_used` and `output_tokens_used` fields will always be zero. The budget limits for `token_input_limit` and `token_output_limit` will never trigger.

This is because the MCP server does not have visibility into the LLM's token consumption -- that happens on the client side. The architecture needs a `record_tokens` MCP tool or a callback mechanism for the LLM client to report token usage back to the server.

### P2: No Wall-Clock Tracking

`BudgetUsage` has `wall_clock_seconds_used` and `started_at` fields, but `started_at` is never set (it is `Option<u64>` and defaults to `None`), and `wall_clock_seconds_used` is never incremented. The wall-clock budget dimension is defined but not enforced.

---

## What's Missing

### From the Plan

1. **Goal 2 (Agent Discovery & Loading) has no implementation.** `list_agent_templates` and `get_agent_template` are not in the MCP tools. The `.mcagent/agents/` directory contains reviewer AGENT.md files, but the server has no way to discover or serve them. This is the bridge between "AGENT.md files exist" and "agents actually use them."

2. **Goal 4 (Task Orchestration) has no implementation.** `TaskGraph`, `create_task`, `add_dependency`, `get_task_order` -- none of these exist. The `TaskId` type exists in `mcagent-core` but is unused. Without task orchestration, the system can only manage independent parallel agents, not dependent task chains that produce stacked PRs.

3. **Goal 5 (End-to-End Integration) depends on Goals 2 and 4**, so it is also unimplemented. The `orchestrate` MCP tool does not exist.

### From the Architecture

4. **No `mcagent-docker` crate listed in PLAN.md.** The Docker backend exists in code but is not mentioned in the plan. The plan jumps from "WASI sandbox" to "future: WASI components" without acknowledging that Docker is the current primary execution backend. The plan should reflect reality.

5. **No state persistence.** All server state (`agents`, `handles`, `budgets`, `budget_usage`) lives in memory in `ServerState`. If the MCP server restarts, all agent state is lost. Worktrees and Docker containers persist on disk/Docker daemon, but the server cannot reconnect to them. This means a server crash during agent execution loses all context.

6. **No concurrency control between agents.** Two agents created simultaneously will both call `CowLayer::create`, which calls `git worktree add`. Git worktree operations take a lock on `.git/worktrees`, so they will serialize naturally, but there is no application-level handling of this. If one fails due to lock contention, the error message will be confusing. The plan mentions "conflict detection when COW layers overlap on the same files" but does not address concurrent creation.

7. **No agent template for the orchestrator itself.** PLAN.md Goal 1 says "Create `.mcagent/agents/mcagent/AGENT.md`" and the file exists, but I have not reviewed its content here. The plan should specify how the orchestrator AGENT.md interacts with the MCP tools -- does the orchestrator call `agent_create` to spawn sub-agents? Does it use `create_branch` and `commit_changes`? The AGENT.md needs to be unambiguous about the workflow.

### From the Threat Model

8. **No rate limiting on agent creation.** An agent (or an MCP client) can call `agent_create` in a loop and create thousands of agents, each with a git worktree and optionally a Docker container. This is a denial-of-service vector. The project-wide budget in IDEAS.md (`concurrent_agents = 8`) would address this, but it is not implemented.

9. **No authentication or authorization on MCP tools.** Any MCP client can call any tool, including `agent_destroy` on another agent's ID. There is no concept of "this tool call came from agent X and should only be allowed to operate on agent X's resources."

10. **Docker container escape via bind mount.** The Docker backend bind-mounts the agent's working directory into the container. If the agent has write access inside the container and the container image has tools like `ln -s`, the agent can create symlinks inside the bind mount that point to host paths. When the host-side MCP tools (read_file, write_file) follow those symlinks, they escape the sandbox. This circles back to the P0 symlink issue.

---

## Specific Recommendations

1. **Fix the symlink escape now.** Add `canonicalize()` to all path checks in MCP tools. Add a `SandboxViolation` error variant. This is a blocking issue.

2. **Scope `compile_tool` and `create_tool` to agents.** Add `agent_id` parameters, enforce budget, validate paths. Or remove these tools from the initial release and add them when you have proper scoping.

3. **Update PROJECT.md to match reality.** Replace APFS reflink references with git worktree. Document the shared-`.git` implications. Do not let the vision doc contradict the implementation -- that confuses contributors and LLMs reading the codebase.

4. **Implement `list_agent_templates` and `get_agent_template` next.** These are the lowest-effort, highest-impact tools missing from the MCP server. They are simple filesystem reads with no isolation concerns. They unblock the entire agent discovery workflow.

5. **Add a `record_tokens` MCP tool.** Let the LLM client report token consumption. Without it, token budgets are decorative.

6. **Implement state persistence.** Write agent state to `.mcagent/state/agents.json` on every mutation. Reload on startup. Reconnect to existing worktrees and Docker containers. Without this, the system is not production-viable.

7. **Add a `SandboxViolation` variant to `McAgentError`.** Sandbox escapes need their own error type for monitoring, alerting, and forensics. Lumping them into generic errors hides the most critical failures.

8. **Address `std::mem::forget` in DockerBackend.** Either implement `Drop` for `CowLayer` cleanup, or persist worktree metadata for crash recovery. Leaked worktrees will accumulate and eventually fill disk.

9. **Assess git worktree information leakage.** Determine whether agents can observe each other's commits, branches, or reflogs through the shared `.git` directory. If they can, consider using the directory-copy fallback as the default, or running git commands with restricted refspecs.

10. **Add `concurrent_agents` limit to `ServerState`.** Reject `agent_create` when the active agent count exceeds the configured limit. This is a trivial guard against resource exhaustion.

---

## Verdict

The architecture is sound. The crate boundaries are correct. The budget system has real enforcement. The Docker backend is a reasonable first backend. But the sandbox has holes -- symlink traversal, unscoped tool compilation, shared git state -- and the plan is only 30% implemented (Goals 1 and 3 are partially done; Goals 2, 4, 5 are untouched).

Ship the symlink fix and tool scoping before any external users run untrusted agents. The rest can be sequenced.

NACK -- symlink escape vector is a P0 that must be resolved before merge.

Signed-off-by: the-meta-reviewer@mcagent
