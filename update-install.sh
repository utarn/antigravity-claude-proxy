#!/usr/bin/env bash
#
# update-install.sh — apply upstream PRs, rebuild, and install globally.
#
# Replaces the globally-installed upstream antigravity-claude-proxy (the one
# root installed under /usr/lib/node_modules) with this fork's build, and also
# refreshes the user-level nvm global install if present.
#
# Usage:
#   ./update-install.sh              # apply PRs + rebuild + global install
#   ./update-install.sh --restart    # also restart a running root-owned proxy
#   ./update-install.sh --no-prs     # skip the PR application step
#   ./update-install.sh --no-install # apply PRs + rebuild only
#
# Requires: git, npm, passwordless sudo for the /usr (root) install.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

UPSTREAM="${UPSTREAM:-https://github.com/badrisnarayanan/antigravity-claude-proxy}"
SYSTEM_NPM="/usr/bin/npm"   # system (root-installed) node toolchain
SYSLOG="/var/log/antigravity-proxy.log"

DO_PRS=1
DO_INSTALL=1
DO_RESTART=0
for arg in "$@"; do
    case "$arg" in
        --no-prs)     DO_PRS=0 ;;
        --no-install) DO_INSTALL=0 ;;
        --restart)    DO_RESTART=1 ;;
        *) echo "Unknown flag: $arg" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ----------------------------------------------------------------------------
# Step 1: apply upstream PRs 310, 376, 378 (idempotent — skips if in history)
# ----------------------------------------------------------------------------
apply_prs() {
    git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM"
    git fetch -q upstream main
    for n in 310 376 378; do
        git fetch -q upstream "pull/$n/head:refs/remotes/upstream/pr-$n" 2>/dev/null \
            || warn "could not fetch pull/$n/head"
    done

    local dirty=0
    git diff-index --quiet HEAD -- || dirty=1
    [ "$dirty" = 1 ] && die "working tree has uncommitted changes; commit or stash first"

    # PR 310 — big web-search PR (merge commits; apply as net diff vs merge base)
    # NOTE: use git log --grep (not `git log | grep -q`) — with pipefail, grep -q
    # closing the pipe early makes git log die on SIGPIPE and the check fail.
    if [ -z "$(git log -1 --format=%H --grep='PR 310')" ]; then
        log "Applying PR 310 (web search grounding + MCP server)"
        local base
        base="$(git merge-base HEAD upstream/pr-310)"
        git diff "$base..upstream/pr-310" | git apply -3 \
            || die "PR 310 patch conflicted — resolve manually, commit as 'Merge PR 310: ...', re-run"
        git add -A
        git commit -q -m "Merge PR 310: add Google Search grounding support and web search MCP server

Co-Authored-By: Claude Code <noreply@anthropic.com>"
    else
        log "PR 310 already applied — skipping"
    fi

    # PR 376 / 378 — single-commit fixes, cherry-pick directly
    for pair in "376:#375" "378:#377"; do
        local n="${pair%%:*}" fixes="${pair##*:}"
        if [ -z "$(git log -1 --format=%H --grep="$fixes")" ]; then
            log "Applying PR $n"
            git cherry-pick "upstream/pr-$n" \
                || die "PR $n cherry-pick conflicted — resolve, git cherry-pick --continue, re-run"
        else
            log "PR $n already applied — skipping"
        fi
    done
}

# ----------------------------------------------------------------------------
# Step 2: rebuild (install deps + compile CSS + standalone tests)
# ----------------------------------------------------------------------------
rebuild() {
    log "Installing dependencies (prepare hook compiles CSS)"
    npm install --no-fund --no-audit

    log "Compiling CSS"
    npm run build:css --silent

    log "Running strategy unit tests (no server needed)"
    node tests/test-strategies.cjs >/dev/null \
        || die "unit tests failed — fix before installing"

    log "Smoke-checking entry module"
    node --input-type=module -e "import('$REPO_DIR/src/index.js').catch(e=>{console.error(e.message);process.exit(1)})" >/dev/null 2>&1 \
        || warn "entry module import reported an error (may just be port 8080 in use)"
}

# ----------------------------------------------------------------------------
# Step 3: global install (tarball, both prefixes)
# ----------------------------------------------------------------------------
install_global() {
    log "Packing release tarball"
    local tarball
    tarball="$(npm pack --silent | tail -1)"
    trap 'rm -f "$REPO_DIR/$tarball"' RETURN

    # 3a. user-level nvm install (if the nvm npm is on PATH)
    if command -v npm >/dev/null && [[ "$(npm prefix -g)" != "/usr" ]]; then
        log "Installing to user npm prefix ($(npm prefix -g))"
        npm install -g --no-fund --no-audit "$tarball" \
            || warn "user-level global install failed"
    fi

    # 3b. root-level system install (replaces the upstream install)
    [ -x "$SYSTEM_NPM" ] || die "system npm not found at $SYSTEM_NPM"
    local sys_prefix
    sys_prefix="$(sudo "$SYSTEM_NPM" prefix -g)"
    log "Replacing global install in $sys_prefix (root-owned)"
    sudo "$SYSTEM_NPM" install -g --no-fund --no-audit "$tarball" \
        || die "system global install failed"

    log "Installed version: $(node -p "require('$sys_prefix/lib/node_modules/antigravity-claude-proxy/package.json').version")"
}

# ----------------------------------------------------------------------------
# Step 4: optionally restart the running root-owned proxy
# ----------------------------------------------------------------------------
restart_proxy() {
    local pids
    pids="$(pgrep -f '/usr/lib/node_modules/antigravity-claude-proxy/src/index.js' || true)"
    if [ -z "$pids" ]; then
        log "No running root proxy found — nothing to restart"
        return
    fi
    warn "Restarting root-owned proxy process(es): $pids"
    sudo pkill -f '/usr/lib/node_modules/antigravity-claude-proxy/src/index.js' || true
    sleep 1
    sudo bash -c "nohup /usr/bin/node /usr/lib/node_modules/antigravity-claude-proxy/src/index.js >'$SYSLOG' 2>&1 &"
    sleep 2
    pgrep -f '/usr/lib/node_modules/antigravity-claude-proxy/src/index.js' >/dev/null \
        && log "Proxy restarted (logs: $SYSLOG)" \
        || die "proxy did not come back up — check $SYSLOG"
}

[ "$DO_PRS" = 1 ]     && apply_prs
rebuild
[ "$DO_INSTALL" = 1 ] && install_global

if [ "$DO_RESTART" = 1 ]; then
    restart_proxy
else
    pids="$(pgrep -f '/usr/lib/node_modules/antigravity-claude-proxy/src/index.js' || true)"
    [ -n "$pids" ] && warn "Root proxy is still running old code (pid $pids). Re-run with --restart or restart it yourself."
fi

log "Done."
