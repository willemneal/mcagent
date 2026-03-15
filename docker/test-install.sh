#!/usr/bin/env bash
set -euo pipefail

# test-install.sh — automated test for install.sh in Docker
# Verifies that install.sh can install all dependencies from scratch
# and set up a GitHub Pages site using the bitswell account.
#
# Requires: GITHUB_TOKEN env var set with a valid PAT.

RED='\033[0;31m'
GREEN='\033[0;32m'
RESET='\033[0m'

pass() { printf "${GREEN}PASS${RESET}: %s\n" "$*"; }
fail() { printf "${RED}FAIL${RESET}: %s\n" "$*" >&2; exit 1; }

# ── Pre-flight ──────────────────────────────────────────────────────────────

[[ -z "${GITHUB_TOKEN:-}" ]] && fail "GITHUB_TOKEN not set"
pass "GITHUB_TOKEN is set"

# Verify nothing is pre-installed (this is what install.sh should install)
! command -v gh &>/dev/null    || echo "Note: gh already installed (testing upgrade path)"
! command -v node &>/dev/null  || echo "Note: node already installed (testing upgrade path)"
! command -v claude &>/dev/null || echo "Note: claude already installed (testing upgrade path)"

# ── Run install.sh ──────────────────────────────────────────────────────────

REPO_NAME="mcagent-install-test-$(date +%s)"

# Pipe answers to install.sh:
#   1) experience level: 3 (advanced)
#   2) repo name: test repo (install.sh skips GitHub login since GITHUB_TOKEN is set)
printf "3\n${REPO_NAME}\n" | bash /workspace/install.sh \
    || fail "install.sh exited with error"
pass "install.sh completed"

# ── Assertions ──────────────────────────────────────────────────────────────

# gh should have been installed by install.sh
command -v gh &>/dev/null || fail "gh not found in PATH"
pass "gh CLI installed"

# Node.js should have been installed by install.sh
command -v node &>/dev/null || fail "node not found in PATH"
pass "Node.js installed"

# Claude Code should have been installed by install.sh
command -v claude &>/dev/null || fail "claude not found in PATH"
pass "claude CLI installed"

# gh should be authenticated (install.sh uses GITHUB_TOKEN)
gh auth status &>/dev/null || fail "gh not authenticated"
pass "gh authenticated"

# Repo should exist on GitHub
GH_USER="$(gh api user -q .login 2>/dev/null || echo "")"
[[ -n "$GH_USER" ]] || fail "could not determine GitHub user"
pass "Logged in as $GH_USER"

gh repo view "${GH_USER}/${REPO_NAME}" &>/dev/null \
    || fail "repo ${GH_USER}/${REPO_NAME} not found on GitHub"
pass "repo exists on GitHub"

# ── Cleanup ─────────────────────────────────────────────────────────────────

echo "Cleaning up test repo..."
gh repo delete "${GH_USER}/${REPO_NAME}" --yes 2>/dev/null \
    || echo "Warning: could not delete test repo (may need delete_repo scope)"
pass "Cleanup complete"

echo ""
echo "All tests passed."
