# review(safety): mcagent project review — architecture, plan, and implementation

Reviewer: Kenji Yamamoto, CTO / Legacy Modernizer
Scope: PROJECT.md, PLAN.md, IDEAS.md, and full crate source

---

## Overall Assessment

NACK — several unwrap/expect calls in library code, two `std::mem::forget` calls without SAFETY documentation, and insufficient attention to panic freedom across the crate boundary.

The architecture is sound. The layered design (WASI sandbox, COW filesystem, GitButler integration, MCP server) is exactly the kind of defense-in-depth I want to see in a system that runs untrusted tool code. The codebase demonstrates real engineering discipline in most areas: proper error types, `?` propagation, `Result`-returning APIs. But discipline breaks down in several specific locations, and the project documents do not address panic safety or unsafe policy at all.

---

## What I Approve Of

### 1. The `ExecutionBackend` trait abstraction

`crates/mcagent-core/src/execution.rs` defines a clean async trait with `Result` returns on every method. No panic paths in the trait definition. The trait boundary is the right place to enforce correctness — any backend that implements this correctly will be safe to use. This is good systems design.

### 2. Error handling in `mcagent-gitbutler`

The `GitButlerCli` (`crates/mcagent-gitbutler/src/cli.rs`) consistently uses `Result<T, McAgentError>` returns and `map_err` conversions. The `String::from_utf8_lossy` usage on CLI output is acceptable here — git and `but` CLI output is expected to be UTF-8, and lossy conversion is the pragmatic choice. No `unwrap()` in library paths. ACK on this crate.

### 3. WASI capability model

The frontmatter-based capability declaration (`crates/mcagent-wasi/src/frontmatter.rs`) with validation that `net` requires `preview2` is a correct enforcement at the right boundary. The `SandboxPermissions` struct in `executor.rs` maps capabilities to preopened directories with appropriate `DirPerms` and `FilePerms`. This is the kind of capability-based security that I want to see.

### 4. Path traversal protection in MCP tools

`crates/mcagent-mcp/src/tools/mod.rs` checks `file_path.starts_with(&agent.working_dir)` before filesystem operations. This is correct defensive boundary validation.

### 5. Budget enforcement before tool execution

Every MCP tool that touches an agent calls `enforce_budget()` and `record_api_call()` before proceeding. The budget system uses `Result` returns throughout. Clean.

### 6. Defensive parsing in `parse_git_diff_name_status`

`crates/mcagent-cowfs/src/layer.rs` lines 256-276: uses `filter_map`, `parts.next()?`, and graceful fallthrough. No panic risk from malformed git output. This is correct defensive parsing.

---

## What Concerns Me

### C1. `std::mem::forget` without SAFETY documentation

Two occurrences:

**`crates/mcagent-wasi/src/backend.rs` line 57:**
```rust
std::mem::forget(cow_layer);
```

**`crates/mcagent-docker/src/backend.rs` line 118:**
```rust
std::mem::forget(cow_layer);
```

`std::mem::forget` is safe Rust, so it does not require a `// SAFETY:` comment in the strict sense. But it is a resource leak by design. The comment on line 53-56 of the WASI backend explains the intent, but does not document the invariant: "This `CowLayer` will be reconstructed from paths stored in `backend_data` when `diff()` or `destroy()` is called. If neither is ever called, the worktree and branch are leaked."

That last sentence is the problem. If `destroy()` is never called (process crash, agent timeout, budget kill), the git worktree and branch are permanently leaked. The PLAN.md mentions "Cleanup: destroy COW layers and branches for completed agents" but there is no crash-recovery mechanism. Every `forget` is a promise that someone else will clean up. Document who, and what happens if they do not.

Recommendation: Add a startup scan in `workspace_init` that detects orphaned worktrees (via `git worktree list --porcelain`) and cleans them up. Document the `forget` calls with the recovery path.

### C2. `expect()` in library code — 4 occurrences

**`crates/mcagent-cowfs/src/layer.rs` line 169:**
```rust
let rel_path = entry.path().strip_prefix(&self.agent_path)
    .expect("entry is under agent_path");
```

Can this panic? Yes. If `agent_path` is a symlink, or if the filesystem is modified concurrently (another agent, a user), `strip_prefix` can fail. The `expect` message is good documentation of intent, but it should be an error, not a panic. This is library code called from the MCP server — a panic here takes down the entire server and all connected agents.

**`crates/mcagent-cowfs/src/layer.rs` line 211:**
```rust
let rel_path = entry.path().strip_prefix(&self.base_path)
    .expect("entry is under base_path");
```

Same issue, same risk. Symlinks, mount points, TOCTOU races.

**`crates/mcagent-cowfs/src/layer.rs` line 287 (in `copy_dir`):**
```rust
let rel_path = entry.path().strip_prefix(src).expect("entry is under src");
```

Same pattern, same risk. Three `expect` calls in the same file, all on `strip_prefix`, all in library code.

**`crates/mcagent-core/src/wasi_types.rs` line 76:**
```rust
serde_json::to_string(metadata).expect("metadata serialization")
```

`print_metadata` is a helper for WASI tool binaries to use. If a tool has a `ToolMetadata` with a field that fails serialization (unlikely with the current types, but possible if the struct is extended), this panics inside the tool binary. Since WASI tools run in a sandbox, this panic is contained — it would produce a WASM trap, not a server crash. Lower severity, but still worth converting to a `Result` return or at minimum documenting why serialization cannot fail for the current types.

### C3. `unwrap()` in library code — 3 occurrences

**`crates/mcagent-wasi/src/compiler.rs` line 93:**
```rust
.unwrap_or("tool");
```

This is `unwrap_or`, not `unwrap` — it provides a fallback. No panic risk. Acceptable. (Noting for completeness; no action needed.)

**`crates/mcagent-mcp/src/server.rs` line 83:**
```rust
.ok_or_else(|| McAgentError::AgentNotFound(agent_id.parse().unwrap()))
```

`agent_id.parse().unwrap()` — `AgentId::from_str` returns `Infallible`, so this `unwrap()` is technically safe (the `Err` variant is uninhabited). However, this relies on the `FromStr` implementation never changing. If someone later changes `AgentId::from_str` to validate input, every `.parse().unwrap()` becomes a panic site. There are 3 such occurrences in `server.rs` (lines 83, 90, 111). Convert to `.parse().expect("AgentId::from_str is infallible")` at minimum, or better, add a `AgentId::from_string(s: String) -> Self` constructor that does not go through `FromStr`.

**`crates/mcagent-wasi/src/runtime.rs` lines 46 and 48:**
```rust
.file_stem().unwrap_or_default()
```

`unwrap_or_default` is safe — provides `OsStr::new("")`. No panic risk. Acceptable.

**`crates/mcagent-docker/src/backend.rs` line 153 and `crates/mcagent-wasi/src/backend.rs` line 85:**
```rust
output.status.code().unwrap_or(-1)
```

`unwrap_or` with a fallback. No panic. Acceptable.

### C4. No `unsafe` blocks — but the absence is suspicious

The codebase has zero `unsafe` blocks, which is normally what I want to see. But this project relies heavily on `wasmtime`, which internally uses extensive `unsafe`. The concern is not the crate code itself but the boundary: `wasmtime::Store`, `wasmtime::Linker`, and the WASI context types all have safety invariants around lifetimes and thread safety. The current code constructs everything within a single synchronous function (`run_preview1`, `run_preview2`) and does not leak `Store` references, so the invariants hold. Document this: "All wasmtime objects are constructed and consumed within a single `spawn_blocking` call. No `Store` or `Instance` references escape the function boundary."

### C5. Path traversal check is bypassable via symlinks

`crates/mcagent-mcp/src/tools/mod.rs` lines 323 and 350:
```rust
let file_path = agent.working_dir.join(&params.path);
if !file_path.starts_with(&agent.working_dir) {
    return err("Path traversal not allowed".to_string());
}
```

`starts_with` checks the logical path, not the resolved path. If an agent creates a symlink inside its working directory pointing outside (e.g., `ln -s /etc/passwd working_dir/escape`), then `working_dir.join("escape")` starts with `working_dir` but resolves to `/etc/passwd`. Use `std::fs::canonicalize` on both paths before the comparison, or use `file_path.canonicalize()?.starts_with(agent.working_dir.canonicalize()?)`.

This is a security boundary — the MCP server is the trust barrier between agents and the host filesystem. The path traversal check must be airtight.

### C6. `search_recursive` reads all files without size limits

`crates/mcagent-mcp/src/tools/mod.rs` lines 732-756: `search_recursive` calls `read_to_string` on every non-hidden file. If an agent's working directory contains large binary files (compiled artifacts, media), this will attempt to read them all into memory. Add a file size check (e.g., skip files > 1MB) and a `read_to_string` that respects encoding (skip binary files).

---

## What Is Missing

### M1. No panic policy documented anywhere

PROJECT.md, PLAN.md, and IDEAS.md do not mention panic freedom, `unwrap` policy, or error handling conventions. For a system that runs as a long-lived server hosting multiple agents, panic freedom in library code is a hard requirement. A single panic takes down every connected agent.

Recommendation: Add a `CONTRIBUTING.md` or a section in PROJECT.md:
- Library code must not panic. No `unwrap()`, `expect()`, `panic!()`, `unreachable!()`, or unchecked indexing.
- All errors must be propagated via `Result<T, McAgentError>`.
- `unwrap()` is acceptable only in `main.rs`, `#[test]`, and build scripts.

### M2. No crash recovery story

The PLAN.md describes the happy path: create agent, work, commit, destroy. It does not describe what happens when:
- The server process crashes mid-task
- An agent exceeds its wall-clock budget and is killed
- Docker/WASI execution hangs indefinitely
- Multiple servers start against the same project directory

The COW layer leaves git worktrees, the Docker backend leaves containers, and neither has a recovery mechanism. IDEAS.md mentions "Work-in-progress is preserved in the CowLayer for potential recovery" at the 100% budget kill threshold, but there is no implementation or design for how recovery works.

### M3. No timeout on external commands

`CowLayer::create`, `CowLayer::destroy`, `GitButlerCli::run`, and `DockerBackend::exec` all shell out to external commands (`git`, `but`, `docker`) without timeouts. A hung `git worktree add` or `docker exec` blocks the async runtime forever. Use `tokio::time::timeout` around all external command executions.

### M4. No concurrency safety documentation

`ServerState` is behind `Arc<RwLock<_>>`, which is correct. But the write lock is held across `await` points in several tool handlers (e.g., `agent_create` holds a write lock while calling `self.backend.create_isolation(..).await` and then `state.gitbutler.create_branch(..).await`). If either of these calls is slow, all other MCP tool calls are blocked. Document the locking strategy and consider whether finer-grained locking is needed as the system scales.

### M5. No integer overflow consideration in budget tracking

`BudgetUsage` fields are `u64` and `f64`. The `record_api_call` method uses `+=` without overflow checking. In release mode, `u64` wraps silently. At 2^64 API calls this is practically unreachable, but `f64` addition on `cpu_seconds_used` and `memory_mb_seconds_used` loses precision as values grow. For a billing system, this matters. Consider using `checked_add` or saturating arithmetic, and document the precision bounds.

### M6. PLAN.md does not mention safety review as part of the workflow

The workflow in PLAN.md is: task decomposition, agent creation, parallel execution, commit, PR. There is no step for automated safety checking — no `cargo clippy`, no `cargo deny`, no `unsafe` audit. Given that agents can write new WASI tools (`create_tool`), and those tools are compiled and executed, the system should automatically lint tool source code before compilation.

---

## Specific Recommendations

1. **Replace all `expect()` in `mcagent-cowfs/src/layer.rs` with `map_err(|_| McAgentError::internal(...))?`.** Three occurrences, all on `strip_prefix`. This is the highest-priority fix.

2. **Add `// NOTE: std::mem::forget` documentation to both backend files** explaining the ownership transfer and the recovery path for leaked worktrees.

3. **Fix the path traversal check** in `mcagent-mcp/src/tools/mod.rs` to use `canonicalize()` before `starts_with`. This is a security fix.

4. **Add `tokio::time::timeout` wrappers** around all external command invocations (`git`, `but`, `docker`). Suggest 30 seconds for `git` operations, 60 seconds for Docker operations.

5. **Add orphan worktree cleanup** to `workspace_init` — scan for worktrees that no longer have a corresponding agent in the server state.

6. **Document the panic policy** in the project. Every contributor and every agent writing WASI tools needs to know: library code does not panic.

7. **Add a file size limit** to `search_recursive` to prevent OOM on large binary files.

8. **Consider `AgentId::from_string`** to avoid the fragile `parse().unwrap()` pattern in `server.rs`.

---

## Assessment by Crate

| Crate | Verdict | Issues |
|-------|---------|--------|
| `mcagent-core` | ACK with note | `print_metadata` uses `expect` — low risk since it runs inside WASI sandbox |
| `mcagent-cowfs` | NACK | 3x `expect()` in library code on `strip_prefix` |
| `mcagent-wasi` | ACK | No unwrap/expect in library paths; wasmtime boundary is clean |
| `mcagent-mcp` | NACK | Symlink-bypassable path traversal check; `parse().unwrap()` on AgentId |
| `mcagent-gitbutler` | ACK | Clean error handling throughout |
| `mcagent-docker` | ACK with note | `std::mem::forget` needs documentation; otherwise clean |
| `mcagent-server` (binary) | ACK | `unwrap_or_else` and `expect` in main are acceptable |

---

## On the IDEAS.md

The ideas document shows good forward thinking. From a safety perspective:

- **WASI components future (Tool Creation Safety Progression)**: The migration path from Docker to pure WASI is exactly right. Docker gives you process isolation today; WASI gives you provable sandboxing tomorrow. The capability model described (filesystem scoped paths, network allowlists, no ambient authority) is the correct architecture.

- **Agent-to-Agent Communication**: The channel-based message passing is fine architecturally. The `conflict` channel for overlapping file edits is important. But the current COW layer provides filesystem isolation, so conflicts at the file level should not occur within a single workspace. Document what "conflict" means in the COW context — is it logical conflict (two agents editing semantically related code on different branches) or physical conflict (which should be impossible with proper isolation)?

- **Budget Tracking (Agent Hours)**: The append-only ledger (`ledger.jsonl`) is a good audit trail design. Ensure the ledger is fsynced on write — an async write that buffers could lose budget events on crash, allowing an agent to exceed its budget before the enforcement layer catches up.

---

## Summary

The project demonstrates strong engineering fundamentals. The architecture is well-layered, the trait boundaries are clean, and the error handling is correct in most paths. The issues I have identified are concentrated in three areas: (1) `expect()` in `mcagent-cowfs` library code, (2) the symlink-bypassable path traversal check in the MCP tools, and (3) the absence of crash recovery for leaked COW layers and Docker containers. All three are fixable without architectural changes.

If it's safe, prove it. If it's unsafe, document it. Right now, several invariants are assumed but not documented.

Signed-off-by: cto-legacy-modernizer@mcagent
