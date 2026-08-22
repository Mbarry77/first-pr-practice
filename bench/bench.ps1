# Machine capability benchmark - Windows wrapper.
#
#   .\bench.ps1                          # default
#   .\bench.ps1 -DiskPath D:\            # measure the big array instead of C:
#   .\bench.ps1 -Quick
#
# Collects hardware inventory Windows knows about, then hands off to
# bench_core.py for the measurements that must be identical across machines.

[CmdletBinding()]
param(
    [string]$DiskPath,
    [switch]$Quick,
    [switch]$SkipDisk,
    [string]$JsonOut = "bench-$env:COMPUTERNAME.json"
)

$ErrorActionPreference = 'Stop'
if (Get-Variable PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Say ($m) { Write-Host "`n==> $m" -ForegroundColor Cyan }
function Row ($k, $v) { Write-Host ("    {0,-22} {1}" -f $k, $v) }

# ------------------------------------------------------------------ inventory

Say 'HARDWARE'

try {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Row 'CPU' $cpu.Name
    Row 'Cores / threads' "$($cpu.NumberOfCores) physical, $($cpu.NumberOfLogicalProcessors) logical"
    Row 'Max clock' "$($cpu.MaxClockSpeed) MHz"
} catch { Row 'CPU' "(unavailable: $($_.Exception.Message))" }

try {
    $os = Get-CimInstance Win32_OperatingSystem
    Row 'OS' "$($os.Caption) build $($os.BuildNumber)"
    Row 'RAM total' ("{0:N1} GB" -f ($os.TotalVisibleMemorySize / 1MB))
    Row 'RAM free' ("{0:N1} GB" -f ($os.FreePhysicalMemory / 1MB))
} catch { Row 'OS' '(unavailable)' }

try {
    $sticks = @(Get-CimInstance Win32_PhysicalMemory)
    if ($sticks) {
        $speeds = ($sticks | ForEach-Object { $_.Speed } | Sort-Object -Unique) -join '/'
        Row 'Memory modules' "$($sticks.Count) x, $speeds MT/s"
    }
} catch { }

Say 'STORAGE'
try {
    Get-CimInstance Win32_DiskDrive | ForEach-Object {
        Row $_.Model ("{0:N0} GB, {1}" -f ($_.Size / 1GB), $_.InterfaceType)
    }
} catch { Row 'disks' '(unavailable)' }

try {
    Get-Volume | Where-Object { $_.DriveLetter } | Sort-Object DriveLetter | ForEach-Object {
        Row "$($_.DriveLetter): $($_.FileSystemType)" (
            "{0:N0} GB free of {1:N0} GB" -f ($_.SizeRemaining / 1GB), ($_.Size / 1GB))
    }
} catch { }

Say 'NETWORK'
# LinkSpeed is the negotiated rate. A 10G card sitting at 1 Gbps means a cable,
# switch port, or driver is holding it back - worth catching before blaming code.
try {
    Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
        Row $_.Name "$($_.LinkSpeed)  [$($_.InterfaceDescription)]"
    }
} catch { Row 'adapters' '(unavailable)' }

Say 'EXPANSION'
# Answers "can this machine take a 10G card?" without opening the case.
# Win32_SystemSlot reports each physical slot and whether something is in it.
try {
    $slots = @(Get-CimInstance Win32_SystemSlot -ErrorAction Stop)
    if ($slots.Count -eq 0) {
        Row 'PCIe slots' '(firmware reports none - check the manual)'
    } else {
        foreach ($slot in $slots) {
            $usage = switch ($slot.CurrentUsage) {
                3       { 'AVAILABLE' }
                4       { 'in use' }
                default { "usage code $($slot.CurrentUsage)" }
            }
            Row $slot.SlotDesignation "$usage - $($slot.Description)"
        }
    }
} catch { Row 'PCIe slots' "(unavailable: $($_.Exception.Message))" }

# Thunderbolt is the fallback path to 10G+ when no slot is free - the NAS
# under consideration has two TB4 ports.
try {
    $tb = @(Get-PnpDevice -PresentOnly -ErrorAction Stop |
            Where-Object { $_.FriendlyName -match 'Thunderbolt|USB4' } |
            Select-Object -ExpandProperty FriendlyName -Unique)
    if ($tb) { foreach ($d in $tb) { Row 'Thunderbolt/USB4' $d } }
    else     { Row 'Thunderbolt/USB4' 'none detected' }
} catch { Row 'Thunderbolt/USB4' '(unavailable)' }

# -------------------------------------------------------------------- python

$py = $null
foreach ($candidate in 'python', 'python3', 'py') {
    if (Get-Command $candidate -ErrorAction SilentlyContinue) {
        # The Microsoft Store stub named 'python' exits non-zero and prints nothing.
        $probe = & $candidate --version 2>&1
        if ($LASTEXITCODE -eq 0 -and $probe -match 'Python 3') { $py = $candidate; break }
    }
}

if (-not $py) {
    Write-Host "`nPython 3 is not installed - the measurement half needs it." -ForegroundColor Yellow
    Write-Host "Install it, then re-run this script:" -ForegroundColor Yellow
    Write-Host "    winget install --id Python.Python.3.12 -e --source winget --accept-package-agreements"
    Write-Host "    `$env:Path += `";`$env:LOCALAPPDATA\Programs\Python\Python312;`$env:LOCALAPPDATA\Programs\Python\Python312\Scripts`""
    exit 1
}
Say 'SOFTWARE'
Row 'Python' (& $py --version)

# ---------------------------------------------------------------- measurements

$core = Join-Path $PSScriptRoot 'bench_core.py'
if (-not (Test-Path $core)) { throw "bench_core.py not found next to this script ($core)" }

$argv = @($core, '--json', $JsonOut)
if ($DiskPath) { $argv += @('--disk-path', $DiskPath) }
if ($Quick)    { $argv += '--quick' }
if ($SkipDisk) { $argv += '--skip-disk' }

Say 'MEASUREMENTS'
& $py @argv
if ($LASTEXITCODE -ne 0) { throw "bench_core.py exited with $LASTEXITCODE" }

Write-Host "Send $JsonOut back to compare against the other machine.`n" -ForegroundColor Green
