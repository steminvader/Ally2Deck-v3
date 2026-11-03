#Requires -Version 5.1
<#
.SYNOPSIS
    Installs (or removes) the Ally2Deck sleep/wake display fix as a scheduled task.

.DESCRIPTION
    Registers a scheduled task that runs FixDisplayWake.ps1 automatically every time Windows
    resumes from sleep (Event 1 from Microsoft-Windows-Power-Troubleshooter and Event 107 from
    Microsoft-Windows-Kernel-Power). This replaces the usual "black screen after wake, run a
    script twice" dance with an automatic one-shot recovery.

.PARAMETER Uninstall
    Remove the scheduled task and the installed copy of FixDisplayWake.ps1.

.PARAMETER RunAsSystem
    Register the task as SYSTEM instead of the current interactive user. The adapter restart
    still works, but per-session display topology changes are less reliable from session 0,
    so the interactive user is the default.

.PARAMETER DelaySeconds
    Seconds to wait after resume before the fix runs. Default 4.

.PARAMETER InstallDir
    Where FixDisplayWake.ps1 is copied. Defaults to %ProgramData%\Ally2Deck.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\InstallWakeFix.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\InstallWakeFix.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$RunAsSystem,
    [int]$DelaySeconds = 4,
    [string]$InstallDir = "$env:ProgramData\Ally2Deck"
)

$ErrorActionPreference = 'Stop'
$TaskName = 'Ally2Deck-FixDisplayWake'
$ScriptName = 'FixDisplayWake.ps1'

try {
    $Host.UI.RawUI.BackgroundColor = 'Black'
    $Host.UI.RawUI.ForegroundColor = 'Gray'
} catch { }

try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
} catch {
    $isAdmin = $false
}

if (-not $isAdmin) {
    Write-Host "Restarting with administrative privileges..." -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Uninstall) { $psi.Arguments += ' -Uninstall' }
    if ($RunAsSystem) { $psi.Arguments += ' -RunAsSystem' }
    $psi.Arguments += " -DelaySeconds $DelaySeconds"
    $psi.Verb = 'runas'
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch { Write-Host 'Elevation declined. Exiting.' -ForegroundColor Red }
    exit
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Definition -Parent }

function Write-Step {
    param([string]$Message, [string]$Color = 'Cyan')
    Write-Host $Message -ForegroundColor $Color
}

Clear-Host
Write-Step 'Ally2Deck - Sleep/Wake Display Fix' 'Cyan'
Write-Host ''

# -------------------------------------------------------------------------------------------------
# Uninstall
# -------------------------------------------------------------------------------------------------

if ($Uninstall) {
    Write-Step "Removing scheduled task '$TaskName'..."
    try {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    } catch { }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Step 'Scheduled task removed.' 'Green'
    } else {
        Write-Step 'Scheduled task was not registered.' 'Yellow'
    }

    $installedScript = Join-Path $InstallDir $ScriptName
    if (Test-Path -LiteralPath $installedScript) {
        Remove-Item -LiteralPath $installedScript -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Step 'Uninstalled. The driver itself is untouched.' 'Green'
    Write-Host ''
    return
}

# -------------------------------------------------------------------------------------------------
# Install
# -------------------------------------------------------------------------------------------------

$sourceScript = Join-Path $ScriptDir $ScriptName
if (-not (Test-Path -LiteralPath $sourceScript)) {
    Write-Host "ERROR: $ScriptName not found next to this installer: $sourceScript" -ForegroundColor Red
    Write-Host 'Download FixDisplayWake.ps1 into the same folder as this script and try again.' -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

$targetScript = Join-Path $InstallDir $ScriptName
Copy-Item -LiteralPath $sourceScript -Destination $targetScript -Force
Write-Step "Installed script: $targetScript" 'Green'

# Event triggers: resume from sleep (both providers) - two simple XPath queries, no OR needed.
$queries = @(
    "*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and EventID=1]]",
    "*[System[Provider[@Name='Microsoft-Windows-Kernel-Power'] and EventID=107]]"
)

$triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
$triggers = @()
foreach ($query in $queries) {
    $trigger = New-CimInstance -CimClass $triggerClass -ClientOnly
    $trigger.Enabled = $true
    $trigger.Subscription = "<QueryList><Query Id='0' Path='System'><Select Path='System'>$query</Select></Query></QueryList>"
    $triggers += $trigger
}
Write-Step "Registered $($triggers.Count) resume triggers." 'Green'

$arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$targetScript`" -DelaySeconds $DelaySeconds -TimeoutSeconds 120"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
    -StartWhenAvailable

if ($RunAsSystem) {
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Write-Step 'Task will run as SYSTEM.' 'Yellow'
} else {
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    Write-Step "Task will run as $env:USERDOMAIN\$env:USERNAME (interactive, highest privileges)." 'Yellow'
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $triggers `
    -Settings $settings `
    -Principal $principal `
    -Description 'Restores the Steam Deck internal panel after sleep/wake on Ally2Deck drivers.' `
    -Force | Out-Null

$registered = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
Write-Step "Scheduled task '$TaskName' registered (state: $($registered.State))." 'Green'

Write-Host ''
Write-Step 'Done. The fix now runs automatically after every sleep/wake.' 'Green'
Write-Host ''
Write-Host 'Test it without sleeping:' -ForegroundColor Cyan
Write-Host "  Start-ScheduledTask -TaskName $TaskName" -ForegroundColor Gray
Write-Host ''
Write-Host 'Check the current state (changes nothing):' -ForegroundColor Cyan
Write-Host "  powershell -NoProfile -ExecutionPolicy Bypass -File `"$targetScript`" -Diagnose" -ForegroundColor Gray
Write-Host ''
Write-Host "Log file: $env:ProgramData\Ally2Deck\display-wake.log" -ForegroundColor Cyan
Write-Host ''
Write-Host "Remove it again with: InstallWakeFix.ps1 -Uninstall" -ForegroundColor DarkGray
Write-Host ''
Write-Host 'Press any key to exit...' -ForegroundColor DarkGray
try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
