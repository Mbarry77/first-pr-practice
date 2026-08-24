#!/usr/bin/env bash
#
# One-shot GitHub setup for a new machine (Linux, macOS, WSL, Git Bash).
#
#   ./setup.sh            install tools, sign in, clone every repo, print report
#   ./setup.sh --test     skip install/clone, just print the machine report
#
# Clone location: $GITHUB_DIR, or ~/github by default.

set -euo pipefail

GITHUB_DIR="${GITHUB_DIR:-$HOME/github}"
TEST_ONLY=false
[ "${1:-}" = "--test" ] && TEST_ONLY=true

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[0;32m[ok]\033[0m %s\n' "$*"; }
warn() { printf '    \033[0;33m[!!]\033[0m %s\n' "$*"; }
die()  { printf '\n\033[0;31m[xx] %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- detect host

case "$(uname -s)" in
  Linux*)   OS=linux ;;
  Darwin*)  OS=macos ;;
  MINGW*|MSYS*|CYGWIN*) OS=windows-bash ;;
  *) die "Unsupported OS: $(uname -s). On Windows PowerShell, run setup.ps1 instead." ;;
esac

# Homebrew installs somewhere different on Apple Silicon vs Intel, and neither is
# on PATH until 'brew shellenv' has been evaluated - which a fresh Terminal that
# has never opened a login shell may not have done yet. Look in both places.
find_homebrew() {
  command -v brew >/dev/null 2>&1 && return 0
  local candidate
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [ -x "$candidate" ]; then
      eval "$("$candidate" shellenv)"
      return 0
    fi
  done
  return 1
}

[ "$OS" = macos ] && find_homebrew || true

# On macOS the answer is Homebrew or nothing - never fall through to a Linux
# package manager that happens to be present.
if [ "$OS" = macos ]; then
  if command -v brew >/dev/null 2>&1; then PKG=brew; else PKG=none; fi
elif command -v apt-get >/dev/null 2>&1; then PKG=apt
elif command -v dnf     >/dev/null 2>&1; then PKG=dnf
elif command -v pacman  >/dev/null 2>&1; then PKG=pacman
elif command -v brew    >/dev/null 2>&1; then PKG=brew
else PKG=none
fi

# A Mac with no Homebrew can't install gh. Installing Homebrew is a big change to
# someone's machine and it prompts for a password, so tell them how rather than
# doing it behind their back.
# (Not in --test mode: that exists to report state, missing tools included.)
if [ "$OS" = macos ] && [ "$PKG" = none ] && [ "$TEST_ONLY" = false ]; then
  cat <<'EOM'

Homebrew is not installed, and it is what installs the GitHub CLI on macOS.

Install it by running this, then re-run this script:

  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

It will ask for your Mac password. When it finishes it prints two 'eval' lines
to add Homebrew to your PATH - run those too, or just open a new Terminal.

EOM
  exit 1
fi

# --------------------------------------------------------------- install deps

install_git() {
  command -v git >/dev/null 2>&1 && { ok "git $(git --version | awk '{print $3}')"; return; }
  say "Installing git"
  case "$PKG" in
    brew)   brew install git ;;
    apt)    sudo apt-get update && sudo apt-get install -y git ;;
    dnf)    sudo dnf install -y git ;;
    pacman) sudo pacman -S --noconfirm git ;;
    *)      die "No supported package manager found. Install git from https://git-scm.com/downloads" ;;
  esac
}

install_gh() {
  command -v gh >/dev/null 2>&1 && { ok "gh $(gh --version | head -1 | awk '{print $3}')"; return; }
  say "Installing the GitHub CLI (gh)"
  case "$PKG" in
    brew)   brew install gh ;;
    dnf)    sudo dnf install -y gh ;;
    pacman) sudo pacman -S --noconfirm github-cli ;;
    apt)
      sudo mkdir -p -m 755 /etc/apt/keyrings
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
      sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
      sudo apt-get update && sudo apt-get install -y gh
      ;;
    *) die "No supported package manager found. Install gh from https://cli.github.com" ;;
  esac
}

# ------------------------------------------------------------------ sign in

sign_in() {
  if gh auth status >/dev/null 2>&1; then
    ok "already signed in as $(gh api user -q .login)"
  else
    say "Signing in to GitHub"
    echo "    A browser window will open. Pick: GitHub.com -> HTTPS -> login with a browser."
    gh auth login --hostname github.com --git-protocol https --web
  fi
  gh auth setup-git   # makes git push/pull use your gh credentials, no password prompts
}

configure_git() {
  say "Configuring git identity"
  local login name email
  login=$(gh api user -q .login)
  name=$(gh api user -q '.name // ""')
  [ -n "$name" ] || name="$login"
  email=$(gh api user/emails -q '[.[] | select(.primary)][0].email' 2>/dev/null || true)
  [ -n "$email" ] || email="$(gh api user -q .id)+$login@users.noreply.github.com"

  git config --global user.name  "$name"
  git config --global user.email "$email"
  git config --global init.defaultBranch main
  git config --global pull.ff only
  ok "$name <$email>"
}

# -------------------------------------------------------------- clone repos

clone_all() {
  say "Cloning every repo you can see into $GITHUB_DIR"
  mkdir -p "$GITHUB_DIR"

  local repos
  repos=$(gh repo list --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner')
  [ -n "$repos" ] || { warn "no repos found on this account"; return; }

  local total=0 cloned=0 updated=0 skipped=0
  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    total=$((total + 1))
    local dir="$GITHUB_DIR/${repo##*/}"
    if [ -d "$dir/.git" ]; then
      if [ -n "$(git -C "$dir" status --porcelain)" ]; then
        warn "${repo} has local changes - fetching only"
        git -C "$dir" fetch --all --quiet && skipped=$((skipped + 1))
      else
        git -C "$dir" pull --ff-only --quiet && updated=$((updated + 1)) || warn "could not fast-forward $repo"
      fi
    else
      gh repo clone "$repo" "$dir" -- --quiet && cloned=$((cloned + 1)) || warn "could not clone $repo"
    fi
  done <<< "$repos"

  ok "$total repos: $cloned cloned, $updated updated, $skipped left alone (uncommitted work)"
}

# ------------------------------------------------------------------- report

report() {
  local repo_count=0
  [ -d "$GITHUB_DIR" ] && repo_count=$(find "$GITHUB_DIR" -maxdepth 2 -name .git -type d 2>/dev/null | wc -l | tr -d ' ')

  say "MACHINE REPORT  --  run this on both computers and compare"
  cat <<EOF
    machine   : $(hostname)
    os        : $OS ($(uname -sr))
    user      : $(whoami)
    git       : $(command -v git >/dev/null 2>&1 && git --version || echo 'NOT INSTALLED')
    gh        : $(command -v gh  >/dev/null 2>&1 && gh --version | head -1 || echo 'NOT INSTALLED')
    signed in : $(gh auth status >/dev/null 2>&1 && gh api user -q .login || echo 'NO')
    git name  : $(git config --global user.name  || echo 'unset')
    git email : $(git config --global user.email || echo 'unset')
    repo dir  : $GITHUB_DIR
    repos     : $repo_count cloned locally
EOF

  say "Push test (proves this machine can actually write to GitHub)"
  echo "    cd $GITHUB_DIR/first-pr-practice"
  echo "    MACHINE=\$(hostname -s | tr -cd '[:alnum:]-')"
  echo "    git checkout -b hello-from-\$MACHINE"
  echo "    echo \"checked in from \$MACHINE\" >> setup/machines.txt"
  echo "    git commit -am \"Say hello from \$MACHINE\" && git push -u origin HEAD"
  echo "    gh pr create --fill --draft"
  echo
  echo "    Both computers pass when both can open a PR that way."
}

# --------------------------------------------------------------------- main

if [ "$TEST_ONLY" = false ]; then
  install_git
  install_gh
  sign_in
  configure_git
  clone_all
fi
report
