# Architectural Review: mcagent

**Reviewer:** the-architect@mcagent
**Scope:** PROJECT.md, PLAN.md, IDEAS.md, full workspace source
**Date:** 2026-03-15

---

## What Excites Me

### The layered architecture is genuinely well-stratified

The four-layer stack (WASI sandbox -> COW filesystem -> GitButler -> MCP server) maps cleanly to four distinct responsibilities. Each layer has a single reason to change. The dependency arrows point the right way: `mcagent-core` at the bottom knows nothing about MCP, COW, or WASI. The MCP layer sits at the top, assembling everything. This is correct.

The workspace `Cargo.toml` makes the intended layering explicit:

```
mcagent-core       (foundation: types, traits, errors, budget)
mcagent-cowfs      (depends on core)
mcagent-wasi       (depends on core, cowfs)
mcagent-docker     (depends on core, cowfs)
mcagent-gitbutler  (depends on core)
mcagent-mcp        (depends on core, cowfs, wasi, gitbutler)
mcagent-server     (binary, depends on core, mcp, wasi, docker)
```

No circular dependencies. Dependencies point from specific to general. This is the kind of graph I want to see.

### The `ExecutionBackend` trait is the right abstraction

Having `WasiBackend` and `DockerBackend` implement the same `ExecutionBackend` trait, composed with `CowLayer`, means swapping isolation strategies is a matter of constructing a different backend. The trait surface is minimal: five methods, all clearly necessary. This is a trait I can reason about.

### CowLayer using git worktrees is clever

Using `git worktree` for COW instead of APFS reflink was the right call. It makes the project cross-platform and leverages git's existing object deduplication. The fallback to directory copy for non-git repos shows pragmatism without over-engineering.

### Budget tracking in core is well-placed

`Budget`, `BudgetUsage`, and `check_budget` belong in `mcagent-core`. They are pure data + logic with no dependencies on any backend. This is infrastructure that every layer above can use without pulling in anything inappropriate. Good placement.

---

## What Concerns Me

### 1. `mcagent-mcp` is becoming a god crate

`mcagent-mcp` depends on `mcagent-core`, `mcagent-cowfs`, `mcagent-wasi`, and `mcagent-gitbutler`. That is four internal dependencies. The `tools/mod.rs` file is already 756 lines with 17 tool implementations. Every new MCP tool adds to this file, every new feature adds a new dependency, and every refactor touches it.

What is the blast radius when `tools/mod.rs` changes? Every consumer of `mcagent-mcp`. Today that is only `mcagent-server`, but the PLAN.md describes `list_agent_templates`, `create_task`, `add_dependency`, `get_task_order`, and `orchestrate` as future tools. This file will grow past 1,500 lines if left unchecked.

**Recommendation:** Split the tool implementations into separate submodules within `mcagent-mcp`: `tools/workspace.rs`, `tools/agent.rs`, `tools/filesystem.rs`, `tools/wasi.rs`, `tools/git.rs`, `tools/budget.rs`. The `tools/mod.rs` keeps only the `#[rmcp::tool_router]` wiring. Each submodule gets one concern, one reason to change.

### 2. `ServerState` holds too much

`ServerState` is a struct with eight fields: `project_root`, `agents_dir`, `agents`, `handles`, `budgets`, `budget_usage`, `backend`, `gitbutler`, `wasi_runner`. It is the entire world. Every tool method takes `&self.state` and reaches into whatever field it needs. This is a bag, not a design.

When PLAN.md Goal 4 adds `TaskGraph`, where does it go? Into `ServerState`, naturally. When IDEAS.md adds agent memory, agent reputation, budget ledger, and message channels? Also `ServerState`. This struct is on trajectory to become a 20-field monolith behind a single `RwLock`.

**Recommendation:** Decompose `ServerState` into focused sub-managers. An `AgentRegistry` that owns agents, handles, budgets. A `ToolManager` that owns the WASI runner. A `GitManager` that owns the GitButler CLI. Each gets its own `RwLock` so that reading agent status does not contend with WASI tool compilation. The `McAgentServer` composes these managers, and tool implementations receive only the manager they need.

### 3. `std::mem::forget(cow_layer)` is a red flag

Both `WasiBackend::create_isolation` and `DockerBackend::create_isolation` call `std::mem::forget(cow_layer)` to prevent the `CowLayer` from being destroyed when it goes out of scope. But `CowLayer` does not implement `Drop` -- there is nothing to forget. This suggests the code was written defensively against a `Drop` impl that does not exist, or that the intent was to implement `Drop` but it was never done.

Either way, the `forget` is misleading. If `CowLayer` ever gets a `Drop` impl, the `forget` silently prevents cleanup on the error paths that follow. If it never gets `Drop`, the `forget` is dead ceremony that confuses readers.

**Recommendation:** Remove the `std::mem::forget` calls. Document on `CowLayer` that it is intentionally not `Drop` and that callers must explicitly call `destroy()`. Or, implement `Drop` properly and use `ManuallyDrop` where you genuinely need to defer destruction.

### 4. `reconstruct_cow_layer` is duplicated across backends

Both `mcagent-wasi/src/backend.rs` and `mcagent-docker/src/backend.rs` contain identical `reconstruct_cow_layer` functions. This is a boundary violation: both backend crates depend on `mcagent-cowfs` and know how to unpack `backend_data` JSON into `CowLayer::from_existing`. When the `backend_data` schema changes, both break.

**Recommendation:** Move `reconstruct_cow_layer` (or a `CowLayer::from_backend_data` associated function) into `mcagent-cowfs`. The backends should not need to know the JSON schema of backend_data -- they should call a single function that handles deserialization. This reduces the coupling surface between the backend crates and the COW layer.

### 5. `IsolationHandle::backend_data` is `serde_json::Value`

Typed crate, untyped data. `backend_data` is a `serde_json::Value` that both backends pack and unpack by string key (`"agent_path"`, `"base_path"`, `"agents_dir"`, `"container_name"`). A typo in any key silently produces `None`, which becomes a runtime error. There is no compile-time guarantee that the data written in `create_isolation` matches the data read in `diff`/`destroy`.

**Recommendation:** Define backend-specific data types. `WasiBackendData` and `DockerBackendData` as serializable structs. Serialize to `serde_json::Value` at the boundary, but pack/unpack through strongly-typed intermediaries. Even better: make `IsolationHandle` generic over backend data, or use an enum.

### 6. The COW layer and GitButler operate on parallel branch concepts

`CowLayer::create` creates a branch named `mcagent/{agent_id}`. `ServerState::create_agent` creates a GitButler branch named `agent/{agent_id}` (or a user-provided name). These are two separate branches for the same agent. The git worktree branch is a git ref; the GitButler branch is a virtual branch in GitButler's workspace model. But the code does not make this distinction clear, and the naming collision risk is real.

When `commit_changes` runs, it commits via GitButler, but the diff is computed from the COW layer's git worktree. These are different git contexts. If the worktree branch and the GitButler branch diverge, the changeset from `diff()` may not match what GitButler commits.

**Recommendation:** Document the dual-branch model explicitly. Consider whether the COW layer should use a detached HEAD instead of a named branch, since its branch is purely an implementation detail of `git worktree add`. The GitButler branch is the "real" branch. Keeping both named creates a namespace collision risk.

### 7. PLAN.md Goal 4 (`TaskGraph`) belongs in `mcagent-core`, but it will pull in graph algorithms

A `TaskGraph` with dependency edges needs topological sorting. That means either a dependency on `petgraph` or a hand-rolled topo sort. `mcagent-core` currently has five dependencies (`async-trait`, `serde`, `serde_json`, `thiserror`, `uuid`), all lightweight. Adding `petgraph` would nearly double the compilation unit.

**Recommendation:** Create a new `mcagent-task` crate for `TaskGraph` and its MCP tools. It depends on `mcagent-core` for `TaskId` and `AgentId`. The graph algorithm dependency stays out of the foundation crate. `mcagent-mcp` depends on `mcagent-task` for the orchestration tools.

---

## What Is Missing

### 1. No trait for GitButler integration

`GitButlerCli` is a concrete struct that shells out to the `but` CLI. There is no `trait GitOps` or similar abstraction. This means:

- Testing the MCP server requires a working `but` binary on PATH.
- Swapping to a different Git backend (raw `git2`, `gitoxide`, a mock) requires changing `ServerState`.
- The Docker backend cannot independently test its git integration.

**Recommendation:** Extract a `trait BranchManager` (or similar) with `create_branch`, `commit`, `push`, `list_branches`. `GitButlerCli` implements it. Tests use a mock. `ServerState` holds `Arc<dyn BranchManager>`, same pattern as `Arc<dyn ExecutionBackend>`.

### 2. No agent lifecycle state machine

`AgentState` has five variants (`Created`, `Working`, `Checkpointing`, `Completing`, `Done`) but there are no enforced transitions. Any code can set `agent.state = AgentState::Done` directly. The `Agent` struct has `pub state` -- any holder can mutate it arbitrarily.

The PLAN.md implies a lifecycle (create -> work -> checkpoint -> complete -> done), but nothing enforces it. An agent in `Done` state can still have tools called against it. An agent in `Created` state can be committed.

**Recommendation:** Make `AgentState` transitions explicit. A `transition(&mut self, to: AgentState) -> Result<(), InvalidTransition>` method that validates the from/to pair. Make `state` private (`pub(crate)`) and expose it through a getter. This prevents impossible states like `Done -> Working`.

### 3. No cleanup or recovery strategy

What happens when the MCP server crashes mid-operation? COW layers (git worktrees) are left on disk. Docker containers continue running. GitButler branches are half-created. There is no startup reconciliation: the server starts fresh with empty `HashMap`s in `ServerState`.

The IDEAS.md mentions "work-in-progress is preserved in the CowLayer for potential recovery" at 100% budget kill, but there is no implementation or design for recovery.

**Recommendation:** On startup, scan `.mcagent/agents/` for existing worktrees. Reconcile against GitButler branches. Offer a `workspace_cleanup` MCP tool that finds and destroys orphaned isolation contexts. Store agent metadata to disk (a `state.json` per agent) so the server can reconstruct after a restart.

### 4. No concurrency control on the COW layer

Multiple agents can have COW layers that modify the same files. The PROJECT.md acknowledges this ("Conflict detection when COW layers overlap on the same files" in Goal 5) but there is no mechanism today. Two agents editing `src/main.rs` will both produce diffs, both commit via GitButler, and the result depends on commit ordering.

**Recommendation:** At minimum, track which files each agent's COW layer has modified (the `diff()` data is already available). Before committing, check for overlaps with other active agents. This does not need to be a lock -- a warning is sufficient for the first iteration.

### 5. Missing `exec` tool in MCP

The `ExecutionBackend` trait has an `exec` method for running arbitrary commands in an agent's isolation context. But there is no MCP tool that exposes it. Agents can `read_file`, `write_file`, and `run_tool` (WASI), but they cannot run `cargo test` or `cargo check` inside their isolation context without a WASI tool wrapper.

The PLAN.md Goal 3 lists `compile_check.rs` and `test_runner.rs` as WASI tools, but these are separate compilation targets that need to be built and deployed. A direct `exec` tool would provide immediate value.

**Recommendation:** Add an `exec_command` MCP tool that calls `backend.exec(handle, command)`. Gate it behind an explicit capability flag in the agent config so that it can be disabled for untrusted agents.

### 6. No visibility control on re-exports

`mcagent-core/src/lib.rs` uses `pub use types::*`, `pub use error::*`, `pub use execution::*`, `pub use wasi_types::*`, `pub use budget::*`. This means every `pub` item in every submodule becomes part of `mcagent-core`'s public API. Adding a helper function to `budget.rs` that happens to be `pub` automatically exports it from the crate.

`mcagent-gitbutler/src/lib.rs` has `pub use types::*` -- same problem. Any addition to `types.rs` is automatically part of the crate's public API.

**Recommendation:** Replace wildcard re-exports with explicit re-exports. List every type that should be part of the crate's public API. This makes the API surface intentional rather than accidental.

---

## Specific Recommendations (Priority Order)

1. **Split `tools/mod.rs`** into per-concern submodules. This is the highest-leverage structural change and prevents the file from becoming unmanageable as PLAN.md goals are implemented. Do this before adding any new tools.

2. **Decompose `ServerState`** into focused sub-managers with independent locks. This unblocks concurrent tool execution and keeps the state struct from growing unbounded.

3. **Type the `backend_data` field** in `IsolationHandle`. Move `reconstruct_cow_layer` into `mcagent-cowfs`. Eliminate the duplicated JSON unpacking.

4. **Extract a `BranchManager` trait** from `GitButlerCli`. This is prerequisite for testability and for the meta-mono-repo idea in IDEAS.md (which would need a different git backend per repo).

5. **Create `mcagent-task`** as a new crate before implementing PLAN.md Goal 4. Do not add graph dependencies to `mcagent-core`.

6. **Replace wildcard re-exports** with explicit item lists in `mcagent-core` and `mcagent-gitbutler`.

7. **Add startup reconciliation** -- scan for orphaned worktrees, containers, and branches. Without this, the system leaks resources on every crash.

---

## Verdict

The foundation is sound. Dependencies point the right way. The `ExecutionBackend` trait is clean. The crate structure follows single-responsibility at the crate level. The dual COW+GitButler model is novel and the git-worktree approach is pragmatic.

But the growth trajectory concerns me. `ServerState` and `tools/mod.rs` are already showing signs of accretion. The PLAN.md and IDEAS.md describe at least six new capabilities (task graphs, agent templates, agent memory, agent communication, budget ledger, meta-mono-repo) that will all converge on these two points unless the structure is decomposed first.

The untyped `backend_data`, the duplicated `reconstruct_cow_layer`, and the `std::mem::forget` pattern are structural debts that will compound. Fix them while the codebase is small.

I am not blocking -- the current architecture is correct for its current size. But I would block any PR that adds PLAN.md Goal 4 or IDEAS.md features without first addressing recommendations 1-3.

How many crates need to rebuild when `tools/mod.rs` changes? Today, just `mcagent-server`. But when that file is 2,000 lines, the rebuild time will hurt. Decompose now while it is cheap.

---

Signed-off-by: the-architect@mcagent
