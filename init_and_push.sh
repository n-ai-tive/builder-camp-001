#!/usr/bin/env bash
#
# init_and_push.sh
# One-shot: initialize a local folder as a git repo and push it to GitHub.
#
# Usage:
#   1. Drop this script into your project folder.
#   2. Create a .env file alongside it containing:
#        GITHUB_TOKEN=ghp_your_token_here
#        GITHUB_USER=n-ai-tive
#        GITHUB_REPO=builder-camp-001
#      (GITHUB_USER + GITHUB_REPO can also be overridden via flags below.)
#   3. chmod +x init_and_push.sh
#   4. ./init_and_push.sh
#
# Optional flags:
#   -u <user>     GitHub user/org (overrides GITHUB_USER from .env)
#   -r <repo>     GitHub repo name (overrides GITHUB_REPO from .env)
#   -b <branch>   Branch name to push (default: main)
#   -m <message>  Commit message for the initial commit (default: "Initial commit")
#   -f            Force push with --force-with-lease (use if the remote was
#                 auto-initialized with a README and you want yours to win)
#

set -euo pipefail

BRANCH="main"
COMMIT_MSG="Initial commit"
FORCE=0
CLI_USER=""
CLI_REPO=""

while getopts ":u:r:b:m:f" opt; do
  case "$opt" in
    u) CLI_USER="$OPTARG" ;;
    r) CLI_REPO="$OPTARG" ;;
    b) BRANCH="$OPTARG" ;;
    m) COMMIT_MSG="$OPTARG" ;;
    f) FORCE=1 ;;
    \?) echo "Unknown option: -$OPTARG" >&2; exit 2 ;;
    :)  echo "Option -$OPTARG requires a value" >&2; exit 2 ;;
  esac
done

# --- Locate ourselves and move into the project dir ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
echo "==> Working directory: $SCRIPT_DIR"

# --- Sanity: git installed? ---
command -v git >/dev/null 2>&1 || { echo "ERROR: git is not installed or not on PATH." >&2; exit 1; }

# --- Load .env ---
if [[ ! -f .env ]]; then
  echo "ERROR: .env not found in $SCRIPT_DIR" >&2
  echo "Create one with:" >&2
  echo "  GITHUB_TOKEN=ghp_xxx" >&2
  echo "  GITHUB_USER=your-user-or-org" >&2
  echo "  GITHUB_REPO=your-repo-name" >&2
  exit 1
fi

# Tighten permissions on .env in case it was created with looser perms
chmod 600 .env || true

# Export everything sourced from .env
set -a
# shellcheck disable=SC1091
source .env
set +a

GITHUB_USER="${CLI_USER:-${GITHUB_USER:-}}"
GITHUB_REPO="${CLI_REPO:-${GITHUB_REPO:-}}"

if [[ -z "${GITHUB_TOKEN:-}" || -z "$GITHUB_USER" || -z "$GITHUB_REPO" ]]; then
  echo "ERROR: GITHUB_TOKEN, GITHUB_USER, and GITHUB_REPO must all be set" >&2
  echo "       (via .env or -u/-r flags)." >&2
  exit 1
fi

REMOTE_URL_PUBLIC="https://github.com/${GITHUB_USER}/${GITHUB_REPO}.git"
REMOTE_URL_AUTHED="https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${GITHUB_REPO}.git"

# --- Ensure .gitignore exists and contains .env ---
if [[ ! -f .gitignore ]]; then
  echo "==> Creating .gitignore"
  cat > .gitignore <<'EOF'
# Secrets
.env
.env.*
!.env.example

# Python
.venv/
venv/
__pycache__/
*.py[cod]
*.egg-info/
.pytest_cache/
.mypy_cache/
.ruff_cache/

# Node
node_modules/

# OS
.DS_Store
Thumbs.db

# Editors
.vscode/
.idea/
*.swp
EOF
else
  if ! grep -qxF ".env" .gitignore; then
    echo "==> Appending .env to existing .gitignore"
    printf '\n# Secrets\n.env\n' >> .gitignore
  fi
fi

# --- git init (idempotent) ---
if [[ ! -d .git ]]; then
  echo "==> git init -b $BRANCH"
  git init -b "$BRANCH" >/dev/null
else
  echo "==> .git already exists, skipping init"
  # Make sure we're on the requested branch
  CURRENT_BRANCH="$(git symbolic-ref --short HEAD 2>/dev/null || echo "")"
  if [[ -z "$CURRENT_BRANCH" ]]; then
    git checkout -b "$BRANCH" >/dev/null
  elif [[ "$CURRENT_BRANCH" != "$BRANCH" ]]; then
    echo "    Current branch is '$CURRENT_BRANCH', renaming to '$BRANCH'"
    git branch -m "$CURRENT_BRANCH" "$BRANCH"
  fi
fi

# --- Stage files and verify .env is excluded ---
echo "==> Staging files"
git add -A

if git ls-files --cached --error-unmatch .env >/dev/null 2>&1; then
  echo "ERROR: .env is staged for commit — aborting before secrets are committed." >&2
  echo "Run: git rm --cached .env  (and verify .gitignore contains .env)" >&2
  exit 1
fi

# --- Commit if there's anything to commit ---
if git diff --cached --quiet; then
  if ! git rev-parse HEAD >/dev/null 2>&1; then
    echo "ERROR: Nothing to commit and no existing commits. Add some files first." >&2
    exit 1
  fi
  echo "==> Nothing new to commit"
else
  # Set a local identity if the user hasn't configured one globally
  if ! git config user.email >/dev/null; then
    echo "==> No git user.email set; configuring a local one for this repo"
    git config user.email "${GIT_AUTHOR_EMAIL:-iamda6d@gmail.com}"
    git config user.name  "${GIT_AUTHOR_NAME:-$GITHUB_USER}"
  fi
  echo "==> Committing: \"$COMMIT_MSG\""
  git commit -m "$COMMIT_MSG" >/dev/null
fi

# --- Add or update the 'origin' remote (store WITHOUT the token) ---
if git remote get-url origin >/dev/null 2>&1; then
  CURRENT_REMOTE="$(git remote get-url origin)"
  if [[ "$CURRENT_REMOTE" != "$REMOTE_URL_PUBLIC" ]]; then
    echo "==> Updating origin: $CURRENT_REMOTE -> $REMOTE_URL_PUBLIC"
    git remote set-url origin "$REMOTE_URL_PUBLIC"
  else
    echo "==> origin already set to $REMOTE_URL_PUBLIC"
  fi
else
  echo "==> Adding origin: $REMOTE_URL_PUBLIC"
  git remote add origin "$REMOTE_URL_PUBLIC"
fi

# --- Push using the authenticated URL (token NOT stored in .git/config) ---
PUSH_ARGS=(-u)
if [[ "$FORCE" -eq 1 ]]; then
  PUSH_ARGS+=(--force-with-lease)
fi

echo "==> Pushing $BRANCH to GitHub"
# Use the public URL for tracking, but push via the token URL so credentials
# are never written to disk. The -u flag sets origin/$BRANCH as upstream.
git push "${PUSH_ARGS[@]}" "$REMOTE_URL_AUTHED" "$BRANCH:$BRANCH"

# After the first successful push, set upstream against the public 'origin'
git branch --set-upstream-to=origin/"$BRANCH" "$BRANCH" >/dev/null 2>&1 || true

echo ""
echo "Done. Repo is live at: https://github.com/${GITHUB_USER}/${GITHUB_REPO}"
echo "Future pushes: just run  git push"
