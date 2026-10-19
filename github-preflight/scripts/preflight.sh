#!/usr/bin/env bash
# github-preflight: read-only diagnosis of whether a repo is ready to push.
# Never mutates: only `git config --get`, ls-remote, ssh -T, push --dry-run.
# Usage: preflight.sh [repo-path] [remote-name]

REPO="${1:-.}"
REMOTE="${2:-origin}"

pass() { printf 'PASS  %-22s %s\n' "$1" "$2"; }
warn() { printf 'WARN  %-22s %s\n' "$1" "$2"; }
fail() { printf 'FAIL  %-22s %s\n' "$1" "$2"; }
info() { printf 'INFO  %-22s %s\n' "$1" "$2"; }

cd "$REPO" 2>/dev/null || { fail "path" "cannot cd to '$REPO'"; exit 1; }

# --- repo -------------------------------------------------------------------
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "repo" "not a git repository (run: git init)"
    exit 1
fi
TOP=$(git rev-parse --show-toplevel 2>/dev/null)
pass "repo" "$TOP"

# --- files / commits --------------------------------------------------------
TRACKED=$(git ls-files | wc -l)
UNTRACKED=$(git ls-files --others --exclude-standard | wc -l)
STAGED=$(git diff --cached --name-only 2>/dev/null | wc -l)

if git rev-parse HEAD >/dev/null 2>&1; then
    HAS_COMMITS=yes
    pass "commits" "$(git log -1 --format='%h %s' 2>/dev/null)"
    pass "author (last commit)" "$(git log -1 --format='%an <%ae>' 2>/dev/null)"
else
    HAS_COMMITS=no
    if [ "$TRACKED" -eq 0 ] && [ "$UNTRACKED" -eq 0 ] && [ "$STAGED" -eq 0 ]; then
        fail "commits" "no commits AND no files — nothing to push (add files first)"
    elif [ "$STAGED" -gt 0 ]; then
        warn "commits" "no commits yet; $STAGED file(s) staged — run: git commit -m 'Initial commit'"
    else
        warn "commits" "no commits yet; $UNTRACKED untracked file(s) — run: git add . && git commit -m 'Initial commit'"
    fi
fi
info "files" "tracked=$TRACKED staged=$STAGED untracked=$UNTRACKED"

# --- branch -----------------------------------------------------------------
BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null)
if [ -z "$BRANCH" ]; then
    warn "branch" "detached HEAD"
elif [ "$HAS_COMMITS" = no ]; then
    warn "branch" "'$BRANCH' (unborn — rename with 'git branch -M main' AFTER the first commit)"
else
    pass "branch" "$BRANCH"
fi

# --- remote -----------------------------------------------------------------
# Read the raw value straight from config: `git remote get-url` already expands
# insteadOf, so comparing it against ls-remote would never detect a rewrite.
RAW=$(git config --get "remote.$REMOTE.url" 2>/dev/null)
if [ -z "$RAW" ]; then
    fail "remote '$REMOTE'" "not configured (run: git remote add $REMOTE <url>)"
    exit 1
fi
# --push covers pushurl/pushInsteadOf, which is what a push preflight cares about.
EFFECTIVE=$(git remote get-url --push "$REMOTE" 2>/dev/null)
pass "remote '$REMOTE'" "$RAW"
if [ "$RAW" != "$EFFECTIVE" ]; then
    warn "url rewritten" "insteadOf rewrites it to: $EFFECTIVE"
    warn "" "git will contact the rewritten URL, not the one you configured"
fi

# --- parse host + owner from the EFFECTIVE url ------------------------------
HOST=""; OWNER=""; PROTO=""
case "$EFFECTIVE" in
    ssh://*)   PROTO=ssh;   r=${EFFECTIVE#ssh://}; r=${r#*@}; HOST=${r%%/*}; p=${r#*/}; OWNER=${p%%/*} ;;
    http://*|https://*)
               PROTO=https; r=${EFFECTIVE#*://}; r=${r#*@}; HOST=${r%%/*}; p=${r#*/}; OWNER=${p%%/*} ;;
    *:*)       PROTO=ssh;   r=${EFFECTIVE#*@}; HOST=${r%%:*}; p=${r#*:}; OWNER=${p%%/*} ;;
    *)         PROTO=local ;;
esac
[ -n "$OWNER" ] && info "url owner" "$OWNER (host: $HOST, protocol: $PROTO)"

# --- which account will authenticate ----------------------------------------
ACCOUNT=""
if [ "$PROTO" = ssh ]; then
    REALHOST=$(ssh -G "$HOST" 2>/dev/null | awk '/^hostname /{print $2; exit}')
    KEY=$(ssh -G "$HOST" 2>/dev/null | awk '/^identityfile /{print $2; exit}')
    [ -n "$REALHOST" ] && [ "$REALHOST" != "$HOST" ] && info "ssh alias" "$HOST -> $REALHOST (key: ${KEY:-default})"
    # GitHub answers "Hi <user>!" and exits 1 — exit 1 is the success case.
    GREETING=$(ssh -T -o BatchMode=yes -o ConnectTimeout=8 "git@$HOST" 2>&1)
    ACCOUNT=$(printf '%s' "$GREETING" | sed -n 's/^Hi \([^!]*\)!.*/\1/p')
    if [ -n "$ACCOUNT" ]; then
        pass "authenticates as" "$ACCOUNT (via ssh key ${KEY:-default})"
    else
        fail "authenticates as" "ssh auth failed: $(printf '%s' "$GREETING" | head -1)"
    fi
elif [ "$PROTO" = https ]; then
    # `gh api user` reports the account the credential helper will actually use;
    # parsing `gh auth status` would just pick the first of several logins.
    ACCOUNT=$(gh api user --jq .login 2>/dev/null)
    if [ -n "$ACCOUNT" ]; then
        pass "authenticates as" "$ACCOUNT (via gh credential helper)"
    else
        warn "authenticates as" "unknown — gh not logged in; git will prompt for credentials"
    fi
fi

if [ -n "$ACCOUNT" ] && [ -n "$OWNER" ] && [ "$ACCOUNT" != "$OWNER" ]; then
    warn "account vs owner" "pushing as '$ACCOUNT' to a repo owned by '$OWNER'"
    warn "" "fine if '$OWNER' is an org/collaborator repo; a 403 otherwise"
fi

# --- commit identity --------------------------------------------------------
NAME_LINE=$(git config --show-origin --get user.name  2>/dev/null)
MAIL_LINE=$(git config --show-origin --get user.email 2>/dev/null)
CFG_NAME=${NAME_LINE##*$'\t'}; CFG_MAIL=${MAIL_LINE##*$'\t'}
CFG_SRC=${MAIL_LINE%%$'\t'*}

if [ -z "$CFG_MAIL" ]; then
    fail "commit identity" "user.email not set — commits will fail or use a guessed address"
else
    case "$CFG_SRC" in
        *".git/config") pass "commit identity" "$CFG_NAME <$CFG_MAIL> (repo-local)" ;;
        *) warn "commit identity" "$CFG_NAME <$CFG_MAIL> (from ${CFG_SRC#file:})"
           warn "" "inherited, not set for this repo — commits may be authored under the wrong identity" ;;
    esac
fi

# --- remote state -----------------------------------------------------------
LS=$(git ls-remote "$REMOTE" 2>&1)
if [ $? -ne 0 ]; then
    fail "remote state" "cannot read remote: $(printf '%s' "$LS" | head -1)"
    fail "" "repo may not exist, or this account lacks access (GitHub reports both as 'not found')"
elif [ -z "$LS" ]; then
    pass "remote state" "empty — first push will be clean, no pull needed"
else
    warn "remote state" "$(printf '%s' "$LS" | wc -l) ref(s) already present"
    warn "" "a plain push may be rejected; pull/rebase first"
fi

# --- dry run ----------------------------------------------------------------
if [ "$HAS_COMMITS" = yes ] && [ -n "$BRANCH" ]; then
    DRY=$(git push --dry-run "$REMOTE" "$BRANCH" 2>&1)
    if [ $? -eq 0 ]; then
        pass "push --dry-run" "would succeed (server-side checks like GH007 not covered)"
    else
        fail "push --dry-run" "$(printf '%s' "$DRY" | tail -2 | tr '\n' ' ')"
    fi
else
    info "push --dry-run" "skipped — needs at least one commit on a named branch"
fi
