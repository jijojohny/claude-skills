---
name: github-preflight
description: |
  Read-only preflight check of a repo's git/GitHub setup before pushing — especially
  the first push. Reports which GitHub account the push will authenticate as, which
  identity the commits will be authored with, whether the remote URL is being rewritten
  by insteadOf, and whether the branch and remote state will actually accept the push.
  Use this whenever the user says "check my github setup", "am I ready to push",
  "before first push", "which account will this push as", "did I set the remote right",
  "verify my remote", "wrong git account", "pushing as the wrong user", or hits
  "src refspec main does not match any", "Repository not found", "403", "GH007",
  "updates were rejected", or "Permission denied (publickey)". Also use it proactively
  before helping someone set up or push to a brand-new repository, and whenever a
  machine has more than one GitHub account or SSH host alias, since the failure mode
  there is silent — the push succeeds under the wrong identity.
---

# GitHub preflight

Pushing a new repo fails in a handful of boring, repeatable ways, and the error messages
point at the wrong thing. `src refspec main does not match any` sounds like a branch
problem but usually means there are no commits. A push that silently succeeds under a
work account looks identical to one that succeeded correctly. This skill finds those
before the user burns a push on them.

The guiding rule: **diagnose, don't mutate.** Report findings and hand back copy-paste
fix commands. The user runs them. People keep multiple accounts precisely because they
care which one acts, so quietly running `git config` or `git remote set-url` on their
behalf is exactly the wrong instinct here.

## Running it

```bash
bash <skill-dir>/scripts/preflight.sh [repo-path] [remote-name]
```

Both arguments are optional — they default to the current directory and `origin`. The
script only reads: `git config --get`, `ls-remote`, `ssh -T`, `push --dry-run`. It never
writes.

If the script can't run for some reason, the checks below are each a one-liner; run them
directly and interpret them the same way.

## What the checks mean

The script prints `PASS` / `WARN` / `FAIL` lines. Interpretation matters more than the
raw output, so translate rather than pasting:

**Repo / files / commits.** An empty directory or a repo with no commits produces
`src refspec <branch> does not match any` at push time. Git cannot build a commit from
nothing. This is the single most common cause of a failed first push, so lead with it
when it fires.

**Branch.** A fresh `git init` may land on `master` while the remote expects `main`.
Renaming is safe *after* the first commit (`git branch -M main`) — on an unborn branch
there's nothing to rename yet, which is why ordering the commands wrongly wastes a cycle.

**Effective remote URL.** Worth knowing precisely, because it's easy to check this wrong:
`git remote get-url` *already expands* `url.<base>.insteadOf`, as does
`git ls-remote --get-url`. Comparing those two therefore detects nothing. The raw value
only survives in `git config --get remote.<name>.url`, so that's what the script compares
against `git remote get-url --push` (the `--push` form additionally covers `pushurl` and
`pushInsteadOf`, which is what a push actually uses). When the two differ, the user's
configured URL is not the one git will contact. The classic trap is a global
`url."https://github.com/".insteadOf = git@github.com:`, which silently reroutes SSH to
HTTPS and therefore to whatever account the credential helper holds — often not the one
the user intended. Always report the effective URL, and flag the difference explicitly.

**Authenticating account.** For SSH, the script resolves the host through `ssh -G`
(so host aliases like `github-personal` are followed to their real hostname and key) and
then asks GitHub directly with `ssh -T`. GitHub answers `Hi <username>!` and exits 1 —
exit 1 is the success case here, not a failure. For HTTPS it reads the active `gh`
account. Compare that account against the owner segment of the URL: a mismatch means the
push will 403, or land in the wrong namespace.

**Commit identity.** `user.email` inherited from the global config is the quiet failure.
The push authenticates as one account while every commit is authored under another
address — and fixing it later means amending or rewriting history. Treat a global-scoped
identity on a repo whose remote belongs to a different owner as a WARN worth raising
prominently, even though nothing is technically broken yet.

**Remote state.** Empty remote means the first push is clean. Existing refs mean a plain
push will be rejected as non-fast-forward and the user needs to pull/rebase first — say
that *before* they hit the rejection. An error here usually means the repo doesn't exist
or the account lacks access; GitHub deliberately reports both as "not found", so offer
both explanations rather than guessing.

**Dry-run push.** Only possible once a commit exists. This is the real end-to-end check —
it exercises auth and ref negotiation without writing. Note its blind spot: it won't
catch server-side rejections like `GH007` (email privacy), because those are evaluated on
actual receipt.

## Reporting

Give a short table of checks, then — only for the things that failed or warned — the
exact commands to fix them, in runnable order. Don't dump passing checks as prose; the
user wants to know what's wrong and what to type.

When the identity needs setting, prefer repo-local config over touching the global one,
since the whole point is that this repo differs from the machine's default:

```bash
git config user.name  "<account>"
git config user.email "<email>"
```

If several repos need the same treatment, mention `includeIf` as the durable fix:

```gitconfig
[includeIf "gitdir:~/personal/"]
    path = ~/.gitconfig-personal
```

And if the push is rejected with `GH007`, point at the `@users.noreply.github.com`
address from GitHub → Settings → Emails rather than guessing at a personal address — key
comments and local config are labels, not proof of what the account accepts.
