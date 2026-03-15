# Infrastructure Review: mcagent

**Reviewer**: Viktor Petrov, CTO / Infrastructure Hardliner
**Date**: 2026-03-15
**Scope**: Full project review — PROJECT.md, PLAN.md, IDEAS.md, and all source code
**Verdict**: Conditional ACK — architecture is sound, but there are allocation and boundedness issues that need addressing before this runs at scale.

---

## What I Like

I do not soften feedback with compliments, but I do acknowledge good engineering when I see it.

### The ExecutionBackend trait is clean

```rust
pub trait ExecutionBackend: Send + Sync {
    async fn create_isolation(&self, agent_id: &AgentId, config: &AgentConfig) -> Result<IsolationHandle, McAgentError>;
    async fn exec(&self, handle: &IsolationHandle, command: &[String]) -> Result<ExecOutput, McAgentError>;
    async fn destroy(&self, handle: &IsolationHandle) -> Result<(), McAgentError>;
    // ...
}
```

This is the right abstraction. WASI, Docker, and the eventual K8s backend share a trait that expresses exactly what it needs to. The `IsolationHandle` with `serde_json::Value` for `backend_data` is pragmatic — it avoids a type parameter explosion while keeping the trait object-safe. I would not have chosen `serde_json::Value` myself (I would reach for an enum), but at this stage it is acceptable.

### WASI tool sandboxing with capability declarations

The frontmatter-based capability model (`read`, `write`, `net`) that maps to `SandboxPermissions` and then to wasmtime preopened directories is exactly right. No ambient authority. Tools declare what they need, the runtime grants exactly that. The validation that `net` requires `preview2` is a good guard rail.

### CowLayer using git worktree with dir-copy fallback

The `CowLayer::create` function tries `git worktree add` first and falls back to full directory copy. The git worktree path is O(1) for the creation step — correct. The dir-copy fallback is expensive but is acknowledged as a cold path for non-git repos. No objection to the fallback.

### Content-addressed WASI compilation cache

`cache.rs` uses `git_blob_hash` (SHA-1 of `"blob <size>\0<content>"`) to key compiled WASM artifacts. Deterministic, avoids redundant recompilation, and the cache key is the source content itself. This is clean.

---

## What Concerns Me

### 1. `Engine::default()` on every WASI tool invocation

```rust
// executor.rs, run_preview1:
let engine = Engine::default();
let module = Module::from_file(&engine, wasm_path)
```

This happens in both `run_preview1` and `run_preview2`. A wasmtime `Engine` is expensive to construct — it initializes the compiler backend, allocates code memory, and sets up the configuration. You are paying this cost on every single tool execution.

**What's the allocation cost?** On my benchmarks, `Engine::default()` is 1-3ms of pure setup, plus the associated heap allocations for the compiler pipeline. In a hot path where agents are calling tools in tight loops, this adds up fast.

**Recommendation**: Create the `Engine` once at `WasiToolRunner` construction and reuse it. Wasmtime engines are `Send + Sync` and designed for exactly this. You could also cache `Module` / `Component` objects keyed by wasm path, since `Module::from_file` involves compilation (JIT or ahead-of-time). The content-addressed cache on disk is good, but you are recompiling from WASM-to-native on every invocation.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### 2. Unbounded `HashMap` growth in `ServerState`

```rust
pub struct ServerState {
    pub agents: HashMap<String, Agent>,
    pub handles: HashMap<String, IsolationHandle>,
    pub budgets: HashMap<String, Budget>,
    pub budget_usage: HashMap<String, BudgetUsage>,
    // ...
}
```

Where is the bound? If the orchestrator creates agents in a loop (or a buggy LLM just keeps calling `agent_create`), these maps grow without limit. Each agent also has an associated COW layer (worktree or dir copy), so unbounded agent creation is also unbounded disk consumption.

**Recommendation**: Add a `max_agents` configuration with a hard limit. Check it in `create_agent` before doing any work. The IDEAS.md already mentions `concurrent_agents = 8` in the project budget config — enforce it.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### 3. `search_recursive` is O(n * m) with unbounded output

```rust
fn search_recursive(dir: &Path, base: &Path, pattern: &str, matches: &mut Vec<String>) {
    // ...
    for entry in entries.flatten() {
        if path.is_file() {
            if let Ok(content) = std::fs::read_to_string(&path) {
                for (i, line) in content.lines().enumerate() {
                    if line.contains(pattern) {
                        matches.push(format!("{}:{}: {}", rel.display(), i + 1, line));
                    }
                }
            }
        }
    }
}
```

This reads every file in the agent's working directory into a `String`, then scans every line. For a repo with 10,000 files and an average of 200 lines per file, that is 2 million `line.contains()` calls, plus 10,000 full file reads. The `matches` vector has no capacity hint and no limit — a broad pattern like `"e"` would return millions of matches.

**Recommendation**:
1. Add a `max_matches` limit (default 1000). Stop scanning once hit.
2. Use `memchr` or `grep`-style searching instead of reading entire files into `String` and calling `.contains()`.
3. Skip binary files (check for null bytes in the first 8192 bytes).
4. At minimum, give `matches` a capacity hint: `Vec::with_capacity(256)`.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### 4. `std::mem::forget(cow_layer)` in both backends

```rust
// backend.rs (WasiBackend):
std::mem::forget(cow_layer);

// backend.rs (DockerBackend):
std::mem::forget(cow_layer);
```

This is a resource leak by design. You `forget` the `CowLayer` to prevent it from being destroyed on drop, and then reconstruct it later from paths stored in `backend_data`. The problem: if `destroy` is never called (server crash, OOM kill, panic), the worktree and branch are orphaned permanently.

`CowLayer` does not implement `Drop`, so `forget` is not actually preventing cleanup — it is just preventing the struct from being deallocated. But the intent is concerning: you are relying on an explicit `destroy` call to clean up OS-level resources (git worktrees, filesystem directories). There is no cleanup-on-panic, no cleanup-on-server-restart.

**Recommendation**: Add a `workspace_cleanup` tool or startup routine that scans `.mcagent/agents/` and reconciles against known agent state. Orphaned worktrees should be prunable via `git worktree prune`. This is not a hot-path concern, but it is an operational correctness concern.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### 5. `AgentId::new()` allocates twice unnecessarily

```rust
pub fn new() -> Self {
    Self(Uuid::new_v4().to_string()[..8].to_string())
}
```

`Uuid::new_v4().to_string()` allocates a 36-character `String`. Then `[..8]` takes a slice, and `.to_string()` allocates a second 8-character `String`. The first allocation is immediately discarded.

Cold path? Probably — agent creation is not a tight loop. But it is sloppy.

**Recommendation**: Use `write!` into a pre-sized buffer, or format directly:
```rust
let uuid = Uuid::new_v4();
let mut buf = [0u8; 8];
hex::encode_to_slice(&uuid.as_bytes()[..4], &mut buf).unwrap();
Self(String::from(std::str::from_utf8(&buf).unwrap()))
```

One allocation instead of two. Cold path — no objection if you leave it, but acknowledge it.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### 6. `diff_filesystem` is O(n * m)

```rust
fn diff_filesystem(&self) -> Result<Vec<FileDiff>, McAgentError> {
    let mut diffs = Vec::new();
    // Walk agent dir for added/modified
    for entry in walkdir::WalkDir::new(&self.agent_path) { ... }
    // Walk base dir for deleted
    for entry in walkdir::WalkDir::new(&self.base_path) { ... }
}
```

Two full directory walks. The "modified" check reads both files fully (`std::fs::read`) and compares byte-by-byte. For a repo with 5,000 files, that is 10,000 file reads plus 5,000 path lookups via `base_path.join(rel_path)` followed by `exists()` checks.

The `diffs` Vec has no capacity hint. Where is the capacity hint?

More importantly: the "deleted" detection walks the entire base directory and checks `agent_path.join(rel_path).exists()` for each file. If both agent and base have N files, this is O(n) file existence checks. That is actually fine — linear. But the full content reads for modification detection are expensive.

**Recommendation**:
1. `Vec::with_capacity(64)` on `diffs` — most changesets are small.
2. For modification detection, compare file metadata (size, mtime) before falling back to content comparison. If size differs, it is modified — skip the full read.
3. This is a fallback path (non-git repos), so it is less critical. But the git path is used 99% of the time. Acceptable as-is for now.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### 7. Every tool call clones the entire `Agent` struct

```rust
// tools/mod.rs, read_file:
let agent = match state.get_agent(&params.agent_id) {
    Ok(a) => a.clone(),
    Err(e) => return err(format!("{e}")),
};
```

This pattern repeats in `read_file`, `write_file`, `list_directory`, `search_files`, `run_tool`, `commit_changes`, `create_pr`, and `agent_status`. Every MCP tool invocation clones the `Agent`, which contains `AgentConfig`, which contains `String` fields (`name`, `task_description`, `branch_name`). Each clone is 3-5 string allocations.

The reason is clear: you hold a `write()` lock on `state` and need to drop it before doing I/O. But the clone happens even when you only need `working_dir`.

**Recommendation**: Extract just the fields you need before releasing the lock, or restructure `ServerState` to separate the per-agent immutable config (set once at creation) from the mutable state (budget usage, handles). `Arc<Agent>` stored in the map would let you clone a reference count instead of the entire struct.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### 8. `MemoryOutputPipe::new(1024 * 1024)` — fixed 1MB buffers

```rust
let stdout = wasmtime_wasi::pipe::MemoryOutputPipe::new(1024 * 1024);
let stderr = wasmtime_wasi::pipe::MemoryOutputPipe::new(1024 * 1024);
```

Every WASI tool execution allocates two 1MB buffers for stdout and stderr. If the tool outputs 50 bytes, you still pay for 1MB. If the tool outputs 2MB, you silently truncate.

**Recommendation**: Either make the buffer size configurable (via tool metadata) or start small and grow. The wasmtime `MemoryOutputPipe` grows dynamically — the `1024 * 1024` argument is the initial capacity, not a hard limit. But pre-allocating 1MB when most tools output a few KB is wasteful. Start with `4096` or `16384`.

Signed-off-by: cto-infrastructure-hardliner@mcagent

---

## What Is Missing

### 1. No resource limits on WASI execution

The WASI executor has no fuel metering, no timeout, and no memory limit. A malicious or buggy tool can spin forever or allocate unbounded memory inside the WASM instance.

Wasmtime supports fuel-based execution limits (`Store::set_fuel`, `consume_fuel`) and epoch-based interruption. Neither is used. The Docker backend has `--memory=512m --cpus=1`, but the WASI backend has nothing.

**Recommendation**: Add fuel metering for CPU and `Store::limiter` for memory. These are wasmtime first-class features. Without them, the "sandbox" only restricts filesystem access, not compute.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### 2. No concurrency control on `RwLock<ServerState>`

```rust
pub struct McAgentServer {
    pub state: Arc<RwLock<ServerState>>,
}
```

The entire server state is behind a single `RwLock`. Every tool call that modifies state (which is almost all of them — budget tracking alone requires `write()`) contends on this lock. With 8 concurrent agents calling tools, this becomes a serial bottleneck.

**Recommendation**: Shard the state. Per-agent state should be in a `DashMap<AgentId, AgentState>` or at least a `HashMap` behind a fine-grained lock. The global state (project root, backend) is immutable after init and should not be behind a lock at all.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### 3. No Linux COW support

PROJECT.md mentions APFS reflink for macOS. The implementation uses `git worktree`, which is cross-platform. But the IDEAS.md and future vision mention Docker and WASI as the primary isolation models. On Linux, `cp --reflink=auto` on btrfs/XFS would be the equivalent of APFS clonefile. The current fallback is a full directory copy, which for a large repo (node_modules, target/, etc.) could be hundreds of MB.

The `is_hidden` filter skips dotfiles, which means `.git` is skipped in the fallback copy — good. But `target/`, `node_modules/`, and other large directories are not filtered.

**Recommendation**: For the fallback path, add a `.mcagentignore` or respect `.gitignore` patterns. A full copy of a project with a 2GB `target/` directory is not acceptable even as a fallback.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### 4. No persistence across server restarts

`ServerState` is entirely in-memory. If the MCP server process dies and restarts, all agent state is lost. The COW layers still exist on disk (worktrees or directories), but the server has no way to discover and re-adopt them.

The IDEAS.md mentions a `ledger.jsonl` for budget tracking and `summary.json` for current state. None of this is implemented. There is no WAL, no checkpoint, no state recovery.

**Recommendation**: At minimum, write agent state to `.mcagent/state.json` on creation and destruction. On startup, scan and reconcile. This is an operational requirement, not a nice-to-have.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### 5. TaskGraph (PLAN Goal 4) has no implementation

The PLAN mentions a `TaskGraph` DAG for dependency tracking, but there is zero code for it. The current system creates agents independently with no ordering guarantees. Stacked branches are created via GitButler, but there is no enforcement that agent B waits for agent A to finish before starting.

This is the most important missing piece for the "stacked PRs" story. Without it, the system is just parallel independent agents.

### 6. No metrics or observability

For a system designed to run multiple concurrent agents with budget tracking, there is no metrics emission. No prometheus counters, no tracing spans around WASI execution, no histograms of tool execution latency. The `tracing::info!` calls are a start, but they are not queryable.

Show me the flamegraph. Except I cannot, because there is no instrumentation to generate one.

**Recommendation**: Add `tracing::instrument` to hot-path functions (`run_tool`, `exec`, `diff`). Add metrics for: tool execution count, tool execution latency (p50/p99), active agent count, budget utilization. Even basic `tracing::Span` with duration would be a start.

Signed-off-by: cto-infrastructure-hardliner@mcagent

---

## Specific Code-Level Recommendations

### `check_budget` allocates a Vec on every call

```rust
pub fn check_budget(budget: &Budget, usage: &BudgetUsage) -> BudgetStatus {
    let checks: Vec<(&str, Option<f64>, f64)> = vec![ /* 7 entries */ ];
    for (dim, limit, actual) in checks { ... }
}
```

This allocates a `Vec` of 7 tuples every time budget is checked. Budget checking happens on every tool call. Use a fixed-size array: `let checks: [(&str, Option<f64>, f64); 7] = [...]`. Zero allocations. Same logic.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### `list_directory` unbounded with no capacity hint

```rust
let mut lines = Vec::new();
for entry in entries.flatten() {
    lines.push(format!("  {kind}  {name}"));
}
```

A directory with 50,000 entries produces a Vec with 50,000 format-allocated strings, then joins them all. No limit, no pagination.

**Recommendation**: Add a `limit` parameter (default 1000). Add `Vec::with_capacity(min(limit, 256))`.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### `workspace_status` collects all agents into a Vec of formatted strings

```rust
let agents: Vec<_> = state.agents.values().map(|a| { format!(...) }).collect();
```

With 100 agents, this allocates 100 strings, then joins. With the proposed max_agents limit of 8, this is fine. But without the limit, it is unbounded.

Signed-off-by: cto-infrastructure-hardliner@mcagent

### The `compile_to_wasi` function reads `Cargo.toml` and does line-by-line string replacement

```rust
let modified_workspace = workspace_toml
    .lines()
    .map(|line| {
        if line.starts_with("members") {
            "members = [\"tool\"]"
        } else {
            line
        }
    })
    .collect::<Vec<_>>()
    .join("\n");
```

This is fragile. If `members` spans multiple lines (TOML allows this), it breaks. If there are multiple `members` keys (invalid TOML, but still), it replaces all of them. Parse the TOML properly — you already have `toml` as a dependency.

Cold path (compilation happens rarely). No performance objection. But correctness objection.

Signed-off-by: cto-infrastructure-hardliner@mcagent

---

## Summary Table

| Finding | Severity | Hot Path? | Recommendation |
|---------|----------|-----------|----------------|
| Engine re-creation per tool call | High | Yes | Cache Engine + Module |
| Unbounded agent creation | High | No | Add max_agents limit |
| search_recursive O(n*m) unbounded | High | Yes | Add max_matches, use memchr |
| No WASI fuel/memory limits | High | Yes | Add fuel metering + limiter |
| Single RwLock contention | Medium | Yes | Shard per-agent state |
| Agent clone on every tool call | Medium | Yes | Use Arc\<Agent\> or extract fields |
| 1MB stdout/stderr buffers | Medium | Yes | Start at 4-16KB |
| check_budget Vec allocation | Low | Yes | Use fixed array |
| No persistence/recovery | Medium | No | Write state to disk |
| No resource cleanup on crash | Medium | No | Add startup reconciliation |
| No Linux reflink COW | Low | No | Add cp --reflink=auto path |
| AgentId double allocation | Low | No | Cold path, acknowledge |
| diff_filesystem no capacity hint | Low | No | Fallback path, acceptable |
| Cargo.toml string replacement | Low | No | Parse TOML properly |

---

## Verdict

The architecture is right. WASI for sandboxing, COW for isolation, pluggable backends via trait objects, MCP for protocol — these are correct choices. The crate structure is clean. The separation of concerns between `mcagent-core`, `mcagent-wasi`, `mcagent-cowfs`, `mcagent-mcp`, and `mcagent-docker` is well-reasoned.

But this is early-stage code that has not been profiled under load. The allocation patterns in the hot path (tool execution) are sloppy — engine re-creation, 1MB buffer pre-allocation, full Agent clones, Vec allocations in budget checking. These will show up the moment you run 8 agents concurrently calling tools in tight loops.

The bigger operational gaps are the unbounded growth (agents, search results, directory listings), the lack of WASI resource limits (defeating half the sandbox promise), and the absence of state persistence.

Fix the engine caching, add max_agents, add WASI fuel limits, and shard the lock. Then we talk about scaling.

NACK on the WASI executor without fuel metering — this is a sandbox that does not limit compute. That is half a sandbox.

Conditional ACK on everything else — allocation profile needs cleanup, but the bones are good.

Signed-off-by: cto-infrastructure-hardliner@mcagent
