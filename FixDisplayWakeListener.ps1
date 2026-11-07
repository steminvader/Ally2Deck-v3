#Requires -Version 5.1
<#
.SYNOPSIS
    Resident resume listener for the Ally2Deck sleep/wake display fix.

.DESCRIPTION
    These handhelds run Modern Standby (S0 Low Power Idle), not legacy S3 sleep.
    On Modern Standby the kernel never writes Microsoft-Windows-Power-Troubleshooter
    Event 1 or Kernel-Power Event 107, so a scheduled task triggered on those events
    can never fire - the task sits at LastTaskResult 267011 (0x41303) forever and the
    display recovery never runs. Resume is recorded as Kernel-Power Event 507
    ("exiting connected standby") instead.

    This script stays resident in the interactive session and waits for the
    WM_POWERBROADCAST resume notification, which Windows delivers on every resume
    regardless of the sleep model. When one arrives it launches FixDisplayWake.ps1.

.PARAMETER Install
    Copy the script to %ProgramData%\Ally2Deck and register a logon task so the
    listener starts with the session. Self-elevates.

.PARAMETER Uninstall
    Stop the listener, unregister its task and delete the installed copy.

.PARAMETER DelaySeconds
    Settle time passed to FixDisplayWake.ps1. Default 5.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\FixDisplayWakeListener.ps1 -Install

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\FixDisplayWakeListener.ps1
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [string]$InstallDir = "$env:ProgramData\Ally2Deck",
    [string]$LogPath = "$env:ProgramData\Ally2Deck\wake-listener.log",
    [int]$DelaySeconds = 5,
    [int]$DebounceSeconds = 20,
    [string]$TargetUser = "$env:USERDOMAIN\$env:USERNAME"
)

$ErrorActionPreference = 'Stop'

$TaskName     = 'Ally2Deck-DisplayWakeListener'
$LegacyTask   = 'Ally2Deck-FixDisplayWake'
$ScriptName   = 'FixDisplayWakeListener.ps1'
$RecoveryName = 'FixDisplayWake.ps1'

function Write-Log {
    param(
        [string]$Level = 'INFO',
        [string]$Message
    )

    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message

    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
    catch {
        # Logging must never take the listener down.
    }

    Write-Host $line
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-ElevatedSelf {
    param([string]$Arguments)

    Start-Process -FilePath 'powershell.exe' -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" $Arguments"
}

function Get-RecoveryScript {
    $candidates = @(
        (Join-Path -Path $PSScriptRoot -ChildPath $RecoveryName),
        (Join-Path -Path $InstallDir -ChildPath $RecoveryName)
    )

    foreach ($candidate in $candidates) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    return $null
}

function Install-Listener {
    if (-not (Test-IsAdmin)) {
        Write-Host 'Elevating to register the listener task...'
        Invoke-ElevatedSelf -Arguments "-Install -InstallDir `"$InstallDir`" -DelaySeconds $DelaySeconds -TargetUser `"$TargetUser`""
        return
    }

    if (-not (Test-Path -LiteralPath $InstallDir)) {
        $null = New-Item -ItemType Directory -Path $InstallDir -Force
    }

    $destination = Join-Path -Path $InstallDir -ChildPath $ScriptName
    if ($PSCommandPath -ne $destination) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $destination -Force
    }

    $recovery = Get-RecoveryScript
    if (-not $recovery) {
        Write-Log 'ERROR' "Cannot find $RecoveryName next to $ScriptName or in $InstallDir. Put both files in the same folder, then run -Install again."
        return
    }

    $installedRecovery = Join-Path -Path $InstallDir -ChildPath $RecoveryName
    if ($recovery -ne $installedRecovery) {
        Copy-Item -LiteralPath $recovery -Destination $installedRecovery -Force
    }

    # The event-log task can never fire on Modern Standby. Disable it rather than
    # delete it, so it stays available for troubleshooting and -Uninstall can revert.
    $legacy = Get-ScheduledTask -TaskName $LegacyTask -ErrorAction SilentlyContinue
    if ($legacy -and $legacy.State -ne 'Disabled') {
        Disable-ScheduledTask -TaskName $LegacyTask -ErrorAction SilentlyContinue | Out-Null
        Write-Log 'INFO' "Disabled the event-log task '$LegacyTask' (kept on disk, not deleted)."
    }

    $powershell = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destination`" -DelaySeconds $DelaySeconds -TargetUser `"$TargetUser`""

    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $TargetUser
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null

    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2

    $task = Get-ScheduledTask -TaskName $TaskName
    Write-Log 'OK' "Installed '$TaskName' for $TargetUser (state: $($task.State))."
    Write-Host ''
    Write-Host 'The listener now starts with every logon and runs the display recovery on every resume.'
    Write-Host "Listener log : $LogPath"
    Write-Host "Recovery log  : $InstallDir\display-wake.log"
}

function Uninstall-Listener {
    if (-not (Test-IsAdmin)) {
        Write-Host 'Elevating to remove the listener task...'
        Invoke-ElevatedSelf -Arguments "-Uninstall -InstallDir `"$InstallDir`""
        return
    }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Log 'OK' "Unregistered '$TaskName'."
    }

    Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and $_.CommandLine -like "*$ScriptName*" } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Log 'INFO' "Stopped listener process $($_.ProcessId)."
        }

    $installed = Join-Path -Path $InstallDir -ChildPath $ScriptName
    if (Test-Path -LiteralPath $installed) {
        Remove-Item -LiteralPath $installed -Force
        Write-Log 'OK' "Removed $installed."
    }

    $legacy = Get-ScheduledTask -TaskName $LegacyTask -ErrorAction SilentlyContinue
    if ($legacy -and $legacy.State -eq 'Disabled') {
        Enable-ScheduledTask -TaskName $LegacyTask -ErrorAction SilentlyContinue | Out-Null
        Write-Log 'INFO' "Re-enabled '$LegacyTask'."
    }
}

function Start-Listener {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\Ally2Deck-DisplayWakeListener')
    if (-not $mutex.WaitOne(0)) {
        Write-Log 'WARN' 'Another listener is already running in this session; exiting.'
        return 2
    }

    $recovery = Get-RecoveryScript
    if (-not $recovery) {
        Write-Log 'ERROR' "Cannot find $RecoveryName next to $ScriptName or in $InstallDir. Nothing to run on resume."
        return 3
    }

    $sessionId = (Get-Process -Id $PID).SessionId
    Write-Log 'INFO' "===== Ally2Deck wake listener starting (PID $PID, session $sessionId) ====="
    Write-Log 'INFO' "Recovery: $recovery (settle ${DelaySeconds}s, debounce ${DebounceSeconds}s)"

    $null = Register-ObjectEvent -InputObject ([Microsoft.Win32.SystemEvents]) `
        -EventName PowerModeChanged -SourceIdentifier 'Ally2Deck.PowerMode'

    Write-Log 'OK' 'Listening for resume notifications. Leave this process running.'

    $lastHandled = [datetime]::MinValue

    while ($true) {
        $powerEvent = Wait-Event -SourceIdentifier 'Ally2Deck.PowerMode' -Timeout 300
        if (-not $powerEvent) { continue }

        Remove-Event -EventIdentifier $powerEvent.EventIdentifier -ErrorAction SilentlyContinue

        $mode = $powerEvent.SourceEventArgs.Mode
        Write-Log 'INFO' "PowerModeChanged: $mode"

        if ($mode -ne [Microsoft.Win32.PowerModes]::Resume) { continue }

        $sinceLast = ((Get-Date) - $lastHandled).TotalSeconds
        if ($sinceLast -lt $DebounceSeconds) {
            Write-Log 'INFO' "Resume ignored: only ${sinceLast}s after the previous one."
            continue
        }
        $lastHandled = Get-Date

        try {
            $arguments = @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-WindowStyle', 'Hidden',
                '-File', ('"{0}"' -f $recovery),
                '-DelaySeconds', $DelaySeconds
            ) -join ' '

            $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
            Write-Log 'INFO' "Resume handled: launched the display recovery (PID $($process.Id))."
        }
        catch {
            Write-Log 'ERROR' "Could not launch the display recovery: $($_.Exception.Message)"
        }
    }
}

try {
    if ($Uninstall) { Uninstall-Listener; exit 0 }
    if ($Install) { Install-Listener; exit 0 }
    exit (Start-Listener)
}
catch {
    Write-Log 'ERROR' $_.Exception.Message
    exit 1
}
