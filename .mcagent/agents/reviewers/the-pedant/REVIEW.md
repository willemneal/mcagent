# Review: IDEAS.md, PLAN.md, PROJECT.md

## Summary

Thank you for the documents. The vision is ambitious and the technology choices are defensible. I have reviewed all three documents and cross-referenced them against the existing codebase (`mcagent-core`, `mcagent-cowfs`, `mcagent-wasi`, `mcagent-mcp`, `mcagent-gitbutler`, `mcagent-docker`). My review is scoped strictly to naming, style, consistency, import conventions, visibility, and documentation — per my charter.

There are **23** items that need attention before these documents should be considered authoritative guides for implementation.

---

## What Excites Me

1. **The crate naming is consistent and well-structured.** Every crate follows `mcagent-{domain}` in `snake-case` with full words (`mcagent-cowfs` is the one exception — more on that below). The workspace `Cargo.toml` lists them in a logical grouping. This is a foundation I can build on.

2. **The existing code is remarkably consistent for an early project.** Types are `CamelCase`, functions are `snake_case`, all public items have `///` doc comments, and the import ordering in most files follows the canonical `std` -> external -> workspace -> local pattern. Whoever wrote the initial code shares my values.

3. **The PLAN.md has clear deliverable sections.** Each goal is numbered, each deliverable is a bullet. There is no ambiguity about what "done" means. This is how plans should read.

4. **The IDEAS.md is properly labelled as ideas.** It does not pretend to be a specification. This is honest and appropriate.

---

## What Concerns Me

### 1. Naming Inconsistency: `cowfs` vs `CowLayer` vs "COW Filesystem"

Per RFC 430, type names should use complete words. The crate is named `mcagent-cowfs`, the struct is `CowLayer`, the PROJECT.md says "COW Filesystem", the PLAN.md says "COW layers", and IDEAS.md says "CowLayer/Docker backend".

"COW" is a well-understood abbreviation in systems programming (copy-on-write), so I will accept it. But "cowfs" is not. Is it "cow filesystem"? "cow fs"? The crate name should be `mcagent-cow` or `mcagent-cow-fs` (with the hyphen). The concatenated `cowfs` reads like a word — "cow-fuss" — not an abbreviation pair.

Recommendation: Rename the crate to `mcagent-cow` since the struct inside is `CowLayer`, not `CowFs` or `CowFilesystem`. The crate name should reflect its primary export.

### 2. Abbreviations in PLAN.md

> "COW lifecycle"

Spell it out on first use: "Copy-on-Write (COW) lifecycle". After that, "COW" is acceptable. PLAN.md uses "COW" eleven times without ever expanding it. A reader unfamiliar with the term would be lost.

> "WASI tool management instructions"

WASI is acceptable — it is a W3C standard name. But it should be expanded on first use in each document: "WebAssembly System Interface (WASI)".

### 3. The `Pr` Abbreviation in Types

In `mcagent-gitbutler/src/types.rs`:

```rust
pub struct PrInfo {
    pub number: u64,
    pub url: String,
}
```

Per RFC 430, "Pr" is ambiguous. It could mean "pull request", "print", or "probability". Rename to `PullRequestInfo`. Similarly, PLAN.md says "stacked PRs" — fine in prose, but any types derived from this plan should use the full name.

### 4. Field Naming Inconsistency in `Budget`

In `mcagent-core/src/budget.rs`:

```rust
pub struct Budget {
    pub token_input_limit: Option<u64>,
    pub token_output_limit: Option<u64>,
    pub cpu_seconds: Option<f64>,
    pub memory_mb_seconds: Option<f64>,
    pub wall_clock_seconds: Option<u64>,
    pub api_calls: Option<u64>,
    pub work_hours: Option<f64>,
}
```

The naming convention is inconsistent. Some fields have a `_limit` suffix (`token_input_limit`), others do not (`cpu_seconds`, `api_calls`). Since this is a `Budget` struct — i.e., all fields *are* limits — either all should have `_limit` or none should. I prefer none: `token_input`, `token_output`, `cpu_seconds`, `memory_mb_seconds`, `wall_clock_seconds`, `api_calls`, `work_hours`. The struct name provides the context.

The IDEAS.md budget section proposes `max_cost_usd`, `max_api_calls`, `wall_clock_minutes` — yet another convention using `max_` prefix and different time units. If IDEAS.md becomes implementation, this inconsistency will compound. Settle on a convention now.

### 5. `mem_mb_secs` Would Be Unacceptable

The existing code uses `memory_mb_seconds` (good). But I see abbreviation pressure building — `record_compute` takes `mem_mb_secs: f64`. The parameter name abbreviates what the field name spells out. These must match. Rename the parameter to `memory_mb_seconds`.

### 6. Visibility Is Too Broad

In `mcagent-core/src/lib.rs`:

```rust
pub mod budget;
mod error;
pub mod execution;
mod types;
pub mod wasi_types;

pub use budget::*;
pub use error::*;
pub use execution::*;
pub use types::*;
pub use wasi_types::*;
```

Every module is glob-re-exported. This means every `pub` item in every submodule becomes part of the crate's public API. This is the opposite of minimal visibility. When the crate grows, this will cause name collisions, make it impossible to know what is public API vs internal, and prevent any refactoring without semver bumps.

Recommendation: Replace `pub use module::*` with explicit re-exports listing each type by name. This forces a conscious decision about what is public API.

### 7. Missing `#[must_use]` on Functions Returning Non-Trivial Values

The following functions return values that the caller should not discard:

- `AgentId::new()` — returns a new ID
- `TaskId::new()` — returns a new ID
- `CowLayer::create()` — returns an isolation layer
- `CowLayer::diff()` — returns a diff set
- `check_budget()` — returns budget status
- `estimate_task_budget()` — returns a budget
- `WasiToolRunner::compile_tool()` — returns a path

All of these should have `#[must_use]`. Discarding any of these return values is almost certainly a bug.

### 8. IDEAS.md Proposes Snake-Case MCP Tool Names — Good, But Verify Consistency

IDEAS.md proposes: `memory_store`, `memory_search`, `memory_list`, `memory_forget`, `budget_status`, `budget_remaining`, `budget_report`, `budget_adjust`, `send_message`, `read_messages`, `broadcast`, `sync_issues`, `sync_prs`.

The existing MCP tools in `mcagent-mcp/src/tools/mod.rs` use: `workspace_init`, `workspace_status`, `agent_create`, `agent_status`, `agent_destroy`, `read_file`, `write_file`, `list_directory`, `search_files`, `run_tool`, `compile_tool`, `list_wasi_tools`, `create_tool`, `commit_changes`, `create_branch`, `create_pr`, `list_branches`, `set_budget`, `get_budget_usage`, `estimate_task_budget`.

The naming pattern is `{noun}_{verb}` for some (`agent_create`) and `{verb}_{noun}` for others (`read_file`, `create_tool`). Pick one. The Rust convention for methods is `verb_noun` (e.g., `read_file`). The `agent_create` / `agent_status` / `agent_destroy` pattern reads more like a CLI subcommand (`agent create`). If these are MCP tool names exposed to external consumers, the CLI-subcommand style has merit for discoverability — but then `read_file` should be `file_read`, `commit_changes` should be `changes_commit`, etc. You cannot have both.

Recommendation: Standardize on `{domain}_{verb}` for all MCP tools: `workspace_init`, `workspace_status`, `agent_create`, `agent_status`, `agent_destroy`, `file_read`, `file_write`, `directory_list`, `file_search`, `tool_run`, `tool_compile`, `tool_list`, `tool_create`, `changes_commit`, `branch_create`, `branch_list`, `pr_create`, `budget_set`, `budget_get`, `budget_estimate`. This groups tools by domain when sorted alphabetically.

### 9. PLAN.md Goal 3: Tool File Names Use Snake Case — Verify

> `tools/read_file.rs`, `tools/write_file.rs`, `tools/list_dir.rs`, `tools/compile_check.rs`, `tools/test_runner.rs`

`list_dir` abbreviates "directory" to "dir". Per RFC 430 and the project's own existing code (`list_directory` in `tools/mod.rs`), this should be `list_directory.rs`. Consistency with the existing MCP tool name is paramount.

### 10. `McAgentError` Variant Naming

In `mcagent-core/src/error.rs`, the variants mix domain-specific names (`GitButler`, `Docker`, `WasiRuntime`) with generic names (`Other`, `InvalidConfig`). The `Other(String)` variant is a code smell in a typed error enum — it is an escape hatch that will accumulate technical debt. Every use of `McAgentError::Other` is a naming violation waiting to happen, because it defers the decision of what the error *is*.

Recommendation: Add a `// TODO: remove Other variant once all error cases are named` comment at minimum. Better: remove it now and force callers to name their errors.

### 11. Import Ordering Violations

In `mcagent-core/src/error.rs`:

```rust
use std::path::PathBuf;

use crate::AgentId;
```

This is correct — `std` first, then `crate` imports, separated by a blank line. Good.

In `mcagent-mcp/src/server.rs`:

```rust
use mcagent_core::{...};
use mcagent_gitbutler::GitButlerCli;
use mcagent_wasi::WasiToolRunner;
use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::model::{ServerCapabilities, ServerInfo};
use rmcp::ServerHandler;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use tokio::sync::RwLock;
```

This is **wrong**. `std` imports (`HashMap`, `PathBuf`, `Arc`) appear after workspace and external crate imports. The canonical ordering is:

1. `std` / `core` / `alloc`
2. External crates (`rmcp`, `tokio`, `serde`, etc.)
3. Workspace crates (`mcagent_core`, `mcagent_gitbutler`, `mcagent_wasi`)
4. `self` / `super` / `crate`

Corrected:

```rust
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use rmcp::handler::server::router::tool::ToolRouter;
use rmcp::model::{ServerCapabilities, ServerInfo};
use rmcp::ServerHandler;
use tokio::sync::RwLock;

use mcagent_core::{...};
use mcagent_gitbutler::GitButlerCli;
use mcagent_wasi::WasiToolRunner;
```

The same violation appears in `mcagent-mcp/src/tools/mod.rs` and `mcagent-cowfs/src/layer.rs`. Fix all of them.

---

## What Is Missing

### 12. No Style Guide Document

The project has PLAN.md, IDEAS.md, PROJECT.md — but no `STYLE.md` or equivalent. The naming and import conventions I have described above should be codified in a binding style guide so that contributors (human or agent) can reference it. Without one, every PR will re-litigate these decisions.

### 13. No `clippy.toml` or Lint Configuration

The workspace `Cargo.toml` does not configure `[workspace.lints]`. There is no `clippy.toml`. The `#![deny(clippy::all)]` or `#![warn(clippy::pedantic)]` directives are absent from all `lib.rs` files. For a project with "pedant" as a reviewer archetype, this is ironic.

Recommendation: Add to the workspace `Cargo.toml`:

```toml
[workspace.lints.clippy]
all = "warn"
pedantic = "warn"
nursery = "warn"
```

And in each crate's `Cargo.toml`:

```toml
[lints]
workspace = true
```

### 14. No Documentation Comments on Modules

In `mcagent-core/src/lib.rs`, the modules have no `//!` crate-level documentation. The file jumps straight into `pub mod budget`. Add at minimum:

```rust
//! Core types, traits, and error definitions for the mcagent workspace.
```

Same for every other crate's `lib.rs`.

### 15. IDEAS.md Agent Communication Channel Names

The proposed channels — `progress`, `discovery`, `conflict`, `review` — are not namespaced. When this becomes a type, will it be an enum? A string? If an enum:

```rust
pub enum Channel {
    Progress,
    Discovery,
    Conflict,
    Review,
}
```

This is fine per RFC 430. But the document does not specify this. It should, because string-typed channels will inevitably drift ("progress" vs "Progress" vs "PROGRESS").

### 16. IDEAS.md `repos.toml` Uses `[[repo]]` — Should Be `[[repos]]`

```toml
[[repo]]
name = "frontend"
```

TOML array-of-tables should use the plural form: `[[repos]]`. A single `[[repo]]` entry is confusing because it looks like a singular table, not an array element. This is a style convention, not a TOML requirement, but it is the dominant convention in the Rust ecosystem (see `Cargo.toml`'s `[[bin]]`, `[[example]]`, `[[bench]]`).

Wait — actually Cargo uses singular forms (`[[bin]]`, `[[test]]`). I retract. The TOML convention in Rust is singular. `[[repo]]` is fine. (I leave this note to show my work.)

### 17. Missing `Serialize`/`Deserialize` on `ExecOutput`

In `mcagent-core/src/execution.rs`:

```rust
#[derive(Debug, Clone)]
pub struct ExecOutput {
```

`AgentConfig`, `Agent`, `FileDiff`, `Budget`, `BudgetUsage`, `BudgetStatus` all derive `Serialize, Deserialize`. `ExecOutput` and `IsolationHandle` do not, despite being public types that will need to cross serialization boundaries (MCP tool responses, logging, state persistence). Either derive `Serialize, Deserialize` on them or document why they are excluded.

### 18. PROJECT.md Claims APFS Reflink — Code Uses Git Worktrees

PROJECT.md states:

> "Copy-on-Write filesystems — Each agent gets an instant, isolated clone of the repo (via APFS reflink)"

The actual code in `mcagent-cowfs/src/layer.rs` uses `git worktree`, with a fallback to full directory copy. The `Cargo.toml` lists `reflink-copy = "0.1"` as a dependency, but I found zero uses of it in the codebase. The PROJECT.md is misleading. Either update the document to reflect reality, or implement the APFS reflink path and use `reflink-copy`.

The workspace `Cargo.toml` also lists `reflink-copy` but no crate imports it. This is an unused dependency. Remove it.

### 19. PLAN.md Goal 4: `TaskGraph` — No Corresponding Type Exists

PLAN.md proposes:

> `TaskGraph` in `mcagent-core` — DAG of tasks with dependency edges

There is a `TaskId` type but no `Task` struct, no `TaskGraph`, no dependency edge type. This is fine for a plan, but the naming should be decided now:

- `TaskGraph` or `TaskDependencyGraph`?
- Edge type: `TaskDependency` or `DependencyEdge`?
- MCP tools: `create_task` or `task_create`? (See item 8.)

Decide these names in PLAN.md so they do not become ad-hoc during implementation.

---

## Specific Recommendations

### R1: Establish a canonical naming convention table

Add a section to a project style guide (or PLAN.md) that codifies:

| Entity | Convention | Example |
|--------|-----------|---------|
| Crate names | `mcagent-{domain}` | `mcagent-core`, `mcagent-cow` |
| Types | `CamelCase`, full words | `CowLayer`, `PullRequestInfo` |
| Functions | `snake_case`, verb-first | `create_isolation`, `check_budget` |
| MCP tools | `{domain}_{verb}` | `agent_create`, `tool_compile` |
| Fields | `snake_case`, no suffix duplication | `token_input` not `token_input_limit` on a `Budget` |
| Constants | `SCREAMING_SNAKE_CASE` | `SUCCESS`, `TOOL_SPECIFIC_START` |
| Modules | `snake_case`, full words | `execution`, `frontmatter` |

### R2: Add `#[must_use]` sweep

Every function in the public API that returns a non-unit, non-`()` value should have `#[must_use]`. This is a one-time sweep that prevents an entire class of bugs.

### R3: Fix import ordering project-wide

Run `cargo fmt` (which does not fix import ordering by default) and then either:
- Configure `rustfmt.toml` with `imports_granularity = "Module"` and `group_imports = "StdExternalCrate"`
- Or manually fix the three files identified above

### R4: Align IDEAS.md budget field names with existing code

If `Budget` in `mcagent-core` is the source of truth, IDEAS.md should reference those field names, not invent new ones (`max_cost_usd`, `max_api_calls`). If IDEAS.md is proposing an evolution of the struct, say so explicitly: "extends the existing `Budget` struct with new fields: `max_cost_usd: Option<f64>`".

### R5: Remove unused `reflink-copy` dependency

It is listed in `[workspace.dependencies]` but no crate uses it. Dead dependencies are dead code.

### R6: Document all public items before expanding the API

Before implementing PLAN.md Goals 2-5, ensure every existing `pub` item has a `///` doc comment. The codebase is mostly good here, but `BranchInfo`, `CommitInfo`, `PrInfo`, and `WorkspaceStatus` in `mcagent-gitbutler/src/types.rs` have none. `ToolInfo` and `ToolOutput` in `mcagent-wasi/src/runtime.rs` have none. Fix these before adding more undocumented types.

---

## Verdict

NACK. There are 23 style and consistency violations across the documents and codebase that need to be addressed. The foundation is strong — the code is clean, the architecture is sound, and the naming is *mostly* consistent. But "mostly consistent" is not consistent. I appreciate the thoughtful design and look forward to reviewing again once the naming conventions are unified and the import ordering is corrected.

The most critical items are:

1. **R1** — Establish and document a naming convention (prevents all future drift)
2. **R3** — Fix import ordering (three files, ten minutes)
3. **Item 18** — Reconcile PROJECT.md with reality (APFS reflink vs git worktree)
4. **Item 8** — Pick one MCP tool naming convention and apply it everywhere

Everything else can be addressed incrementally.

---

Signed-off-by: the-pedant@mcagent
