# =================================================================================================
# Steam Deck: ROG Ally Graphics Driver Uninstaller
# Reverts only the Windows-side changes made by InstallDriver.ps1.
# =================================================================================================

$Host.UI.RawUI.BackgroundColor = 'Black'
$Host.UI.RawUI.ForegroundColor = 'Gray'
$ErrorActionPreference = "Stop"

try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
} catch {
    $isAdmin = $false
}

if (-not $isAdmin) {
    Write-Host "Restarting with administrative privileges..." -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = "runas"
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch { Write-Host "Elevation declined. Exiting." -ForegroundColor Red }
    exit
}

function Pause-And-Exit {
    param([int]$Code = 0)
    Write-Host ""
    Write-Host "Press any key to exit..." -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host -Prompt "Press Enter to exit" }
    exit $Code
}

function Get-PublishedDriverPackages {
    $output = & pnputil.exe /enum-drivers
    $packages = New-Object System.Collections.Generic.List[object]
    $current = @{}

    foreach ($line in $output) {
        if ($line -match '^\s*$') {
            if ($current.Count -gt 0) {
                $packages.Add([PSCustomObject]$current)
                $current = @{}
            }
            continue
        }

        if ($line -match '^\s*Published Name\s*:\s*(.+?)\s*$') { $current.PublishedName = $matches[1].Trim(); continue }
        if ($line -match '^\s*Original Name\s*:\s*(.+?)\s*$') { $current.OriginalName = $matches[1].Trim(); continue }
        if ($line -match '^\s*Provider Name\s*:\s*(.+?)\s*$') { $current.ProviderName = $matches[1].Trim(); continue }
        if ($line -match '^\s*Class Name\s*:\s*(.+?)\s*$') { $current.ClassName = $matches[1].Trim(); continue }
        if ($line -match '^\s*Signer Name\s*:\s*(.+?)\s*$') { $current.SignerName = $matches[1].Trim(); continue }
    }

    if ($current.Count -gt 0) {
        $packages.Add([PSCustomObject]$current)
    }

    return $packages
}

function Remove-CertificateBySubject {
    param(
        [string]$StorePath,
        [string]$Subject
    )

    $certs = @(Get-ChildItem -LiteralPath $StorePath -ErrorAction SilentlyContinue | Where-Object { $_.Subject -eq $Subject })
    foreach ($cert in $certs) {
        Write-Host "Removing certificate from ${StorePath}: $($cert.Thumbprint)" -ForegroundColor Gray
        Remove-Item -LiteralPath $cert.PSPath -Force -ErrorAction SilentlyContinue
    }
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Definition -Parent }
Set-Location $ScriptDir

$testCertSubject = "CN=Steam Deck Test Driver Signing"
$testSignerName = "Steam Deck Test Driver Signing"

Clear-Host
Write-Host "Steam Deck: ROG Ally Graphics Driver Uninstaller" -ForegroundColor Cyan
Write-Host ""
Write-Host "This removes only the test-signed driver packages and certificate installed by this project." -ForegroundColor Cyan
Write-Host ""

Write-Host "Finding driver packages signed by this project's test certificate..." -ForegroundColor Cyan
$packages = @(Get-PublishedDriverPackages | Where-Object {
    $_.PublishedName -and $_.SignerName -eq $testSignerName
})

if ($packages.Count -eq 0) {
    Write-Host "No matching test-signed driver packages found in Driver Store." -ForegroundColor Yellow
} else {
    foreach ($package in $packages) {
        Write-Host "Deleting $($package.PublishedName) [$($package.OriginalName)]..." -ForegroundColor Cyan
        & pnputil.exe /delete-driver $package.PublishedName /uninstall /force
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Warning: pnputil returned exit code $LASTEXITCODE for $($package.PublishedName)." -ForegroundColor Yellow
        }
    }
}

Write-Host ""
Write-Host "Removing this project's test certificate..." -ForegroundColor Cyan
Remove-CertificateBySubject -StorePath "Cert:\LocalMachine\Root" -Subject $testCertSubject
Remove-CertificateBySubject -StorePath "Cert:\LocalMachine\TrustedPublisher" -Subject $testCertSubject
Remove-CertificateBySubject -StorePath "Cert:\CurrentUser\My" -Subject $testCertSubject

Write-Host ""
Write-Host "Turning Windows test-signing mode off..." -ForegroundColor Cyan
& bcdedit.exe /set testsigning off
if ($LASTEXITCODE -ne 0) {
    Write-Host "Warning: bcdedit returned exit code $LASTEXITCODE while disabling testsigning." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "Scanning devices again..." -ForegroundColor Cyan
& pnputil.exe /scan-devices

Write-Host ""
Write-Host "Uninstall step completed." -ForegroundColor Green
Write-Host "Reboot Windows now." -ForegroundColor Yellow
Write-Host ""
Write-Host "After reboot, verify with:" -ForegroundColor Cyan
Write-Host "  pnputil /enum-devices /class Display /drivers" -ForegroundColor Gray
Write-Host ""

Pause-And-Exit
