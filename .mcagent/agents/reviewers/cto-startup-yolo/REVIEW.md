# Review: mcagent — PROJECT.md, PLAN.md, IDEAS.md

**Verdict: LGTM with notes. Ship it.**

---

## What Excites Me

This solves a real problem I hit every week. Right now my 2 other engineers and I
are literally waiting on each other because our AI agents trash each other's working
tree. COW clones + per-agent branches is the obvious correct answer and I am genuinely
surprised nobody shipped this yet.

The GitButler integration is the killer feature. Stacked PRs in dependency order means
I can review 5 small PRs instead of one 800-line monster. That alone would save me
hours per week — hours I do not have.

LLM-agnostic via MCP is smart. We are not married to Claude or GPT. When the next
model drops and it is 3x cheaper, we just swap it in. No vendor lock-in. Good.

The WASI sandbox story is exactly right for where we are. Docker now, WASI later. Do
not over-invest in the perfect sandbox when Docker gets us 90% of the way. I have seen
too many projects die trying to build the perfect security model before they had users.

## What Concerns Me

**APFS-only COW is a hard platform lock.** Your entire Layer 2 depends on macOS. I get
it — APFS reflink is elegant and fast. But if even one of my engineers is on Linux
(spoiler: they are), this does not work for them. The PROJECT.md does not mention a
fallback. `cp -r` is slow but it works everywhere. Ship APFS support first, but have a
`cp -r` fallback from day one or you cut your addressable market in half.

**The PLAN.md has 5 goals but no timeline.** I need to know what I get in week 1 vs
week 6. Goals 1-2 (agent definition + discovery) are table stakes — those should land
first and fast. Goal 5 (end-to-end orchestration) is the demo-worthy feature. What is
the critical path? If I am demoing this to a Series A lead, what is the minimum set of
goals that gives me a working demo?

**IDEAS.md is a feature graveyard waiting to happen.** I love the ambition — agent
memory, reputation tracking, cross-repo orchestration, budget tracking. But that is 6+
months of work for a team of 3. My concern is not that these are bad ideas. My concern
is that someone starts building OpenViking Memory before the basic workflow is solid.
Suggestion: put a giant "DO NOT BUILD YET" header on IDEAS.md and only graduate items
to PLAN.md when the core loop (spawn agent → isolated work → commit → PR) is
rock-solid.

**No mention of error recovery in the plan.** What happens when an agent's COW layer
gets corrupted? What happens when GitButler fails to commit? What happens when the WASI
tool panics? The PLAN.md talks about conflict detection but not about the basic failure
modes. This is not a blocker — we can add error handling iteratively — but I want to
see at least a "when things go wrong, we log it and the user retries" fallback in the
first version.

## What's Missing

**A 10-minute getting-started path.** I should be able to `cargo install mcagent`,
run one command, and see an agent do something useful. The PLAN.md jumps straight to
agent definitions and WASI tools. Where is Goal 0: "user runs mcagent and it works on
a simple task"?

**Metrics on the COW approach.** How fast is `clonefile` on a 10k-file repo? 100k? How
much disk does 5 concurrent COW clones actually use? I believe it is fast but I want
numbers before I bet my startup on it.

**Multi-platform story.** Already mentioned APFS, but also: the WASI toolchain assumes
Rust. What about TypeScript/Python projects? The built-in tools in Goal 3 are all
`cargo check` and `cargo test`. Most startups are not writing Rust. We need at least
`npm test` and `pytest` equivalents or this is a Rust-only tool with a small market.

**Conflict resolution strategy.** The plan mentions "conflict detection when COW layers
overlap on the same files" but not what happens next. Does the orchestrator pick a
winner? Does it ask the user? Does it try to merge? This will matter as soon as two
agents touch the same file, which will happen constantly in real projects.

## Specific Recommendations

1. **Ship Goal 1 + Goal 2 this week.** Agent definitions and discovery are pure
   markdown and MCP plumbing. No hard infrastructure. Get this working so people can
   start defining agents and see them listed.

2. **Add a `--backend=copy` fallback for Linux immediately.** Even if it is slow, it
   unblocks Linux users and proves the abstraction layer works. One `trait IsolationBackend`
   with two impls. Simple.

3. **Move IDEAS.md items to a backlog, not the plan.** Treat IDEAS.md as a "maybe
   someday" list. The plan should only contain what you are building in the next 4-6
   weeks.

4. **Add a Goal 0 to the plan: "Hello World" demo.** Single command, single agent,
   single task, visible output. This is your onboarding funnel and your demo script.
   Everything else is invisible infrastructure until this works.

5. **Do not build the WASI tools (Goal 3) until the orchestration loop works.** Shell
   out to `cargo test` directly. WASI compilation adds complexity you do not need yet.
   Wrap it later. The abstraction boundary is clean enough that swapping shell-exec for
   WASI-exec is a refactor, not a rewrite.

6. **Pick one non-Rust language for the built-in tools.** Add `npm test` or `python -m
   pytest` support. This triples your potential user base overnight.

---

Ship the core loop first. Everything else is a nice-to-have until spawn → isolate →
work → commit → PR works end to end. You are building the right thing. Do not let the
IDEAS.md distract you from shipping it.

LGTM, let's go.

Signed-off-by: cto-startup-yolo@mcagent
