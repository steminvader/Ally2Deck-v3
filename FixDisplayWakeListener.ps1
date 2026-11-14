#Requires -Version 5.1
<#
.SYNOPSIS
    Resident resume listener with FORCED display recovery for Ally2Deck.

.DESCRIPTION
    Why this exists, in order:

    1. The original fix used scheduled tasks triggered on Power-Troubleshooter Event 1 and
       Kernel-Power Event 107. On units that resume from Modern Standby those events are
       never written, so the task never fired (LastTaskResult 267011 forever). On units that
       use S3 they ARE written, but a CIM/WMI subscription on the System log is unreliable
       and can also never fire. Either way the recovery never ran.

    2. This listener does not depend on the event log at all. It stays resident in the
       interactive session and reacts to the WM_POWERBROADCAST resume notification, which
       Windows delivers on every resume regardless of the sleep model.

    3. The old recovery script bailed out early when QueryDisplayConfig reported an active
       path:

           if ($bp.Active -gt 0) { 'Display is already active, nothing to do.'; exit }

       That test cannot detect the actual failure. After the KMD loses the internal eDP link,
       Windows keeps listing the panel as an active path in its cached display config, so the
       screen is black while every API says it is fine. The recovery then exits without doing
       anything, which is why the log said "already active" on a black screen.

    So on resume this listener ALWAYS runs the full recovery sequence - panel power-on, GDI
    re-enumeration, topology re-apply, and (unless -NoRestart) an adapter restart - instead of
    asking the OS whether it thinks the display is fine.

.PARAMETER Install
    Copy the script to %ProgramData%\Ally2Deck and register a logon task. Self-elevates.

.PARAMETER Uninstall
    Stop the listener, unregister its task and delete the installed copy.

.PARAMETER Test
    Run the forced recovery once, right now, and exit. Use this to check that the sequence
    works on a healthy desktop before relying on it after a wake. The screen blanks for a few
    seconds while the adapter restarts - that is expected.

.PARAMETER NoRestart
    Never restart the display adapter. Only power the panel on and re-apply the topology.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\FixDisplayWakeListener.ps1 -Install

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\FixDisplayWakeListener.ps1 -Test
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$Test,
    [string]$InstallDir = "$env:ProgramData\Ally2Deck",
    [string]$LogPath = "$env:ProgramData\Ally2Deck\wake-listener.log",
    [int]$DelaySeconds = 4,
    [int]$DebounceSeconds = 20,
    [int]$TimeoutSeconds = 90,
    [switch]$NoRestart,
    [string]$TargetUser = "$env:USERDOMAIN\$env:USERNAME"
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

$TaskName = 'Ally2Deck-DisplayWakeListener'
$LegacyTask = 'Ally2Deck-FixDisplayWake'
$ScriptName = 'FixDisplayWakeListener.ps1'

function Write-Log {
    param(
        [string]$Level = 'INFO',
        [string]$Message
    )

    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message

    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
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

# -------------------------------------------------------------------------------------------------
# Win32 display helpers
# -------------------------------------------------------------------------------------------------

$displayApiSource = @'
using System;
using System.Runtime.InteropServices;

public static class AllyForcedDisplay
{
    private const uint QDC_ALL_PATHS         = 0x00000001;
    private const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;

    public const uint SDC_TOPOLOGY_INTERNAL = 0x00000001;
    public const uint SDC_TOPOLOGY_EXTEND   = 0x00000004;
    public const uint SDC_APPLY             = 0x00000080;
    public const uint SDC_NO_OPTIMIZATION   = 0x00000100;
    public const uint SDC_SAVE_TO_DATABASE  = 0x00000200;
    public const uint SDC_ALLOW_CHANGES     = 0x00000400;

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(uint flags, ref uint paths, IntPtr pathArray,
        ref uint modes, IntPtr modeArray, IntPtr topologyId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int ChangeDisplaySettingsEx(string deviceName, IntPtr devMode,
        IntPtr hwnd, uint flags, IntPtr param);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint msg, IntPtr wParam,
        IntPtr lParam, uint flags, uint timeout, out IntPtr result);

    private static int CountPaths(uint flags)
    {
        uint pathCount = 0;
        uint modeCount = 0;

        if (GetDisplayConfigBufferSizes(flags, out pathCount, out modeCount) != 0) { return -1; }
        if (pathCount == 0) { return 0; }

        IntPtr pathBuffer = IntPtr.Zero;
        IntPtr modeBuffer = IntPtr.Zero;

        try
        {
            pathBuffer = Marshal.AllocHGlobal((int)pathCount * 256);
            modeBuffer = Marshal.AllocHGlobal((int)(modeCount == 0 ? 1 : modeCount) * 128);

            uint pCount = pathCount;
            uint mCount = modeCount;

            if (QueryDisplayConfig(flags, ref pCount, pathBuffer, ref mCount, modeBuffer, IntPtr.Zero) != 0)
            {
                return -1;
            }

            return (int)pCount;
        }
        finally
        {
            if (pathBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(pathBuffer); }
            if (modeBuffer != IntPtr.Zero) { Marshal.FreeHGlobal(modeBuffer); }
        }
    }

    // [available, active]
    public static int[] GetCounts()
    {
        return new int[] { CountPaths(QDC_ALL_PATHS), CountPaths(QDC_ONLY_ACTIVE_PATHS) };
    }

    public static int ResetDisplaySettings()
    {
        return ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0x40000000, IntPtr.Zero);
    }

    public static void WakeMonitor()
    {
        IntPtr result;
        SendMessageTimeout(new IntPtr(0xFFFF), 0x0112, new IntPtr(0xF170), new IntPtr(-1), 0x0002, 2000, out result);
    }

    public static int ApplyLastKnownGood()
    {
        return SetDisplayConfig(0, IntPtr.Zero, 0, IntPtr.Zero,
            SDC_APPLY | SDC_NO_OPTIMIZATION | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
    }

    public static int ApplyInternal()
    {
        return SetDisplayConfig(0, IntPtr.Zero, 0, IntPtr.Zero,
            SDC_TOPOLOGY_INTERNAL | SDC_APPLY | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
    }

    public static int ApplyExtend()
    {
        return SetDisplayConfig(0, IntPtr.Zero, 0, IntPtr.Zero,
            SDC_TOPOLOGY_EXTEND | SDC_APPLY | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
    }

    [DllImport("user32.dll")]
    private static extern int SetDisplayConfig(uint pathCount, IntPtr paths,
        uint modeCount, IntPtr modes, uint flags);
}
'@

try {
    if (-not ('AllyForcedDisplay' -as [type])) {
        Add-Type -TypeDefinition $displayApiSource -Language CSharp -ErrorAction Stop
    }
}
catch {
    Write-Log 'ERROR' "Failed to compile the display helper: $($_.Exception.Message)"
    exit 3
}

function Get-AllyGpuDevice {
    $devices = @(Get-PnpDevice -Class Display -ErrorAction SilentlyContinue)
    if ($devices.Count -eq 0) { return $null }

    $amd = @($devices | Where-Object {
        $_.InstanceId -match 'VEN_1002' -or $_.FriendlyName -match 'Radeon'
    })

    if ($amd.Count -gt 0) { return ($amd | Select-Object -First 1) }
    return ($devices | Select-Object -First 1)
}

function Get-PathCounts {
    $counts = [AllyForcedDisplay]::GetCounts()
    return [pscustomobject]@{
        Available = $counts[0]
        Active    = $counts[1]
    }
}

function Invoke-TopologyPass {
    $steps = @(
        @{ Name = 'last-known-good'; Result = [AllyForcedDisplay]::ApplyLastKnownGood() },
        @{ Name = 'internal';        Result = [AllyForcedDisplay]::ApplyInternal() },
        @{ Name = 'extend';          Result = [AllyForcedDisplay]::ApplyExtend() }
    )

    foreach ($step in $steps) {
        Write-Log 'DEBUG' ("SetDisplayConfig({0}) -> {1}" -f $step.Name, $step.Result)
        if ($step.Result -eq 0) { Start-Sleep -Milliseconds 900 }
    }
}

function Wait-ForTargets {
    param([int]$Seconds = 30)

    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        $state = Get-PathCounts
        if ($state.Available -gt 0) {
            Write-Log 'INFO' "Driver re-enumerated $($state.Available) display target(s)."
            return $true
        }
        Start-Sleep -Milliseconds 750
    }

    return $false
}

function Restart-DisplayAdapter {
    param([Parameter(Mandatory = $true)]$Device)

    $instanceId = $Device.InstanceId
    Write-Log 'WARN' "Restarting display adapter: $instanceId"

    $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    if (Test-Path -LiteralPath $pnputil) {
        $output = & $pnputil /restart-device "$instanceId" 2>&1
        $code = $LASTEXITCODE
        $text = ($output | Out-String).Trim()
        if ($text) { Write-Log 'DEBUG' "pnputil: $text" }
        Write-Log 'INFO' "pnputil /restart-device exited with code $code."
        if ($code -eq 0) { return (Wait-ForTargets -Seconds 30) }
    }

    Write-Log 'WARN' 'Falling back to Disable-PnpDevice / Enable-PnpDevice.'
    try {
        Disable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction Stop
    }
    catch {
        Write-Log 'ERROR' "Disable-PnpDevice failed: $($_.Exception.Message)"
        return $false
    }

    Start-Sleep -Seconds 2

    for ($i = 1; $i -le 10; $i++) {
        try {
            Enable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction Stop
            return (Wait-ForTargets -Seconds 25)
        }
        catch {
            Write-Log 'WARN' "Enable-PnpDevice attempt $i failed: $($_.Exception.Message)"
            Start-Sleep -Seconds 2
        }
    }

    return $false
}

# Runs the sequence unconditionally. It does not ask whether the display looks active,
# because that question is what made the old script skip every recovery step.
function Invoke-ForcedRecovery {
    param([string]$Reason = 'resume')

    $started = Get-Date
    $gpu = Get-AllyGpuDevice

    if (-not $gpu) {
        Write-Log 'ERROR' "$Reason : no display adapter found (is the driver loaded?)."
        return 2
    }

    $before = Get-PathCounts
    Write-Log 'INFO' "$Reason : GPU $($gpu.FriendlyName) status=$($gpu.Status); paths available=$($before.Available) active=$($before.Active)"

    $restarts = 0

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        # 1) Panel out of DPMS off, and make GDI re-enumerate from the driver.
        [AllyForcedDisplay]::WakeMonitor()
        $reset = [AllyForcedDisplay]::ResetDisplaySettings()
        Write-Log 'DEBUG' "Attempt #$attempt CDS_RESET -> $reset"

        # 2) Re-apply the topology.
        Invoke-TopologyPass

        Start-Sleep -Milliseconds 1200

        # 3) Last resort: make the driver re-run its start routine and re-train eDP.
        if ($NoRestart) {
            Write-Log 'WARN' 'NoRestart is set, so the adapter will not be restarted.'
            break
        }

        if ($restarts -ge 2) {
            Write-Log 'WARN' 'Adapter already restarted twice; stopping here.'
            break
        }

        $restarts++
        Write-Log 'INFO' "Attempt #$attempt adapter restart $restarts of 2."
        [void](Restart-DisplayAdapter -Device $gpu)

        # A restart leaves the panel powered down often enough that the sequence has to repeat.
        [AllyForcedDisplay]::WakeMonitor()
        [void][AllyForcedDisplay]::ResetDisplaySettings()
        Invoke-TopologyPass

        Start-Sleep -Milliseconds 1500
    }

    $after = Get-PathCounts
    $elapsed = [int]((Get-Date) - $started).TotalSeconds
    Write-Log 'OK' "$Reason : forced recovery finished in $elapsed s after $restarts adapter restart(s); paths available=$($after.Available) active=$($after.Active). If the picture is back, sleep/wake again to confirm it repeats."

    return 0
}

# -------------------------------------------------------------------------------------------------
# Install / uninstall
# -------------------------------------------------------------------------------------------------

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

    # The event-log task can never be relied on. Disable it rather than delete it.
    $legacy = Get-ScheduledTask -TaskName $LegacyTask -ErrorAction SilentlyContinue
    if ($legacy -and $legacy.State -ne 'Disabled') {
        Disable-ScheduledTask -TaskName $LegacyTask -ErrorAction SilentlyContinue | Out-Null
        Write-Log 'INFO' "Disabled the event-log task '$LegacyTask' (kept on disk, not deleted)."
    }

    $powershell = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$destination`" -DelaySeconds $DelaySeconds -TargetUser `"$TargetUser`""

    $action = New-ScheduledTaskAction -Execute $powershell -Argument $arguments
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $TargetUser

    $settingsParams = @{
        AllowStartIfOnBatteries    = $true
        DontStopIfGoingOnBatteries = $true
        StartWhenAvailable         = $true
        ExecutionTimeLimit         = [TimeSpan]::Zero
        MultipleInstances          = 'IgnoreNew'
        RestartCount               = 3
        RestartInterval            = (New-TimeSpan -Minutes 1)
    }
    $settings = New-ScheduledTaskSettingsSet @settingsParams

    $principal = New-ScheduledTaskPrincipal -UserId $TargetUser -LogonType Interactive -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null

    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 2

    $task = Get-ScheduledTask -TaskName $TaskName
    Write-Log 'OK' "Installed '$TaskName' for $TargetUser (state: $($task.State))."
    Write-Host ''
    Write-Host 'The listener now runs the forced recovery on every resume.'
    Write-Host 'Verify the sequence now, while the screen still works:'
    Write-Host '    powershell -NoProfile -ExecutionPolicy Bypass -File .\FixDisplayWakeListener.ps1 -Test'
    Write-Log 'INFO' "Listener log: $LogPath"
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

# -------------------------------------------------------------------------------------------------
# Resident listener
# -------------------------------------------------------------------------------------------------

function Start-Listener {
    $mutex = New-Object System.Threading.Mutex($false, 'Local\Ally2Deck-DisplayWakeListener')
    if (-not $mutex.WaitOne(0)) {
        Write-Log 'WARN' 'Another listener is already running in this session; exiting.'
        return 2
    }

    $sessionId = (Get-Process -Id $PID).SessionId
    Write-Log 'INFO' "===== Ally2Deck wake listener starting (PID $PID, session $sessionId) ====="
    Write-Log 'INFO' "Forced recovery: settle ${DelaySeconds}s, debounce ${DebounceSeconds}s, NoRestart=$NoRestart"

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

        Start-Sleep -Seconds $DelaySeconds

        try {
            [void](Invoke-ForcedRecovery -Reason 'resume')
        }
        catch {
            Write-Log 'ERROR' "Forced recovery threw: $($_.Exception.Message)"
        }
    }
}

try {
    if ($Uninstall) { Uninstall-Listener; exit 0 }
    if ($Install) { Install-Listener; exit 0 }
    if ($Test) { exit (Invoke-ForcedRecovery -Reason 'manual test') }
    exit (Start-Listener)
}
catch {
    Write-Log 'ERROR' $_.Exception.Message
    exit 1
}
