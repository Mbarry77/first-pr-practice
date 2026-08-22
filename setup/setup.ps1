# One-shot GitHub setup for a new Windows machine.
#
#   .\setup.ps1           install tools, sign in, clone every repo, print report
#   .\setup.ps1 -Test     skip install/clone, just print the machine report
#
# Clone location: $env:GITHUB_DIR, or ~\github by default.

[CmdletBinding()]
param([switch]$Test)

$ErrorActionPreference = 'Stop'

# On PowerShell 7.4+ this defaults to $true, which turns any non-zero exit from
# git/gh into a thrown error. We check exit codes deliberately, so turn it off.
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$GithubDir = if ($env:GITHUB_DIR) { $env:GITHUB_DIR } else { Join-Path $HOME 'github' }

function Say  ($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Ok   ($m) { Write-Host "    [ok] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "    [!!] $m" -ForegroundColor Yellow }
function Have ($c) { [bool](Get-Command $c -ErrorAction SilentlyContinue) }

# App Control for Business (WDAC) can force Constrained Language Mode, where .NET
# calls like [Environment]::... are blocked. Detect it and stay on the safe path.
$Constrained = $ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage'
if ($Constrained) {
    Warn "PowerShell is in $($ExecutionContext.SessionState.LanguageMode) (App Control is enforced)."
    Warn 'Handled - the script stays off the calls that mode blocks.'
}

# winget puts new tools on the PATH of *future* shells only, so a fresh install is
# invisible to the window that installed it. Rather than making the user close and
# reopen, add the standard install locations to this session's PATH directly.
# Plain string work, so it survives Constrained Language Mode too.
function Add-KnownToolPaths {
    $candidates = @(
        "$env:ProgramFiles\Git\cmd"
        "$env:ProgramFiles\GitHub CLI"
        "${env:ProgramFiles(x86)}\Git\cmd"
        "$env:LOCALAPPDATA\Programs\Git\cmd"
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links"
    )
    foreach ($dir in $candidates) {
        # Skip entries whose environment variable was empty (e.g. no x86 dir on
        # a 64-bit-only install) - they collapse to a bare relative path.
        if ($dir -notmatch '^[A-Za-z]:\\') { continue }
        if ((Test-Path $dir) -and ($env:Path -notlike "*$dir*")) {
            $env:Path = "$env:Path;$dir"
        }
    }
}
Add-KnownToolPaths

# ---------------------------------------------------------------- install deps

function Install-Tool($command, $wingetId, $displayName) {
    if (Have $command) { Ok "$displayName already installed"; return }
    Say "Installing $displayName"
    if (-not (Have 'winget')) {
        throw "winget not found. Install $displayName manually, then re-run this script."
    }
    winget install --id $wingetId --source winget --accept-package-agreements --accept-source-agreements -e

    # Make the just-installed tool usable in THIS window: known locations first,
    # then a full re-read of the persisted PATH where the language mode allows it.
    Add-KnownToolPaths
    if (-not (Have $command) -and -not $Constrained) {
        $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                    [Environment]::GetEnvironmentVariable('Path', 'User')
    }
    if (-not (Have $command)) {
        throw "$displayName installed but '$command' is still not on PATH. Close this window, open a new one, and re-run."
    }
    Ok "$displayName installed"
}

# ------------------------------------------------------------------- sign in

function Connect-GitHub {
    gh auth status *>$null
    if ($LASTEXITCODE -eq 0) {
        Ok "already signed in as $(gh api user -q .login)"
    } else {
        Say 'Signing in to GitHub'
        Write-Host '    A browser window will open. Pick: GitHub.com -> HTTPS -> login with a browser.'
        gh auth login --hostname github.com --git-protocol https --web
        if ($LASTEXITCODE -ne 0) { throw 'GitHub sign-in did not complete.' }
    }
    gh auth setup-git   # makes git push/pull use your gh credentials, no password prompts
}

function Set-GitIdentity {
    Say 'Configuring git identity'
    $login = gh api user -q .login
    $name  = gh api user -q '.name // ""'
    if (-not $name) { $name = $login }
    $email = gh api user/emails -q '[.[] | select(.primary)][0].email' 2>$null
    if (-not $email) { $email = "$(gh api user -q .id)+$login@users.noreply.github.com" }

    git config --global user.name  $name
    git config --global user.email $email
    git config --global init.defaultBranch main
    git config --global pull.ff only
    Ok "$name <$email>"
}

# -------------------------------------------------------------- clone repos

function Copy-AllRepos {
    Say "Cloning every repo you can see into $GithubDir"
    New-Item -ItemType Directory -Force -Path $GithubDir | Out-Null

    $repos = @(gh repo list --limit 1000 --json nameWithOwner --jq '.[].nameWithOwner') |
             Where-Object { $_ }
    if (-not $repos) { Warn 'no repos found on this account'; return }

    $cloned = 0; $updated = 0; $skipped = 0
    foreach ($repo in $repos) {
        $dir = Join-Path $GithubDir ($repo -split '/')[-1]
        if (Test-Path (Join-Path $dir '.git')) {
            if (git -C $dir status --porcelain) {
                Warn "$repo has local changes - fetching only"
                git -C $dir fetch --all --quiet; $skipped++
            } else {
                git -C $dir pull --ff-only --quiet
                if ($LASTEXITCODE -eq 0) { $updated++ } else { Warn "could not fast-forward $repo" }
            }
        } else {
            gh repo clone $repo $dir -- --quiet
            if ($LASTEXITCODE -eq 0) { $cloned++ } else { Warn "could not clone $repo" }
        }
    }
    Ok "$($repos.Count) repos: $cloned cloned, $updated updated, $skipped left alone (uncommitted work)"
}

# ------------------------------------------------------------------- report

function Show-Report {
    $repoCount = 0
    if (Test-Path $GithubDir) {
        $repoCount = @(Get-ChildItem $GithubDir -Directory |
                       Where-Object { Test-Path (Join-Path $_.FullName '.git') }).Count
    }
    gh auth status *>$null
    $who = if ($LASTEXITCODE -eq 0) { gh api user -q .login } else { 'NO' }

    $osName = try { (Get-CimInstance Win32_OperatingSystem).Caption } catch { 'Windows' }
    $osBuild = try { (Get-CimInstance Win32_OperatingSystem).BuildNumber } catch { 'unknown build' }

    Say 'MACHINE REPORT  --  run this on both computers and compare'
    @"
    machine   : $env:COMPUTERNAME
    os        : $osName (build $osBuild, PowerShell $($PSVersionTable.PSVersion))
    user      : $env:USERNAME
    git       : $(if (Have 'git') { git --version } else { 'NOT INSTALLED' })
    gh        : $(if (Have 'gh')  { (gh --version)[0] } else { 'NOT INSTALLED' })
    signed in : $who
    git name  : $(git config --global user.name)
    git email : $(git config --global user.email)
    repo dir  : $GithubDir
    repos     : $repoCount cloned locally
"@ | Write-Host

    Say 'Push test (proves this machine can actually write to GitHub)'
    Write-Host @"
    cd $GithubDir\first-pr-practice
    git checkout -b hello-from-$env:COMPUTERNAME
    Add-Content setup\machines.txt "checked in from $env:COMPUTERNAME"
    git commit -am "Say hello from $env:COMPUTERNAME"; git push -u origin HEAD
    gh pr create --fill --draft

    Both computers pass when both can open a PR that way.
"@
}

# --------------------------------------------------------------------- main

if (-not $Test) {
    Install-Tool 'git' 'Git.Git'      'Git'
    Install-Tool 'gh'  'GitHub.cli'   'GitHub CLI'
    Connect-GitHub
    Set-GitIdentity
    Copy-AllRepos
}
Show-Report
