# Set up GitHub on a new computer

Gets a machine from "nothing installed" to "every repo cloned, and I can push."

Two scripts, same job:

| Script | For |
| --- | --- |
| `setup.ps1` | Windows (PowerShell) — this is the one for **ALPHAX**, the Alienware Area-51 |
| `setup.sh` | macOS, Linux, WSL, or Git Bash — for the second computer |

Both are safe to re-run. Nothing is overwritten: a repo you already have is
fast-forwarded, and one with uncommitted work is left alone.

---

## Windows (ALPHAX / Alienware Area-51)

Open **PowerShell** from the Start menu. Two blocks, in order.

### Step 1 — install the tools, then make this window see them

```powershell
winget install --id Git.Git    -e --source winget --accept-package-agreements --accept-source-agreements
winget install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
$env:Path += ";$env:ProgramFiles\Git\cmd;$env:ProgramFiles\GitHub CLI"
git --version; gh --version
```

That last pair of commands must print two version numbers. If either says
*"not recognized"*, stop — step 2 cannot work. See
[Troubleshooting](#troubleshooting) below.

The `$env:Path` line matters: `winget` adds tools to the PATH of *future*
PowerShell windows only, so without it the window you just installed from still
can't find `git` or `gh`. Adding the install directories by hand fixes that
without closing anything. (Opening a fresh window works too.)

### Step 2 — sign in and run the setup

```powershell
gh auth login --hostname github.com --git-protocol https --web
gh repo clone Mbarry77/first-pr-practice "$HOME\github\first-pr-practice"
cd "$HOME\github\first-pr-practice"
powershell -ExecutionPolicy Bypass -File .\setup\setup.ps1
```

At sign-in, choose **GitHub.com → HTTPS → login with a browser** and paste the
one-time code it shows you.

That's it. Everything you can see on GitHub ends up in `C:\Users\matth\github\`.

<a name="troubleshooting"></a>
### Troubleshooting

**`The term 'gh' is not recognized`** — step 1 didn't finish, or this window
predates the install. Re-run the `$env:Path += ...` line from step 1, then
`gh --version`. Still failing? Check whether it landed anywhere at all:

```powershell
Test-Path "$env:ProgramFiles\GitHub CLI\gh.exe"
```

`True` means it's installed and only the PATH is wrong — call it by full path:
`& "$env:ProgramFiles\GitHub CLI\gh.exe" --version`. `False` means the winget
install genuinely failed; re-run it and read its output.

**`winget` is not recognized** — it ships with Windows 11 as *App Installer*.
Update it from the Microsoft Store, or install git and gh by hand from
[git-scm.com](https://git-scm.com/downloads) and [cli.github.com](https://cli.github.com).

**`cannot be loaded because running scripts is disabled`** — you left off
`-ExecutionPolicy Bypass`. Use the full command as written in step 2.

### A note specific to this machine

Your System Information shows **App Control for Business: Enforced**. Two
consequences, both already handled:

- PowerShell may run in *Constrained Language Mode*. The script detects this,
  prints a warning, and avoids the .NET calls that mode blocks.
- Scripts won't run under the default execution policy, which is why step 2
  uses `-ExecutionPolicy Bypass` for that single command. It does not change
  any setting on the machine.

If `winget` itself is blocked by policy, install the two tools by hand from
[git-scm.com](https://git-scm.com/downloads) and [cli.github.com](https://cli.github.com),
then pick up at step 2 (the `$env:Path` line from step 1 first, if `gh` isn't
found).

---

## The second computer — the Mac

Open **Terminal** (Command-Space, type "Terminal"). Run these one at a time.

### Step 1 — Homebrew

Homebrew is what installs the GitHub CLI on macOS. Check whether you already
have it:

```bash
brew --version
```

If that prints a version, skip to step 2. If it says `command not found`:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

It asks for your Mac login password (the prompt stays blank as you type — that's
normal). When it finishes it prints two `eval` lines under "Next steps" — run
those, or just open a new Terminal window, otherwise `brew` won't be found.

### Step 2 — clone the repo and run the setup

```bash
git clone https://github.com/Mbarry77/first-pr-practice.git ~/github/first-pr-practice
cd ~/github/first-pr-practice
bash setup/setup.sh
```

On a Mac that has never had developer tools, that first `git` command pops up a
dialog offering to install the Xcode Command Line Tools. Click **Install**, wait
for it, then run the command again.

The script installs the GitHub CLI, signs you in (**GitHub.com → HTTPS → login
with a browser**), and clones everything into `~/github/`.

### Other Unix-likes

The same `setup.sh` covers Linux and WSL, using apt, dnf, or pacman instead of
Homebrew. On another Windows PC, follow the PowerShell steps above.

---

## Testing both computers

The point of the test is not "did it install" — it's "can this machine
actually push to GitHub." Two parts.

### Part 1 — the machine report

On each computer:

```powershell
.\setup\setup.ps1 -Test      # Windows
```
```bash
bash setup/setup.sh --test   # everything else
```

It prints the machine name, OS, git/gh versions, who you're signed in as, and
how many repos are cloned. Run it on both and put the two side by side — the
signed-in account should match, and neither should say `NOT INSTALLED` or `NO`.

### Part 2 — the push test

This is the real proof. On each computer, from the repo:

```powershell
cd "$HOME\github\first-pr-practice"
git checkout main; git pull
git checkout -b "hello-from-$env:COMPUTERNAME"
Add-Content setup\machines.txt "checked in from $env:COMPUTERNAME"
git commit -am "Say hello from $env:COMPUTERNAME"
git push -u origin HEAD
gh pr create --fill --draft
```

```bash
cd ~/github/first-pr-practice
git checkout main && git pull
MACHINE=$(hostname -s | tr -cd '[:alnum:]-')   # a Mac's hostname has dots in it
git checkout -b "hello-from-$MACHINE"
echo "checked in from $MACHINE" >> setup/machines.txt
git commit -am "Say hello from $MACHINE"
git push -u origin HEAD
gh pr create --fill --draft
```

Both computers pass when each one opens its own draft PR against this repo.
That exercises the whole chain — credentials, network, git, and the CLI. Close
the two test PRs without merging once you've seen them; they've done their job.
