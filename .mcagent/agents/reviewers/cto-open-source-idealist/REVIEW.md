# Review: mcagent Project Vision, Plan, and Ideas

Signed-off-by: cto-open-source-idealist@mcagent

---

## Summary

I have read PROJECT.md (vision and architecture), PLAN.md (implementation roadmap), and IDEAS.md (future directions), and I have reviewed the current codebase across all six crates and the server binary. This review is written from the perspective of contributor experience: would a stranger be able to show up, understand what this project does, contribute meaningfully, and feel welcomed?

The short answer: the technical vision is genuinely exciting and the code is already in better shape than most projects at this stage, but there are significant gaps in documentation and contributor infrastructure that would prevent the project from building the community it needs.

---

## What Excites Me

### The problem is real and well-articulated

PROJECT.md does something rare: it explains *why* the project exists in plain language before diving into how it works. The two problems (file contention and no isolation) are immediately recognizable to anyone who has tried to run multiple AI agents on the same codebase. A new contributor reads this and instantly understands the motivation. That is good writing.

### The layered architecture is readable

The four-layer stack (WASI Sandbox, COW Filesystem, GitButler, MCP Server) is presented clearly. Each layer has a one-sentence explanation of what it does and why. The ASCII diagram in PROJECT.md is worth a thousand words. Someone reading this for the first time can build a mental model quickly, and that is the single most important quality of project documentation.

### The code is mostly boring (a compliment)

The core types in `mcagent-core/src/types.rs` are straightforward structs with derive macros. The `ExecutionBackend` trait in `execution.rs` is a clean abstraction with five well-named methods. The `CowLayer` implementation in `mcagent-cowfs/src/layer.rs` is linear and readable --- git worktree first, fallback to directory copy, no clever tricks. The `DockerBackend` in `mcagent-docker/src/backend.rs` follows the same pattern. A new contributor could read these files and understand the isolation model without asking anyone.

The budget system in `budget.rs` is particularly well done. The `check_budget` function iterates over dimensions, compares usage to limits, and returns the worst status. No magic. The tests cover the three main states (within, warning, exceeded). Boring is beautiful.

### The `ExecutionBackend` trait is the right abstraction

Defining `create_isolation`, `exec`, `diff`, `destroy` as a trait means new backends (Kubernetes, Firecracker, plain processes) can be added without touching the MCP server. This is exactly the kind of extensibility point that attracts contributors --- someone can show up and implement a new backend without understanding the entire system.

### WASI + Docker as a safety progression is honest

IDEAS.md acknowledges that Docker is "good enough" today and WASI components are the future. This is refreshing honesty. Too many projects promise WASI-only sandboxing when Docker is what actually works in production. The migration path (Docker now, WASI with Docker fallback, pure WASI later) is pragmatic and contributor-friendly --- people can contribute to the Docker backend today without worrying about WASI expertise.

---

## What Concerns Me

### There is no CONTRIBUTING.md

This is the single biggest gap. A project that aspires to have contributors but has no contribution guide is like a restaurant with no front door. I need to know:

- How do I set up the development environment?
- What are the prerequisites (Rust version, Docker, wasmtime, GitButler)?
- How do I run the tests?
- What is the commit message format?
- What is the PR process?
- What coding standards apply?
- How do I add a new MCP tool?
- How do I add a new execution backend?

Right now a potential contributor has to reverse-engineer all of this from the code.

### There is no CHANGELOG

The project already has at least three meaningful commits. When contributors consider joining a project, they look at the changelog to understand the pace and direction of development. When downstream users adopt the project, they need to know what changed between versions. Starting a changelog now, even if it is just a few lines, sets the expectation that every PR should include a changelog entry.

### The README is too thin

The README has a two-line description, a quick start section, and a tool list. For a project this ambitious, the README should be the first thing that makes someone say "I want to contribute to this." It needs:

- A one-paragraph elevator pitch (can be pulled from PROJECT.md)
- A "Why does this exist?" section
- A clear status indicator (alpha, experimental, not yet production-ready)
- Links to CONTRIBUTING.md, PLAN.md, and PROJECT.md
- A "Current limitations" section (this builds trust)
- A license section

### Most public functions lack doc comments with examples

Looking at the MCP tools in `mcagent-mcp/src/tools/mod.rs`, every tool function has a `#[tool(description = "...")]` annotation, which is great for the MCP protocol. But they have no Rust doc comments (`///`) with `# Examples` sections. A contributor reading the code needs both: the MCP description tells the LLM what the tool does, and the doc comment tells the human contributor.

The `ServerState` methods (`create_agent`, `destroy_agent`, `enforce_budget`) also lack `# Examples` and `# Errors` sections. These are the core lifecycle operations. A contributor implementing a new feature needs to know what errors `create_agent` can return and when.

Notable exceptions: `CowLayer::create` and `DockerBackend` have good doc comments. More of this, please.

### The `std::mem::forget(cow_layer)` in DockerBackend is a landmine

In `mcagent-docker/src/backend.rs` line 119:

```rust
std::mem::forget(cow_layer);
```

This is used to prevent the `CowLayer` from being dropped when the `DockerBackend::create_isolation` method returns. The comment says "prevent destroy-on-drop" but `CowLayer` does not implement `Drop`, so this `forget` is currently a no-op with a misleading comment. If someone later adds a `Drop` impl to `CowLayer`, this `forget` becomes load-bearing in a non-obvious way.

This is the kind of code that needs either a thorough comment explaining the intent and the assumption, or a redesign. Could we instead store the `CowLayer` inside the `IsolationHandle` (or alongside it) so its lifetime is explicitly managed?

Think about someone reading this for the first time. They see `std::mem::forget` and immediately wonder: is this a leak? Is it intentional? What breaks if I remove it?

### The `search_recursive` function is ad-hoc and outside any struct

In `tools/mod.rs` there is a standalone `search_recursive` function at the bottom of a 756-line file. It does naive string matching without regex support, silently ignores read errors on individual files (returns empty results rather than errors), and has no tests. A contributor looking for search functionality would not know this exists.

This should either be promoted to a proper utility in `mcagent-core` with tests and documentation, or replaced with a dependency like `grep` or `ignore` crate.

### `tools/mod.rs` is a 756-line monolith

All 17+ MCP tools are defined in a single file. Each tool follows the same pattern (read/write state, enforce budget, do work, return result), which is good for consistency. But 756 lines in one file makes it hard for a contributor to find the tool they want to modify. Consider splitting into modules by category: `tools/workspace.rs`, `tools/agent.rs`, `tools/filesystem.rs`, `tools/wasi.rs`, `tools/git.rs`, `tools/budget.rs`.

### PROJECT.md says "APFS reflink" but the code uses git worktrees

PROJECT.md explicitly says "Copy-on-Write filesystems --- Each agent gets an instant, isolated clone of the repo (via APFS reflink)" and the Technology section lists "APFS reflink --- Copy-on-write clones (macOS)". But the actual implementation in `mcagent-cowfs/src/layer.rs` uses `git worktree`, which is cross-platform.

This is a documentation-code mismatch that will confuse contributors. Someone on Linux reads PROJECT.md and thinks "this only works on macOS." The reality is better than the docs --- the code works everywhere. Update PROJECT.md to reflect the actual implementation.

### The PLAN.md mentions "all 17" MCP tools but Goal 2 and beyond are not implemented

PLAN.md lists five goals. Goal 1 (root agent definition) is partially done. Goal 2 (agent discovery and loading via `list_agent_templates` / `get_agent_template`) is not implemented. Goals 3-5 (built-in WASI tools, task orchestration, end-to-end integration) are not implemented.

This is fine for an early-stage project, but a contributor looking at PLAN.md has no way to know what is done and what is not. Add status markers:

```
## Goal 1: Root Agent Definition [IN PROGRESS]
## Goal 2: Agent Discovery & Loading [NOT STARTED]
```

### Error handling uses string parsing in agent ID lookup

In `server.rs` line 83-84:

```rust
.ok_or_else(|| McAgentError::AgentNotFound(agent_id.parse().unwrap()))
```

The `agent_id.parse().unwrap()` will never panic because `AgentId::from_str` returns `Infallible`, but a contributor seeing `.unwrap()` in error-handling code will worry. This is a case where the code is correct but not obviously correct. Consider a `AgentId::from_string(s)` constructor that makes the intent clear without the parse-unwrap dance.

---

## What is Missing

### A "Getting Started for Contributors" tutorial

Not just a CONTRIBUTING.md checklist, but a walkthrough: "Here is how to add a new MCP tool in 5 steps." The current codebase has a clear pattern for adding tools (define a param struct, add a `#[tool]` method, done), but nobody has written it down. This is the kind of documentation that turns a one-person project into a ten-person project.

### Integration tests

The codebase has unit tests for `CowLayer` and `Budget`, which is good. But there are no integration tests that start the MCP server, connect a client, and exercise the tool workflow. A contributor who changes the server has no way to verify they did not break the end-to-end flow without manually testing.

### CI configuration

No GitHub Actions workflow, no CI badges. A contributor submitting a PR has no automated feedback on whether their change compiles, passes tests, or is formatted correctly. This is a prerequisite for accepting external contributions.

### License clarity in source files

The project has a LICENSE file (good), but no license headers in source files. For a Rust project this is common, but for a project that wants contributors, adding a brief header or a note in CONTRIBUTING.md about the license terms for contributions (CLA? DCO? Inbound=outbound?) removes friction.

### A code of conduct

If you want contributors from 40 countries and different backgrounds, a CODE_OF_CONDUCT.md is not optional. It sets the tone for how people interact and gives maintainers a framework for handling conflicts.

### Cross-platform testing story

The `CowLayer` uses `git worktree` which works cross-platform, and falls back to directory copy for non-git repos. But there is no documentation about which platforms are tested or supported. The Cargo.toml still pulls in `reflink-copy` as a dependency even though the code does not appear to use it (it was presumably from the original APFS approach). Dead dependencies confuse contributors.

---

## Specific Recommendations

1. **Create CONTRIBUTING.md immediately.** Before anything else. Before new features. Before refactoring. The single highest-leverage action for this project is telling people how to contribute. Include: prerequisites, setup, testing, commit format, PR process, and a "your first contribution" section.

2. **Update PROJECT.md to match reality.** Replace APFS reflink references with git worktree. Add a "Current Status" section. Mark what works today and what is planned.

3. **Add status markers to PLAN.md.** Each goal should have a `[DONE]`, `[IN PROGRESS]`, or `[NOT STARTED]` tag. This tells contributors where help is needed.

4. **Split `tools/mod.rs` into per-category modules.** This makes it easier for a contributor to find and modify the tool they care about. The current 756 lines are manageable but will not stay that way as the tool count grows.

5. **Add `# Examples` to all public functions.** Start with the `ExecutionBackend` trait methods, `CowLayer::create`, `ServerState::create_agent`, and the budget functions. These are the entry points that contributors will interact with first.

6. **Remove the `reflink-copy` dependency** if it is no longer used. Dead dependencies are confusing and add compile time.

7. **Add a `CowLayer` architecture doc comment** at the module level in `mcagent-cowfs/src/layer.rs` explaining the git-worktree-first, directory-copy-fallback strategy. The code is clear, but a module-level doc that a contributor sees in `cargo doc` output makes it even clearer.

8. **Replace `std::mem::forget(cow_layer)` with explicit lifetime management.** Either store the `CowLayer` in the handle's backend data, or restructure so the `DockerBackend` owns its `CowLayer` instances in a map.

9. **Add GitHub Actions CI** with at minimum: `cargo build`, `cargo test`, `cargo clippy`, `cargo fmt --check`. This is table stakes for accepting contributions.

10. **Start a CHANGELOG.md.** Even a few lines for the current state. Set the convention early that every PR includes a changelog entry.

---

## Overall Assessment

This project has a compelling vision, a clean architecture, and working code that solves a real problem. The technical foundations are solid --- the `ExecutionBackend` trait, the `CowLayer` implementation, the budget system, and the MCP tool surface are all well-structured and readable.

What is missing is the contributor infrastructure. The code is ready for contributors, but the project is not. No CONTRIBUTING.md, no CI, no changelog, no code of conduct, outdated documentation, and a thin README mean that the first impression for a potential contributor is "this is someone's personal project" rather than "this is a community I want to join."

The good news is that these are all solvable problems, and they are easier to solve now, before the codebase gets larger. The hardest part --- writing clear, boring, understandable code --- is already done. Now the project needs to invite people in.

Thank you for this work. The functionality is strong and the vision is clear. I look forward to seeing the contributor experience catch up to the technical quality.

---

*Would a new contributor understand this project? Almost --- but they would need a front door.*
