#!/usr/bin/env bash
set -euo pipefail

# test-deploy.sh — end-to-end test of install.sh's full flow
#
# Runs install.sh from scratch in Docker, then verifies:
#   1. All dependencies installed (gh, node, claude)
#   2. GitHub repo was created
#   3. GitHub Pages site is actually live and serving correct content
#   4. Cleans up the repo afterwards
#
# Requires: GITHUB_TOKEN env var set with a valid PAT.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RESET='\033[0m'

pass() { printf "${GREEN}PASS${RESET}: %s\n" "$*"; }
fail() { printf "${RED}FAIL${RESET}: %s\n" "$*" >&2; FAILED=1; }
info() { printf "${YELLOW} .. ${RESET} %s\n" "$*"; }

FAILED=0
REPO_NAME=""
GH_USER=""

cleanup() {
    if [[ -n "$REPO_NAME" && -n "$GH_USER" ]]; then
        echo ""
        info "Cleaning up..."
        gh api --method DELETE "repos/${GH_USER}/${REPO_NAME}/pages" 2>/dev/null || true
        gh repo delete "${GH_USER}/${REPO_NAME}" --yes 2>/dev/null \
            && pass "Deleted repo ${GH_USER}/${REPO_NAME}" \
            || echo "Warning: could not delete repo (may need delete_repo scope)"
    fi
    if [[ "$FAILED" -ne 0 ]]; then
        echo ""
        echo "Some tests failed."
        exit 1
    fi
}
trap cleanup EXIT

# ── Pre-flight ──────────────────────────────────────────────────────────────

[[ -z "${GITHUB_TOKEN:-}" ]] && { fail "GITHUB_TOKEN not set"; exit 1; }
pass "GITHUB_TOKEN is set"

# ── Run install.sh ──────────────────────────────────────────────────────────

REPO_NAME="deploy-test-$(date +%s)"

# Pipe answers:
#   1) experience: 3 (advanced)
#   2) repo name: our test repo
printf "3\n${REPO_NAME}\n" | bash /workspace/install.sh \
    || { fail "install.sh exited with error"; exit 1; }
pass "install.sh completed"

# ── Verify dependencies installed ──────────────────────────────────────────

command -v gh &>/dev/null    || fail "gh not found in PATH"
command -v node &>/dev/null  || fail "node not found in PATH"
command -v claude &>/dev/null || fail "claude not found in PATH"
pass "All dependencies installed (gh, node, claude)"

# ── Verify GitHub state ────────────────────────────────────────────────────

gh auth status &>/dev/null || { fail "gh not authenticated"; exit 1; }

GH_USER="$(gh api user -q .login 2>/dev/null)"
[[ -n "$GH_USER" ]] || { fail "Could not determine GitHub user"; exit 1; }
pass "Authenticated as $GH_USER"

gh repo view "${GH_USER}/${REPO_NAME}" &>/dev/null \
    || { fail "Repo ${GH_USER}/${REPO_NAME} not found"; exit 1; }
pass "Repo exists on GitHub"

REPO_VISIBILITY="$(gh repo view "${GH_USER}/${REPO_NAME}" --json visibility -q '.visibility' 2>/dev/null)"
if [[ "$REPO_VISIBILITY" == "PUBLIC" ]]; then
    pass "Repo is public"
else
    fail "Expected public repo, got: $REPO_VISIBILITY"
fi

# ── Wait for GitHub Pages deployment ───────────────────────────────────────

SITE_URL="https://${GH_USER}.github.io/${REPO_NAME}/"
info "Waiting for site to go live at: $SITE_URL"

MAX_ATTEMPTS=30
DELAY=10
DEPLOYED=false

for i in $(seq 1 $MAX_ATTEMPTS); do
    HTTP_CODE="$(curl -s -o /dev/null -w '%{http_code}' "$SITE_URL" 2>/dev/null || echo "000")"

    if [[ "$HTTP_CODE" == "200" ]]; then
        DEPLOYED=true
        break
    fi

    info "Attempt $i/$MAX_ATTEMPTS — HTTP $HTTP_CODE (waiting ${DELAY}s)"
    sleep "$DELAY"
done

if [[ "$DEPLOYED" != "true" ]]; then
    fail "Site not live after $((MAX_ATTEMPTS * DELAY))s"
else
    pass "Site is live (HTTP 200)"
fi

# ── Verify deployed content ────────────────────────────────────────────────

if [[ "$DEPLOYED" == "true" ]]; then
    BODY="$(curl -s "$SITE_URL")"

    if echo "$BODY" | grep -q "Hello, World!"; then
        pass "Site content verified — 'Hello, World!' found"
    else
        fail "'Hello, World!' not found in deployed site"
        echo "First 10 lines of response:"
        echo "$BODY" | head -10
    fi

    if echo "$BODY" | grep -q "Built with Claude Code"; then
        pass "Badge text found — 'Built with Claude Code'"
    else
        fail "'Built with Claude Code' badge not found"
    fi
fi

# ── Verify Pages API status ────────────────────────────────────────────────

PAGES_STATUS="$(gh api "repos/${GH_USER}/${REPO_NAME}/pages" -q '.status' 2>/dev/null || echo "unknown")"
if [[ "$PAGES_STATUS" == "built" ]]; then
    pass "GitHub Pages API status: built"
else
    info "GitHub Pages API status: $PAGES_STATUS"
fi

# ── Summary ─────────────────────────────────────────────────────────────────

echo ""
if [[ "$FAILED" -eq 0 ]]; then
    echo "All deploy tests passed."
else
    echo "Some deploy tests failed."
fi

# Cleanup happens in trap
