#!/usr/bin/env bash
set -euo pipefail

# test-install.sh — automated test for install.sh in Docker
# Runs as bitswell user with GITHUB_TOKEN pre-configured

RED='\033[0;31m'
GREEN='\033[0;32m'
RESET='\033[0m'

pass() { printf "${GREEN}PASS${RESET}: %s\n" "$*"; }
fail() { printf "${RED}FAIL${RESET}: %s\n" "$*" >&2; exit 1; }

# ── Pre-flight ──────────────────────────────────────────────────────────────

if [[ -z "${GITHUB_TOKEN:-}" ]]; then
    fail "GITHUB_TOKEN not set"
fi

# Authenticate with GitHub CLI (non-interactive)
echo "$GITHUB_TOKEN" | gh auth login --with-token 2>/dev/null \
    || fail "gh auth login failed"
pass "GitHub CLI authenticated"

# Verify auth
gh auth status &>/dev/null || fail "gh auth status check failed"
pass "gh auth status OK"

GH_USER="$(gh api user -q .login)"
pass "Logged in as $GH_USER"

# Pre-configure git identity
git config --global user.name "$GH_USER"
git config --global user.email "${GH_USER}@users.noreply.github.com"
pass "Git identity configured"

# ── Run install.sh ──────────────────────────────────────────────────────────

REPO_NAME="mcagent-install-test-$(date +%s)"

# Pipe answers to install.sh:
# - experience level: 3 (advanced)
# - already has GitHub account: yes (but already authed, so skipped)
# - repo name: the test repo name
printf "3\n${REPO_NAME}\n" | bash /workspace/install.sh \
    || fail "install.sh exited with error"
pass "install.sh completed"

# ── Assertions ──────────────────────────────────────────────────────────────

# Claude Code should be installed
command -v claude &>/dev/null || fail "claude not found in PATH"
pass "claude CLI installed"

# gh should still be authenticated
gh auth status &>/dev/null || fail "gh lost authentication"
pass "gh still authenticated"

# Repo should exist on GitHub
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
