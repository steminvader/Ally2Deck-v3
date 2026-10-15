# =================================================================================================
# Steam Deck: ROG Ally Graphics Driver Builder
# Builds a patched driver package that preserves the Microsoft WHQL signature on amdkmdag.sys
# by updating amdgcf.dat instead of patching the kernel binary, so Windows Test Mode is NOT needed.
# =================================================================================================

param(
    [switch]$NonInteractive
)

if (-not $NonInteractive) {
    try {
        $Host.UI.RawUI.BackgroundColor = 'Black'
        $Host.UI.RawUI.ForegroundColor = 'Gray'
    } catch {}
}
$ErrorActionPreference = "Stop"

try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
} catch {
    $isAdmin = $false
}

if (-not $isAdmin -and -not $NonInteractive) {
    Write-Host "Restarting with administrative privileges..." -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = "runas"
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch { Write-Host "Elevation declined. Exiting." -ForegroundColor Red }
    exit
}

function Fail {
    param([string]$Message)
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host ""
    if (-not $NonInteractive) {
        Write-Host "Press any key to exit..." -ForegroundColor Yellow
        try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host -Prompt "Press Enter to exit" }
    }
    exit 1
}

function Find-7Zip {
    $fromPath = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }

    $paths = @(
        "$env:ProgramFiles\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    )

    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) { return $path }
    }

    return $null
}

function Find-WindowsKitTool {
    param(
        [string]$ToolName
    )

    $fromPath = Get-Command $ToolName -ErrorAction SilentlyContinue
    if ($fromPath) { return $fromPath.Source }

    $kitBin = "C:\Program Files (x86)\Windows Kits\10\bin"
    if (Test-Path -LiteralPath $kitBin) {
        $found = Get-ChildItem -LiteralPath $kitBin -Recurse -Filter $ToolName -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match "\\x64\\" } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }

    return $null
}

function Get-RelativePathCompat {
    param(
        [string]$BasePath,
        [string]$FullPath
    )

    $baseUriPath = if ($BasePath.EndsWith([System.IO.Path]::DirectorySeparatorChar)) { $BasePath } else { $BasePath + [System.IO.Path]::DirectorySeparatorChar }
    $baseUri = New-Object System.Uri($baseUriPath)
    $fullUri = New-Object System.Uri($FullPath)
    return [System.Uri]::UnescapeDataString($baseUri.MakeRelativeUri($fullUri).ToString()).Replace("/", "\")
}

function Get-InfCatalogName {
    param([string]$InfPath)

    $catalogLine = Get-Content -LiteralPath $InfPath | Where-Object { $_ -match "^\s*CatalogFile(?:\.[^=]+)?\s*=" } | Select-Object -First 1
    if ($catalogLine) {
        $name = (($catalogLine -split "=", 2)[1]).Trim()
        if ($name.ToLowerInvariant().EndsWith(".cat")) { return [System.IO.Path]::GetFileName($name) }
    }

    return [System.IO.Path]::GetFileNameWithoutExtension($InfPath) + ".cat"
}

function Get-InfReleaseVersion {
    param([string]$InfPath)

    $relLine = Get-Content -LiteralPath $InfPath | Where-Object { $_ -match "^\s*HKR\s*,\s*,\s*ReleaseVersion\s*," } | Select-Object -First 1
    if ($relLine -and $relLine -match 'ReleaseVersion\s*,[^,]*,\s*"?([^"\r\n]+)"?') {
        return $matches[1].Trim()
    }

    Fail "Could not determine ReleaseVersion from $InfPath."
}

function Update-AmdGcfFile {
    param(
        [string]$GcfPath,
        [string]$ReleaseVersion
    )

    $gcfTypeSource = @"
using System;
using System.Collections.Generic;
using System.Text;

public static class AmdGcfBuilder
{
    static ulong Ror64(ulong v, int s) { return (v >> s) | (v << (64 - s)); }
    static ulong ReadU64(byte[] d, int o) { return BitConverter.ToUInt64(d, o); }
    static uint ReadU32(byte[] d, int o) { return BitConverter.ToUInt32(d, o); }
    static ushort ReadU16(byte[] d, int o) { return BitConverter.ToUInt16(d, o); }

    public static ulong ComputeHash(byte[] data, ulong seed = 0)
    {
        unchecked
        {
            ulong r15 = 0xD6D018F5UL;
            ulong rbp = 0xA2AA033BUL;
            ulong r10 = (seed + 0x62992FC1UL) * r15;
            int idx = 0;
            int n = data.Length;
            if (n >= 32)
            {
                ulong rdi = r10, rsi = r10, rbx = r10, r8 = r10;
                while (idx <= n - 32)
                {
                    ulong w0 = ReadU64(data, idx);
                    ulong w1 = ReadU64(data, idx + 8);
                    ulong w2 = ReadU64(data, idx + 16);
                    ulong w3 = ReadU64(data, idx + 24);
                    ulong rdx = w2 * 0x62992FC1UL;
                    ulong rax = w0 * r15;
                    rdi += rax;
                    rax = w1 * rbp;
                    rdi = Ror64(rdi, 0x1D);
                    rbx += rax;
                    rdi += rsi;
                    rsi += rdx;
                    rdx = w3 * 0x30BC5B29UL;
                    rbx = Ror64(rbx, 0x1D);
                    idx += 32;
                    rbx += r8;
                    rsi = Ror64(rsi, 0x1D);
                    r8 += rdx;
                    rsi += rdi;
                    r8 = Ror64(r8, 0x1D);
                    r8 += rbx;
                }
                ulong r9 = (rdi + r8) * r15 + rbx;
                r9 = Ror64(r9, 0x25) * rbp ^ rsi;
                ulong rax2 = (r9 + rbx) * rbp + rdi;
                rax2 = Ror64(rax2, 0x25) * r15 ^ r8;
                ulong r8_2 = (r9 + rdi) * r15 + rax2;
                ulong rdx2 = (rax2 + rbx) * rbp + r9;
                r8_2 = Ror64(r8_2, 0x25) * rbp;
                rdx2 = Ror64(rdx2, 0x25) * r15;
                rdx2 ^= r8_2 ^ rdi ^ rbx;
                r10 += rdx2;
            }
            if (n - idx >= 16)
            {
                ulong w0 = ReadU64(data, idx);
                ulong w1 = ReadU64(data, idx + 8);
                idx += 16;
                ulong rdx = Ror64(w0 * 0x62992FC1UL + r10, 0x1D);
                ulong r9 = rdx * 0x30BC5B29UL;
                rdx = Ror64(w1 * 0x62992FC1UL + r10, 0x1D);
                ulong r8 = rdx * 0x30BC5B29UL;
                rdx = Ror64(r9 * r15, 0x15) + r8 ^ r9;
                ulong rax = Ror64(r8 * 0x30BC5B29UL, 0x15);
                rdx = (rdx + rax) ^ r8;
                r10 += rdx;
            }
            if (n - idx >= 8)
            {
                ulong w0 = ReadU64(data, idx);
                idx += 8;
                r10 += w0 * 0x30BC5B29UL;
                r10 ^= Ror64(r10, 0x37) * rbp;
            }
            if (n - idx >= 4)
            {
                ulong w0 = ReadU32(data, idx);
                idx += 4;
                r10 += w0 * 0x30BC5B29UL;
                r10 ^= Ror64(r10, 0x1A) * rbp;
            }
            if (n - idx >= 2)
            {
                ulong w0 = ReadU16(data, idx);
                idx += 2;
                r10 += w0 * 0x30BC5B29UL;
                r10 ^= Ror64(r10, 0x30) * rbp;
            }
            if (n - idx >= 1)
            {
                ulong w0 = data[idx];
                r10 += w0 * 0x30BC5B29UL;
                r10 ^= Ror64(r10, 0x25) * rbp;
            }
            ulong rcx = (Ror64(r10, 0x1C) ^ r10) * r15;
            return Ror64(rcx, 0x1D) ^ rcx;
        }
    }

    public static byte[] PatchGcfBytes(byte[] existingGcf, string releaseVersion, ushort[] addDevIds, byte[] addRevIds)
    {
        var pairs = new List<Tuple<ushort, byte>>();
        if (existingGcf != null && existingGcf.Length >= 12)
        {
            uint existingCount = BitConverter.ToUInt32(existingGcf, 0);
            for (int i = 0; i < existingCount && (12 + i * 3 + 2) < existingGcf.Length; i++)
            {
                ushort rawWord = BitConverter.ToUInt16(existingGcf, 12 + i * 3);
                ushort devId = (ushort)(rawWord - (12 + i * 3));
                byte revId = existingGcf[12 + i * 3 + 2];
                pairs.Add(Tuple.Create(devId, revId));
            }
        }

        for (int i = 0; i < addDevIds.Length; i++)
        {
            ushort d = addDevIds[i];
            byte r = addRevIds[i];
            bool exists = false;
            foreach (var p in pairs)
            {
                if (p.Item1 == d && p.Item2 == r) { exists = true; break; }
            }
            if (!exists) pairs.Add(Tuple.Create(d, r));
        }

        // amdkmdag.sys binary-searches/scans entries in ascending order of (DeviceID, RevisionID)
        pairs.Sort((a, b) =>
        {
            int cmp = a.Item1.CompareTo(b.Item1);
            return cmp != 0 ? cmp : a.Item2.CompareTo(b.Item2);
        });

        int count = pairs.Count;
        byte[] entries = new byte[count * 3];
        for (int i = 0; i < count; i++)
        {
            ushort encodedDev = (ushort)(pairs[i].Item1 + 12 + i * 3);
            entries[i * 3] = (byte)(encodedDev & 0xFF);
            entries[i * 3 + 1] = (byte)((encodedDev >> 8) & 0xFF);
            entries[i * 3 + 2] = pairs[i].Item2;
        }

        byte[] relBytes = Encoding.ASCII.GetBytes(releaseVersion);
        byte[] hashInput = new byte[entries.Length + relBytes.Length];
        Buffer.BlockCopy(entries, 0, hashInput, 0, entries.Length);
        Buffer.BlockCopy(relBytes, 0, hashInput, entries.Length, relBytes.Length);

        ulong h = ComputeHash(hashInput, 0);

        byte[] outGcf = new byte[12 + entries.Length];
        BitConverter.GetBytes((uint)count).CopyTo(outGcf, 0);
        for (int b = 0; b < 8; b++)
        {
            outGcf[4 + b] = (byte)((h >> (56 - b * 8)) & 0xFF);
        }
        Buffer.BlockCopy(entries, 0, outGcf, 12, entries.Length);
        return outGcf;
    }
}
"@

    if (-not ("AmdGcfBuilder" -as [type])) {
        Add-Type -TypeDefinition $gcfTypeSource -ErrorAction Stop
    }

    $backupPath = "$GcfPath.bak"
    if (-not (Test-Path -LiteralPath $backupPath)) {
        Copy-Item -LiteralPath $GcfPath -Destination $backupPath -Force
    }

    $origBytes = [System.IO.File]::ReadAllBytes($backupPath)
    $beforeHex = ($origBytes | ForEach-Object { $_.ToString("X2") }) -join " "
    Write-Host "Original amdgcf.dat: $beforeHex" -ForegroundColor Yellow

    # Add Steam Deck LCD (163F rev AE), ROG Ally (163F rev AF), and Steam Deck OLED (163F rev E1)
    $devIds = [uint16[]]@(0x163F, 0x163F, 0x163F)
    $revIds = [byte[]]@(0xAE, 0xAF, 0xE1)

    $patchedBytes = [AmdGcfBuilder]::PatchGcfBytes($origBytes, $ReleaseVersion, $devIds, $revIds)
    [System.IO.File]::WriteAllBytes($GcfPath, $patchedBytes)

    $afterHex = ($patchedBytes | ForEach-Object { $_.ToString("X2") }) -join " "
    Write-Host "Patched amdgcf.dat:  $afterHex" -ForegroundColor Yellow
    Write-Host "amdgcf.dat updated for ReleaseVersion '$ReleaseVersion' (amdkmdag.sys left untouched with Microsoft WHQL signature)." -ForegroundColor Green
}

function New-CatalogWithMakeCat {
    param(
        [string]$DriverFolder,
        [string]$CatName,
        [string]$MakeCatPath
    )

    $catalogCdfPath = Join-Path $DriverFolder ([System.IO.Path]::GetFileNameWithoutExtension($CatName) + ".cdf")
    $catalogFiles = @(Get-ChildItem -LiteralPath $DriverFolder -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Extension -notin @(".cat", ".bak", ".cdf") -and
            -not $_.Name.EndsWith(".bak", [System.StringComparison]::OrdinalIgnoreCase)
        } |
        Sort-Object FullName)

    if ($catalogFiles.Count -eq 0) { Fail "No files found for catalog generation." }

    $cdfLines = New-Object System.Collections.Generic.List[string]
    $cdfLines.Add("[CatalogHeader]")
    $cdfLines.Add("Name=$CatName")
    $cdfLines.Add("PublicVersion=0x0000001")
    $cdfLines.Add("EncodingType=0x00010001")
    $cdfLines.Add("CATATTR1=0x10010001:OSAttr:2:10.0")
    $cdfLines.Add("[CatalogFiles]")

    $fileIndex = 1
    foreach ($file in $catalogFiles) {
        $relativePath = Get-RelativePathCompat -BasePath $DriverFolder -FullPath $file.FullName
        $cdfLines.Add("<hash>File$fileIndex=$relativePath")
        $fileIndex++
    }

    [System.IO.File]::WriteAllLines($catalogCdfPath, $cdfLines, [System.Text.Encoding]::ASCII)

    Push-Location $DriverFolder
    try {
        & $MakeCatPath -v $catalogCdfPath
        if ($LASTEXITCODE -ne 0) { Fail "makecat failed (exit $LASTEXITCODE)." }
    } finally {
        Pop-Location
    }
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Definition -Parent }
Set-Location $ScriptDir

$DriverExe = Join-Path $ScriptDir "AMDDriver.exe"
$ExtractRoot = Join-Path $ScriptDir "DRIVERS"
$CertPfx = Join-Path $ScriptDir "SteamDeckTestDriverCert.pfx"
$CertCer = Join-Path $ScriptDir "SteamDeckTestDriverCert.cer"
$CertName = "Steam Deck Test Driver Signing"
$CertPassword = [Guid]::NewGuid().ToString("N") + [Guid]::NewGuid().ToString("N")
$SignToolPath = Find-WindowsKitTool -ToolName "signtool.exe"
$Inf2CatPath = Find-WindowsKitTool -ToolName "inf2cat.exe"
$MakeCatPath = Find-WindowsKitTool -ToolName "makecat.exe"

if (-not $NonInteractive) { Clear-Host }
Write-Host "Steam Deck: ROG Ally Graphics Driver Builder (No Test Mode Required)" -ForegroundColor Cyan
Write-Host ""
Write-Host "This builds a patched driver package while keeping amdkmdag.sys WHQL-signed." -ForegroundColor Cyan
Write-Host "Windows Test Mode (testsigning) is NOT required." -ForegroundColor Green
Write-Host ""

if (-not (Test-Path -LiteralPath $DriverExe)) {
    Fail "AMDDriver.exe not found next to this script."
}

$SevenZip = Find-7Zip
if (-not $SevenZip) { Fail "7-Zip not found. Install 7-Zip and make sure 7z.exe is available in Program Files or PATH." }
if (-not $SignToolPath) { Fail "signtool.exe not found. Install Windows SDK Signing Tools." }
if (-not $Inf2CatPath -and -not $MakeCatPath) { Fail "Neither inf2cat.exe nor makecat.exe was found. Install Windows SDK/WDK tools." }

if (Test-Path -LiteralPath $ExtractRoot) {
    Write-Host "Removing existing DRIVERS folder..." -ForegroundColor Yellow
    Remove-Item -LiteralPath $ExtractRoot -Recurse -Force
}

New-Item -ItemType Directory -Path $ExtractRoot -Force | Out-Null
Write-Host "Extracting AMDDriver.exe..." -ForegroundColor Cyan
& $SevenZip x -y "-o$ExtractRoot" $DriverExe | Out-Null

$DisplayBase = Join-Path $ExtractRoot "Packages\Drivers\Display"
$sysMatches = @(Get-ChildItem -LiteralPath $DisplayBase -Recurse -Filter "amdkmdag.sys" -ErrorAction SilentlyContinue | Sort-Object Length -Descending)
if ($sysMatches.Count -eq 0) { Fail "amdkmdag.sys not found under $DisplayBase." }

$SysFilePath = $sysMatches[0].FullName
$SysDir = $sysMatches[0].DirectoryName
$DisplayInfFolder = $SysDir
while ($DisplayInfFolder -and -not (Get-ChildItem -LiteralPath $DisplayInfFolder -Filter "*.inf" -ErrorAction SilentlyContinue)) {
    $DisplayInfFolder = Split-Path $DisplayInfFolder -Parent
}

Write-Host "Display INF folder: $DisplayInfFolder" -ForegroundColor Green
Write-Host "Keeping unpatched WHQL-signed SYS: $SysFilePath" -ForegroundColor Green

$allInfFiles = @(Get-ChildItem -LiteralPath $DisplayInfFolder -Filter "*.inf" -ErrorAction SilentlyContinue)
$displayInfCandidates = @($allInfFiles | Where-Object {
    $content = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
    $content -match "(?im)^\s*Class\s*=\s*Display\s*$" -and
    $content -match "ati2mtag_VanGogh|VEN_1002&DEV_163F|amdkmdag\.sys"
})

if ($displayInfCandidates.Count -eq 0) { Fail "No compatible display INF found under $DisplayInfFolder." }

$InfPath = $displayInfCandidates[0].FullName
Write-Host "Using INF: $InfPath" -ForegroundColor Green

$ReleaseVersion = Get-InfReleaseVersion -InfPath $InfPath
$GcfFilePath = Join-Path $SysDir "amdgcf.dat"
if (-not (Test-Path -LiteralPath $GcfFilePath)) {
    $gcfMatches = @(Get-ChildItem -LiteralPath $DisplayInfFolder -Recurse -Filter "amdgcf.dat" -ErrorAction SilentlyContinue)
    if ($gcfMatches.Count -eq 0) { Fail "amdgcf.dat not found under $DisplayInfFolder." }
    $GcfFilePath = $gcfMatches[0].FullName
}

Update-AmdGcfFile -GcfPath $GcfFilePath -ReleaseVersion $ReleaseVersion

$steamDeckLcdHwid = '"%AMD163F.2%" = ati2mtag_VanGogh, PCI\VEN_1002&DEV_163F&SUBSYS_01231002&REV_AE'
$steamDeckOledHwid = '"%AMD163F.2%" = ati2mtag_VanGogh, PCI\VEN_1002&DEV_163F&SUBSYS_01231002&REV_E1'
$steamDeckString = 'AMD163F.2 = "AMD Radeon(TM) Graphics"'

foreach ($hwidLine in @($steamDeckOledHwid, $steamDeckLcdHwid)) {
    $infLines = Get-Content -LiteralPath $InfPath
    if ($infLines -notcontains $hwidLine) {
        $anchorIndex = -1
        for ($i = 0; $i -lt $infLines.Count; $i++) {
            if ($infLines[$i] -match [regex]::Escape("ati2mtag_VanGogh") -and $infLines[$i] -match "VEN_1002&DEV_163F") {
                $anchorIndex = $i
                break
            }
        }
        if ($anchorIndex -lt 0) { Fail "No VanGogh DEV_163F entry found in $InfPath." }

        $afterAnchor = if ($anchorIndex -lt $infLines.Count - 1) { $infLines[($anchorIndex + 1)..($infLines.Count - 1)] } else { @() }
        Set-Content -LiteralPath $InfPath -Value ($infLines[0..$anchorIndex] + $hwidLine + $afterAnchor) -Encoding ASCII
        Write-Host "Inserted Steam Deck hardware ID: $hwidLine" -ForegroundColor Green
    }
}

$infLines = Get-Content -LiteralPath $InfPath
if ($infLines -notcontains $steamDeckString) {
    $strAnchorIndex = -1
    for ($i = 0; $i -lt $infLines.Count; $i++) {
        if ($infLines[$i] -match "^\s*AMD163F\.1\s*=") {
            $strAnchorIndex = $i
            break
        }
    }
    if ($strAnchorIndex -ge 0) {
        $afterStrAnchor = if ($strAnchorIndex -lt $infLines.Count - 1) { $infLines[($strAnchorIndex + 1)..($infLines.Count - 1)] } else { @() }
        Set-Content -LiteralPath $InfPath -Value ($infLines[0..$strAnchorIndex] + $steamDeckString + $afterStrAnchor) -Encoding ASCII
        Write-Host "Inserted Steam Deck display string." -ForegroundColor Green
    }
}

# Also add Steam Deck HWIDs to amduw23e.inf (extension INF) if present
$extInfPath = Join-Path $DisplayInfFolder "amduw23e.inf"
$extCatFile = $null
if (Test-Path -LiteralPath $extInfPath) {
    foreach ($hwidLine in @($steamDeckOledHwid, $steamDeckLcdHwid)) {
        $extLines = Get-Content -LiteralPath $extInfPath
        if ($extLines -notcontains $hwidLine) {
            $anchorIdx = -1
            for ($i = 0; $i -lt $extLines.Count; $i++) {
                if ($extLines[$i] -match [regex]::Escape("ati2mtag_VanGogh") -and $extLines[$i] -match "VEN_1002&DEV_163F") {
                    $anchorIdx = $i
                    break
                }
            }
            if ($anchorIdx -ge 0) {
                $afterExt = if ($anchorIdx -lt $extLines.Count - 1) { $extLines[($anchorIdx + 1)..($extLines.Count - 1)] } else { @() }
                Set-Content -LiteralPath $extInfPath -Value ($extLines[0..$anchorIdx] + $hwidLine + $afterExt) -Encoding ASCII
            }
        }
    }
    $extLines = Get-Content -LiteralPath $extInfPath
    if ($extLines -notcontains $steamDeckString) {
        $strIdx = -1
        for ($i = 0; $i -lt $extLines.Count; $i++) {
            if ($extLines[$i] -match "^\s*AMD163F\.1\s*=") {
                $strIdx = $i
                break
            }
        }
        if ($strIdx -ge 0) {
            $afterStr = if ($strIdx -lt $extLines.Count - 1) { $extLines[($strIdx + 1)..($extLines.Count - 1)] } else { @() }
            Set-Content -LiteralPath $extInfPath -Value ($extLines[0..$strIdx] + $steamDeckString + $afterStr) -Encoding ASCII
        }
    }
    $extCatName = Get-InfCatalogName -InfPath $extInfPath
    $extCatFile = Join-Path $DisplayInfFolder $extCatName
    if (Test-Path -LiteralPath $extCatFile) {
        Move-Item -LiteralPath $extCatFile -Destination "$extCatFile.bak" -Force
    }
}

Write-Host "Creating or reusing package catalog certificate..." -ForegroundColor Cyan
$cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert -ErrorAction SilentlyContinue |
    Where-Object { $_.Subject -eq "CN=$CertName" } |
    Select-Object -First 1

if (-not $cert) {
    $cert = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject "CN=$CertName" `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -KeyExportPolicy Exportable `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -NotAfter (Get-Date).AddYears(10)
}

$securePassword = ConvertTo-SecureString -String $CertPassword -AsPlainText -Force
Export-PfxCertificate -Cert $cert -FilePath $CertPfx -Password $securePassword -Force | Out-Null
Export-Certificate -Cert $cert -FilePath $CertCer -Force | Out-Null

Write-Host "Temporary PFX: $CertPfx" -ForegroundColor Green
Write-Host "CER: $CertCer" -ForegroundColor Green

$catBaseName = Get-InfCatalogName -InfPath $InfPath
$CatFile = Join-Path $DisplayInfFolder $catBaseName

if (Test-Path -LiteralPath $CatFile) {
    Move-Item -LiteralPath $CatFile -Destination "$CatFile.bak" -Force
}

Write-Host "Generating driver catalog..." -ForegroundColor Cyan
if ($Inf2CatPath) {
    & $Inf2CatPath "/driver:$DisplayInfFolder" "/os:10_X64"
    if ($LASTEXITCODE -ne 0) { Fail "inf2cat failed (exit $LASTEXITCODE)." }
} else {
    New-CatalogWithMakeCat -DriverFolder $DisplayInfFolder -CatName $catBaseName -MakeCatPath $MakeCatPath
}

if (-not (Test-Path -LiteralPath $CatFile)) {
    $generatedCat = Get-ChildItem -LiteralPath $DisplayInfFolder -Filter "*.cat" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($generatedCat) { $CatFile = $generatedCat.FullName } else { Fail "Catalog generation completed but no .cat file was found." }
}

Write-Host "Signing CAT with package certificate..." -ForegroundColor Cyan
& $SignToolPath sign /fd SHA256 /f $CertPfx /p $CertPassword $CatFile
if ($LASTEXITCODE -ne 0) { Fail "Catalog signing failed (exit $LASTEXITCODE)." }

# Regenerate and sign extension catalog if amduw23e.inf was updated
if ($extCatFile) {
    if (-not (Test-Path -LiteralPath $extCatFile)) {
        Copy-Item -LiteralPath $CatFile -Destination $extCatFile -Force
    }
    & $SignToolPath sign /fd SHA256 /f $CertPfx /p $CertPassword $extCatFile | Out-Null
}

Remove-Item -LiteralPath $CertPfx -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Build complete (WHQL signature on amdkmdag.sys preserved, no Test Mode needed)." -ForegroundColor Green
Write-Host "Next: run InstallDriver.ps1 on the Steam Deck Windows install." -ForegroundColor Yellow
Write-Host ""
if (-not $NonInteractive) {
    Write-Host "Press any key to exit..." -ForegroundColor DarkGray
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host -Prompt "Press Enter to exit" }
}
