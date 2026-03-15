# The Gatekeeper Review: mcagent PROJECT / PLAN / IDEAS

Reviewed: `PROJECT.md`, `PLAN.md`, `IDEAS.md`, and current source tree.

Signed-off-by: the-gatekeeper@mcagent

---

## What holds up under pressure

The error type design in `mcagent-core/src/error.rs` is solid. `McAgentError::Filesystem` carries the path and the original `io::Error`. The caller can diagnose the problem without reading source. That is how you build an error type.

The path traversal checks in the MCP tool handlers (`read_file`, `write_file`, `list_directory`, `search_files`) are present and correct. `file_path.starts_with(&agent.working_dir)` prevents breakout. Good.

The Docker backend's cleanup logic in `create_isolation` handles partial failure correctly: if `docker start` fails, it removes the container and destroys the COW layer before returning `Err`. That is the kind of cleanup path I want to see.

The `ExecutionBackend` trait forces every backend to implement `destroy`. Resource lifecycle has a contract. I respect that.

Budget enforcement exists and is checked before tool execution. The `check_budget` function handles all dimensions and returns the worst-case status. The tests cover within-budget, warning, and exceeded states.

---

## What will break in production

### 1. `std::mem::forget(cow_layer)` is a resource leak waiting to happen

`crates/mcagent-docker/src/backend.rs:118` and `crates/mcagent-wasi/src/backend.rs:57`.

Both backends `forget` the `CowLayer` after creation to "prevent destroy-on-drop." But `CowLayer` has no `Drop` impl. There is nothing to prevent. The `forget` is a no-op today, but it documents an incorrect mental model. The comment says "prevent destroy-on-drop" for a type that does not implement `Drop`. When someone adds a `Drop` impl later (and they will, because this type manages git worktrees), the `forget` will silently suppress cleanup on every error path between creation and the eventual `reconstruct_cow_layer` call.

What happens when the server crashes between `create_isolation` and `destroy`? Orphaned git worktrees. Orphaned agent directories. No cleanup. There is no recovery mechanism documented in PROJECT.md or PLAN.md.

**Recommendation:** Remove the `mem::forget`. If `CowLayer` is purely path-based and holds no resources, just drop it normally. Add a startup-time garbage collection step that scans `.mcagent/agents/` for orphaned directories and `git worktree list` for stale worktrees.

### 2. `unwrap()` on `AgentId::parse()` in library code

`crates/mcagent-mcp/src/server.rs` lines 83, 90, 111. Three `unwrap()` calls on `agent_id.parse()`. Yes, `FromStr for AgentId` returns `Infallible`, so these cannot panic *today*. But this is library code. If `AgentId::from_str` ever gains validation (and it should -- see point 7), every one of these becomes a panic. Convert to `.map_err` now.

### 3. `expect()` in non-test code with no safety justification

`crates/mcagent-cowfs/src/layer.rs` lines 169, 212, 287: `.expect("entry is under agent_path")`. These are in `diff_filesystem` and `copy_dir`. If a symlink resolves outside the expected prefix, or if a race condition changes the directory structure during the walk, `strip_prefix` fails and the process panics.

What happens when an agent creates a symlink that points outside its working directory? The diff operation panics. The MCP server crashes. Every other agent's work is lost.

**Recommendation:** Replace with `.map_err` and return `McAgentError::Filesystem`. Skip entries that cannot be stripped rather than crashing the entire server.

### 4. No timeout on external process execution

`CowLayer::create` calls `Command::new("git")` with no timeout. `GitButlerCli::run` calls `Command::new("but")` with no timeout. `DockerBackend::exec` calls `docker exec` with no timeout. `WasiBackend::exec` calls arbitrary commands with no timeout.

What happens when `git worktree add` hangs because the disk is full and git is waiting on a lock? The MCP server blocks forever. What happens when a `docker exec` hangs because the container is stuck? The agent is dead but the server does not know.

The PLAN mentions "wall_clock_seconds" as a budget dimension, but there is no enforcement mechanism. `BudgetUsage::wall_clock_seconds_used` is never updated anywhere in the codebase. It is always 0.

**Recommendation:** Wrap every `Command` and `tokio::process::Command` in `tokio::time::timeout`. For agent execution, start a wall-clock timer in `create_isolation` and check it in `enforce_budget`. The budget system is incomplete without this.

### 5. `search_recursive` silently swallows I/O errors

`crates/mcagent-mcp/src/tools/mod.rs` line 733-756. The `search_recursive` function silently returns on `read_dir` errors and silently skips files that fail `read_to_string`. The caller gets partial results with no indication that anything went wrong. Binary files will produce garbage matches or be silently skipped.

A search that silently returns incomplete results is worse than a search that fails loudly.

**Recommendation:** At minimum, count errors and report "N files could not be read" in the result. Better: return a `Result` and let the caller decide.

### 6. No `Drop` impl on anything that manages external resources

`CowLayer` creates git worktrees. `DockerBackend` creates Docker containers. Neither has a `Drop` impl. If the server panics (and with all those `expect()` calls, it will), every worktree and container leaks.

The `ExecutionBackend::destroy` is async, so a sync `Drop` cannot call it directly. But you can spawn a blocking cleanup task, or maintain a cleanup registry that runs on shutdown.

**Recommendation:** Implement a shutdown hook or cleanup registry. On server startup, scan for orphaned resources. On graceful shutdown, destroy all active handles.

### 7. `AgentId` accepts any string with no validation

`AgentId::from_str` accepts any input. An agent ID like `../../etc` would produce a worktree path of `.mcagent/agents/../../etc`. The path traversal check in the MCP tools protects file reads, but `CowLayer::create` constructs paths directly from the `AgentId` with no sanitization.

`AgentId::new()` generates safe 8-character hex strings, but `from_str` is public and unchecked. Anyone calling `agent_id.parse()` can inject path components.

**Recommendation:** Validate `AgentId` in `from_str`: alphanumeric and hyphens only, max 64 characters. Reject `/`, `..`, and null bytes.

---

## What is missing from the PLAN

### 8. No error recovery or retry strategy

PLAN Goal 5 mentions "conflict detection" but says nothing about what happens when an agent fails mid-task. The agent's COW layer has uncommitted changes. The branch is in an unknown state. What does the orchestrator do? The plan says "cleanup: destroy COW layers and branches for completed agents" but says nothing about *failed* agents.

What happens when agent A depends on agent B, and agent B fails? The `TaskGraph` will need a failure propagation strategy. The PLAN does not mention this.

### 9. No state persistence

`ServerState` lives entirely in memory. `HashMap<String, Agent>`, `HashMap<String, IsolationHandle>`. If the MCP server restarts, all agent state is lost. The handles are gone. The COW layers and Docker containers are orphaned. The budget tracking resets to zero.

The IDEAS document mentions `.mcagent/budget/ledger.jsonl` but this is not implemented and not in the PLAN.

**Recommendation:** Add a state persistence goal to the PLAN. At minimum, serialize `ServerState` to `.mcagent/state.json` on every mutation and reconstruct on startup. The `IsolationHandle` already carries enough `backend_data` to reconstruct.

### 10. No signal handling

What happens when the server receives SIGTERM? SIGINT? SIGHUP? No graceful shutdown. No cleanup. Docker containers keep running. Git worktrees litter the filesystem.

**Recommendation:** Add signal handling to the server binary. On SIGTERM/SIGINT: destroy all active isolation handles, then exit.

### 11. Disk exhaustion during COW operations

`copy_dir` in the non-git fallback copies the entire project directory. What if the disk fills up mid-copy? Partial directory left behind. No cleanup in the error path -- `copy_dir` returns `Err` but does not remove the partially-created destination.

`CowLayer::create` calls `create_dir_all` and then either `git worktree add` or `copy_dir`. If `copy_dir` fails, the empty `agent_path` directory is left behind. Next call with the same `agent_id` will hit `AgentAlreadyExists` even though the agent does not actually exist.

**Recommendation:** In `copy_dir`, if any operation fails after creating `dst`, remove `dst` before returning the error. Same pattern as the Docker backend's cleanup logic.

---

## What concerns me about the IDEAS

### 12. Cross-repo coordination without distributed locking

The "Meta Mono-Repo" idea forks repos and spawns per-repo agents. What happens when two agents modify the same dependency? What happens when the coordinator crashes between forking and spawning agents? Who cleans up the forks? There is no mention of locking, leases, or idempotent operations.

### 13. Agent memory with no eviction under pressure

"OpenViking Memory" stores per-agent data with vector embeddings. `vectors.bin` for HNSW lookup. What is the size limit? What happens when an agent accumulates gigabytes of memory entries? There is no mention of eviction, compaction, or OOM behavior. `memory_mb_seconds` is a budget dimension but is never enforced in the current code.

### 14. WASI tools with network access

The IDEAS document mentions the WASI migration path. The current executor already supports `allow_net: true` via `wasi.inherit_network()`. This grants full network access to a WASM module. A tool with `net = true` in its frontmatter can exfiltrate any data from the preopened directories.

The PROJECT.md says "No network by default" which is correct. But there is no allowlist. It is binary: full network or none. The IDEAS mention "allowlisted hosts" as a future WASI feature but the current code has no enforcement.

**Recommendation:** Until host-level allowlisting exists, document the risk clearly. Consider removing `inherit_network` entirely and requiring a Docker backend for tools that need network access, where `--network=none` is the default.

---

## Specific questions for the authors

1. What happens when `git worktree add` succeeds but the branch already exists? The branch name is `mcagent/{agent_id}` which is unique per agent, but there is no cleanup of stale branches from previous runs.

2. `CowLayer::destroy` calls `git branch -D` and ignores the result (`let _ = ...`). If the branch has unmerged commits, those commits are silently destroyed. Is this intentional? Where is the comment explaining why this is acceptable?

3. The `MemoryOutputPipe` in the WASI executor is capped at 1MB (`new(1024 * 1024)`). What happens when a tool writes more than 1MB to stdout? Does wasmtime truncate, block, or error? If the tool hangs waiting on a full pipe, there is no timeout to kill it.

4. `list_directory` calls `entries.flatten()` which silently skips entries that fail to read. On a filesystem with permission issues, the user gets a partial listing with no warning. Is this a conscious trade-off?

5. `workspace_init` acquires a read lock (`state.read().await`) but creates directories on the filesystem. Why is this not a write lock? If two concurrent calls both pass the `create_dir_all` check, the operation is idempotent, but the pattern is misleading.

---

## Verdict

NACK. The design is sound and the isolation model is the right approach. But the implementation has unhandled failure modes that will bite in production:

- `mem::forget` on types that may gain `Drop`
- `expect()` in non-test code paths reachable from the MCP server
- Zero timeouts on any external process
- No state persistence across restarts
- No cleanup of orphaned resources on startup
- No signal handling for graceful shutdown
- Partial copy cleanup missing in error paths
- `AgentId` path injection via unchecked `from_str`
- Wall-clock budget tracking declared but never implemented

Fix the error handling, add timeouts, and implement startup cleanup. Then I will review again.

Signed-off-by: the-gatekeeper@mcagent
