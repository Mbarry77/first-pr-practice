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

### Step 1 — install the two tools

Open **PowerShell** from the Start menu and paste this:

```powershell
winget install --id Git.Git    -e --source winget --accept-package-agreements --accept-source-agreements
winget install --id GitHub.cli -e --source winget --accept-package-agreements --accept-source-agreements
```

### Step 2 — close that window, open a **new** PowerShell window

This matters. `winget` adds `git` and `gh` to your PATH, but only new windows
pick it up. Skipping this is the #1 reason step 3 fails with
`'gh' is not recognized`.

### Step 3 — sign in and run the setup

```powershell
gh auth login --hostname github.com --git-protocol https --web
gh repo clone Mbarry77/first-pr-practice "$HOME\github\first-pr-practice"
cd "$HOME\github\first-pr-practice"
powershell -ExecutionPolicy Bypass -File .\setup\setup.ps1
```

At sign-in, choose **GitHub.com → HTTPS → login with a browser** and paste the
one-time code it shows you.

That's it. Everything you can see on GitHub ends up in `C:\Users\matth\github\`.

### A note specific to this machine

Your System Information shows **App Control for Business: Enforced**. Two
consequences, both already handled:

- PowerShell may run in *Constrained Language Mode*. The script detects this,
  prints a warning, and avoids the .NET calls that mode blocks.
- Scripts won't run under the default execution policy, which is why step 3
  uses `-ExecutionPolicy Bypass` for that single command. It does not change
  any setting on the machine.

If `winget` itself is blocked by policy, install the two tools by hand from
[git-scm.com](https://git-scm.com/downloads) and [cli.github.com](https://cli.github.com),
then pick up at step 2.

---

## The second computer

**macOS / Linux / WSL:**

```bash
git clone https://github.com/Mbarry77/first-pr-practice.git ~/github/first-pr-practice
cd ~/github/first-pr-practice
bash setup/setup.sh
```

If `git` isn't installed yet, macOS will offer to install the developer tools
when you run that first command — accept, then re-run it.

**Another Windows machine:** same three steps as ALPHAX above.

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
git checkout -b "hello-from-$(hostname)"
echo "checked in from $(hostname)" >> setup/machines.txt
git commit -am "Say hello from $(hostname)"
git push -u origin HEAD
gh pr create --fill --draft
```

Both computers pass when each one opens its own draft PR against this repo.
That exercises the whole chain — credentials, network, git, and the CLI. Close
the two test PRs without merging once you've seen them; they've done their job.
