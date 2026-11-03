#Requires -Version 5.1
<#
.SYNOPSIS
    Restores the Steam Deck internal panel after the Ally2Deck driver loses it on sleep/wake.

.DESCRIPTION
    On some Steam Deck units the Ally2Deck (ROG Xbox Ally) display driver resumes from
    sleep (Modern Standby / S0ix or S3) without any display target enumerated by the
    kernel mode driver. Windows then has no monitor attached to the GPU, which is why:

        CDS_RESET          -> -1  (DISP_CHANGE_FAILED)
        SetDisplayConfig   -> 87  (ERROR_INVALID_PARAMETER, zero valid display paths)

    This script waits for the GPU to settle, checks whether the KMD enumerated any display
    target at all and, if it did not, restarts the display adapter so the driver re-runs its
    start routine (and therefore re-trains the internal eDP panel). It then re-applies the
    last known good topology, verifies that an active display path exists and retries until
    it works or the timeout expires.

    Unlike a "sleep 3 seconds then fire and forget" script, every step here is checked, so it
    works on the FIRST wake instead of only on the second one.

.PARAMETER TimeoutSeconds
    How long to keep retrying before giving up. Default 120.

.PARAMETER DelaySeconds
    Initial wait after wake so the power manager and KMD finish their own resume work.
    Default 4.

.PARAMETER NoRestart
    Never restart the display adapter. Only re-apply the display topology (gentler, but it
    cannot fix a resume where the KMD enumerated no targets at all).

.PARAMETER Diagnose
    Print the current display state and exit without changing anything.

.PARAMETER LogPath
    Log file. Defaults to %ProgramData%\Ally2Deck\display-wake.log.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\FixDisplayWake.ps1 -Diagnose

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\FixDisplayWake.ps1
#>
[CmdletBinding()]
param(
    [int]$TimeoutSeconds = 120,
    [int]$DelaySeconds = 4,
    [switch]$NoRestart,
    [switch]$Diagnose,
    [string]$LogPath = "$env:ProgramData\Ally2Deck\display-wake.log"
)

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'

# -------------------------------------------------------------------------------------------------
# Logging
# -------------------------------------------------------------------------------------------------

function Initialize-Log {
    if (-not $LogPath) { return }
    try {
        $dir = Split-Path -Parent $LogPath
        if ($dir -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        if (Test-Path -LiteralPath $LogPath) {
            if ((Get-Item -LiteralPath $LogPath).Length -gt 1MB) {
                Move-Item -LiteralPath $LogPath -Destination "$LogPath.1" -Force -ErrorAction SilentlyContinue
            }
        }
    } catch { }
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DEBUG')][string]$Level = 'INFO'
    )

    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message

    if ($LogPath) {
        try {
            $dir = Split-Path -Parent $LogPath
            if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                New-Item -ItemType Directory -Path $dir -Force | Out-Null
            }
            Add-Content -LiteralPath $LogPath -Value $line -ErrorAction Stop
        } catch { }
    }

    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        'DEBUG' { if ($VerbosePreference -ne 'SilentlyContinue' -or $Diagnose) { Write-Host $line -ForegroundColor DarkGray } }
        default { Write-Host $line }
    }
}

# -------------------------------------------------------------------------------------------------
# Win32 display configuration helpers
# -------------------------------------------------------------------------------------------------

$displayApiSource = @'
using System;
using System.Runtime.InteropServices;

public static class AllyDisplayApi
{
    private const uint QDC_ALL_PATHS        = 0x00000001;
    private const uint QDC_ONLY_ACTIVE_PATHS = 0x00000002;

    // SetDisplayConfig flags
    public const uint SDC_TOPOLOGY_INTERNAL = 0x00000001;
    public const uint SDC_TOPOLOGY_EXTEND   = 0x00000004;
    public const uint SDC_APPLY             = 0x00000080;
    public const uint SDC_NO_OPTIMIZATION   = 0x00000100;
    public const uint SDC_SAVE_TO_DATABASE  = 0x00000200;
    public const uint SDC_ALLOW_CHANGES     = 0x00000400;

    public const int ERROR_SUCCESS           = 0;
    public const int ERROR_INVALID_PARAMETER = 87;

    [DllImport("user32.dll")]
    private static extern int GetDisplayConfigBufferSizes(
        uint flags,
        out uint numPathArrayElements,
        out uint numModeInfoArrayElements);

    [DllImport("user32.dll")]
    private static extern int QueryDisplayConfig(
        uint flags,
        ref uint numPathArrayElements,
        IntPtr pathArray,
        ref uint numModeInfoArrayElements,
        IntPtr modeInfoArray,
        IntPtr currentTopologyId);

    [DllImport("user32.dll")]
    private static extern int SetDisplayConfig(
        uint numPathArrayElements,
        IntPtr pathArray,
        uint numModeInfoArrayElements,
        IntPtr modeInfoArray,
        uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int ChangeDisplaySettingsEx(
        string deviceName,
        IntPtr devMode,
        IntPtr hwnd,
        uint flags,
        IntPtr param);

    [DllImport("user32.dll")]
    private static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        IntPtr wParam,
        IntPtr lParam,
        uint fuFlags,
        uint uTimeout,
        out IntPtr lpdwResult);

    // All paths the KMD currently knows about (active and inactive).
    // 0 means the driver enumerated no display targets at all.
    public static int GetAllPathCount(out int error)
    {
        return CountPaths(QDC_ALL_PATHS, out error);
    }

    public static int GetActivePathCount(out int error)
    {
        return CountPaths(QDC_ONLY_ACTIVE_PATHS, out error);
    }

    private static int CountPaths(uint flags, out int error)
    {
        error = 0;
        uint pathCount = 0;
        uint modeCount = 0;

        int status = GetDisplayConfigBufferSizes(flags, out pathCount, out modeCount);
        if (status != 0)
        {
            error = status;
            return -1;
        }

        if (pathCount == 0)
        {
            return 0;
        }

        IntPtr pathBuffer = IntPtr.Zero;
        IntPtr modeBuffer = IntPtr.Zero;
        try
        {
            // Generous buffers: DISPLAYCONFIG_PATH_INFO is 88 bytes, DISPLAYCONFIG_MODE_INFO is 64.
            pathBuffer = Marshal.AllocHGlobal((int)pathCount * 256);
            modeBuffer = Marshal.AllocHGlobal((int)(modeCount == 0 ? 1 : modeCount) * 128);

            uint pCount = pathCount;
            uint mCount = modeCount;
            status = QueryDisplayConfig(flags, ref pCount, pathBuffer, ref mCount, modeBuffer, IntPtr.Zero);
            if (status != 0)
            {
                error = status;
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

    public static int ApplyConfig(uint flags)
    {
        return SetDisplayConfig(0, IntPtr.Zero, 0, IntPtr.Zero, flags);
    }

    // Last known good topology stored by the OS, no vendor user-mode stack required.
    public static int ApplyLastKnownGood()
    {
        return ApplyConfig(SDC_APPLY | SDC_NO_OPTIMIZATION | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
    }

    public static int ApplyInternalTopology()
    {
        return ApplyConfig(SDC_TOPOLOGY_INTERNAL | SDC_APPLY | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
    }

    public static int ApplyExtendTopology()
    {
        return ApplyConfig(SDC_TOPOLOGY_EXTEND | SDC_APPLY | SDC_ALLOW_CHANGES | SDC_SAVE_TO_DATABASE);
    }

    // Force GDI to throw away its cached display state and re-enumerate from the driver.
    public static int ResetDisplaySettings()
    {
        return ChangeDisplaySettingsEx(null, IntPtr.Zero, IntPtr.Zero, 0x40000000 /* CDS_RESET */, IntPtr.Zero);
    }

    // Broadcast SC_MONITORPOWER = -1 to bring the panel out of DPMS off.
    public static void WakeMonitor()
    {
        IntPtr result;
        SendMessageTimeout(
            new IntPtr(0xFFFF),      // HWND_BROADCAST
            0x0112,                  // WM_SYSCOMMAND
            new IntPtr(0xF170),      // SC_MONITORPOWER
            new IntPtr(-1),          // MONITOR_ON
            0x0002,                  // SMTO_ABORTIFHUNG
            2000,
            out result);
    }
}
'@

try {
    if (-not ('AllyDisplayApi' -as [type])) {
        Add-Type -TypeDefinition $displayApiSource -Language CSharp -ErrorAction Stop
    }
} catch {
    Write-Host "Failed to compile the display helper: $($_.Exception.Message)" -ForegroundColor Red
    exit 3
}

# -------------------------------------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------------------------------------

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
    $allError = 0
    $activeError = 0
    $all = [AllyDisplayApi]::GetAllPathCount([ref]$allError)
    $active = [AllyDisplayApi]::GetActivePathCount([ref]$activeError)

    return [pscustomobject]@{
        All         = $all
        Active      = $active
        AllError    = $allError
        ActiveError = $activeError
    }
}

function Test-DisplayRestored {
    $state = Get-PathCounts
    return ($state.Active -gt 0)
}

function Wait-ForDisplayTargets {
    param([int]$TimeoutSeconds = 25)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $state = Get-PathCounts
        if ($state.All -gt 0) {
            Write-Log "Driver re-enumerated $($state.All) display target(s)."
            return $true
        }
        Start-Sleep -Milliseconds 750
    }

    Write-Log "Driver still reports no display targets after $TimeoutSeconds second(s)." 'WARN'
    return $false
}

function Restart-DisplayAdapter {
    param([Parameter(Mandatory = $true)]$Device)

    $instanceId = $Device.InstanceId
    Write-Log "Restarting display adapter: $instanceId" 'WARN'

    $pnputil = Join-Path $env:SystemRoot 'System32\pnputil.exe'
    if (Test-Path -LiteralPath $pnputil) {
        $output = & $pnputil /restart-device "$instanceId" 2>&1
        $code = $LASTEXITCODE
        $text = ($output | Out-String).Trim()
        if ($text) { Write-Log "pnputil: $text" 'DEBUG' }
        Write-Log "pnputil /restart-device exited with code $code."
        if ($code -eq 0) {
            return (Wait-ForDisplayTargets -TimeoutSeconds 30)
        }
    }

    # Windows builds without /restart-device: fall back to a PnP disable/enable cycle.
    Write-Log 'Falling back to Disable-PnpDevice / Enable-PnpDevice.' 'WARN'
    try {
        Disable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction Stop
    } catch {
        Write-Log "Disable-PnpDevice failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }

    Start-Sleep -Seconds 2

    for ($i = 1; $i -le 10; $i++) {
        try {
            Enable-PnpDevice -InstanceId $instanceId -Confirm:$false -ErrorAction Stop
            return (Wait-ForDisplayTargets -TimeoutSeconds 25)
        } catch {
            Write-Log "Enable-PnpDevice attempt $i failed: $($_.Exception.Message)" 'WARN'
            Start-Sleep -Seconds 2
        }
    }

    return $false
}

function Invoke-TopologyPass {
    param([int]$Attempt)

    $steps = @(
        @{ Name = 'last-known-good'; Result = [AllyDisplayApi]::ApplyLastKnownGood() },
        @{ Name = 'internal';        Result = [AllyDisplayApi]::ApplyInternalTopology() },
        @{ Name = 'extend';          Result = [AllyDisplayApi]::ApplyExtendTopology() }
    )

    foreach ($step in $steps) {
        Write-Log ("Attempt #{0} SetDisplayConfig({1}) -> {2}" -f $Attempt, $step.Name, $step.Result) 'DEBUG'
        if ($step.Result -eq 0) {
            Start-Sleep -Milliseconds 1200
            if (Test-DisplayRestored) { return $true }
        }
    }

    return $false
}

# -------------------------------------------------------------------------------------------------
# Main
# -------------------------------------------------------------------------------------------------

Initialize-Log
$started = Get-Date

try {
    $sessionId = (Get-Process -Id $PID).SessionId
} catch {
    $sessionId = -1
}

Write-Log "===== Ally2Deck display wake fix starting (PID $PID, session $sessionId) ====="

$gpu = Get-AllyGpuDevice
if (-not $gpu) {
    Write-Log 'No display adapter found (is the driver loaded?).' 'ERROR'
    exit 2
}

$bp = Get-PathCounts
Write-Log "GPU: $($gpu.FriendlyName) [$($gpu.InstanceId)] status=$($gpu.Status)"
Write-Log "Display paths: active=$($bp.Active) available=$($bp.All) (errors: active=$($bp.ActiveError) all=$($bp.AllError))"

$monitors = @(Get-PnpDevice -Class Monitor -ErrorAction SilentlyContinue)
if ($monitors.Count -gt 0) {
    Write-Log ("Monitors: " + (($monitors | ForEach-Object { $_.FriendlyName }) -join '; '))
} else {
    Write-Log 'Monitors: none registered' 'WARN'
}

if ($sessionId -eq 0) {
    Write-Log 'Running in session 0: adapter restarts still work, but GDI topology changes only apply to the interactive session.' 'WARN'
}

if ($Diagnose) {
    if ($bp.Active -gt 0) {
        Write-Log 'Diagnose: a display is active, nothing to fix.' 'OK'
        exit 0
    }
    if ($bp.All -gt 0) {
        Write-Log 'Diagnose: the driver sees display targets but none are active (topology pass should fix it).' 'WARN'
        exit 0
    }
    Write-Log 'Diagnose: the driver reports zero display targets (adapter restart required).' 'WARN'
    exit 0
}

if ($bp.Active -gt 0) {
    Write-Log 'Display is already active, nothing to do.' 'OK'
    exit 0
}

if ($DelaySeconds -gt 0) {
    Write-Log "Waiting $DelaySeconds second(s) for the power manager to finish resuming."
    Start-Sleep -Seconds $DelaySeconds
}

$deadline = $started.AddSeconds($TimeoutSeconds)
$attempt = 0
$restarts = 0
$maxRestarts = 2
$restored = $false

while ((Get-Date) -lt $deadline) {
    $attempt++

    if (Test-DisplayRestored) {
        $restored = $true
        break
    }

    # 1) Bring the panel out of DPMS off and make GDI re-enumerate.
    if ($attempt -le 2) {
        [AllyDisplayApi]::WakeMonitor()
        $reset = [AllyDisplayApi]::ResetDisplaySettings()
        Write-Log "Attempt #$attempt CDS_RESET -> $reset" 'DEBUG'
    }

    # 2) Re-apply the topology.
    if (Invoke-TopologyPass -Attempt $attempt) {
        $restored = $true
        break
    }

    # 3) The driver has no targets at all: force it to re-run its start routine.
    $state = Get-PathCounts
    Write-Log "Attempt #$attempt state: active=$($state.Active) available=$($state.All)"

    if ($state.All -le 0) {
        if ($NoRestart) {
            Write-Log 'NoRestart was specified, so the adapter will not be restarted.' 'WARN'
        } elseif ($restarts -ge $maxRestarts) {
            Write-Log "Adapter already restarted $restarts time(s), not restarting again." 'WARN'
        } else {
            $restarts++
            Write-Log "Adapter restart $restarts of $maxRestarts."
            [void](Restart-DisplayAdapter -Device $gpu)
            if (Test-DisplayRestored) {
                $restored = $true
                break
            }
        }
    }

    Start-Sleep -Seconds 3
}

if (-not $restored) {
    # Final grace period: give the last restart a moment to settle before giving up.
    for ($i = 0; $i -lt 5; $i++) {
        if (Test-DisplayRestored) { $restored = $true; break }
        Start-Sleep -Seconds 2
    }
}

$elapsed = [int]((Get-Date) - $started).TotalSeconds

if ($restored) {
    $final = Get-PathCounts
    Write-Log "Display restored after $attempt attempt(s) and $restarts adapter restart(s) in $elapsed s (active=$($final.Active), available=$($final.All))." 'OK'
    exit 0
}

Write-Log "Display was NOT restored after $attempt attempt(s) and $restarts adapter restart(s) in $elapsed s." 'ERROR'
Write-Log 'If this keeps happening, collect the log and open an issue with your GPU revision (REV_AE = LCD, REV_E1 = OLED).' 'ERROR'
exit 1
