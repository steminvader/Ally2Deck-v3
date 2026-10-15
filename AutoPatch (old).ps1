# =================================================================================================
# Steam Deck: ROG XBOX ALLY Graphics Driver Patcher
# =================================================================================================

# -------------------------
# 1. ENVIRONMENT SETUP
# -------------------------

# Force black background
$Host.UI.RawUI.BackgroundColor = 'Black'
$Host.UI.RawUI.ForegroundColor = 'Gray'

# Auto-elevate
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

$ErrorActionPreference = "Stop"

# Helper functions
function Fail {
    param([string]$Message)
    Write-Host ""
    Write-Host "ERROR: $Message" -ForegroundColor Red
    Write-Host ""
    Write-Host "Press any key to exit..." -ForegroundColor Yellow
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host -Prompt "Press Enter to exit" }
    Exit 1
}

function ShowUserDownloadHint {
    param(
        [string]$ExpectedName = "AMDDriver.exe",
        [string]$DownloadUrl = "https://rog.asus.com/gaming-handhelds/rog-ally/rog-xbox-ally-2025/helpdesk_download/"
    )
    Write-Host ""
    Write-Host "Driver EXE not found." -ForegroundColor Yellow
    Write-Host "Please download the official AMD driver package from the vendor:" -ForegroundColor Cyan
    Write-Host $DownloadUrl -ForegroundColor Cyan
    Write-Host ""
    Write-Host "After downloading, place the file in this script's folder and rename it to:" -ForegroundColor Cyan
    Write-Host "  $ExpectedName" -ForegroundColor Green
    Write-Host ""
    Write-Host "Press any key after you've placed and renamed the file, or Ctrl+C to cancel." -ForegroundColor Yellow
    try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host -Prompt "Press Enter to continue" }
}

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path $MyInvocation.MyCommand.Definition -Parent }
Set-Location $ScriptDir

$DriverExe = Join-Path $ScriptDir "AMDDriver.exe"
$ExtractRoot = Join-Path $ScriptDir "DRIVERS"
$SignToolPath = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe"
$SdkFwlink = "https://go.microsoft.com/fwlink/?linkid=2346012"
$InstallerName = "winsdksetup.exe"
$InstallerTemp = Join-Path $env:TEMP $InstallerName
$InstallerLocal = Join-Path $ScriptDir $InstallerName

$CertPfx = Join-Path $ScriptDir "SteamDeckTestDriverCert.pfx"
$CertCer = Join-Path $ScriptDir "SteamDeckTestDriverCert.cer"
$PasswordTxt = Join-Path $ScriptDir "password.txt"

# -------------------------
# 2. INTRO
# -------------------------
$SteamDeckASCII = @"
                                           
                :@@%*=-.                   
                :@@@@@@@@#-.               
                :@@@@@@@@@@@#.             
                :%@@@@@@@@@@@@#.           
                    .-#@@@@@@@@@=.         
            .:-====:.  .-%@@@@@@@*.        
         .-+++++++++++=.  =@@@@@@@+        
        :+++++++++++++++-. -@@@@@@@-       
       :+++++++++++++++++-. =@@@@@@*       
       =++++++++++++++++++. .%@@@@@%       
       +++++++++++++++++++: .%@@@@@%       
       =++++++++++++++++++. .%@@@@@%       
       :+++++++++++++++++=. =@@@@@@*       
        :+++++++++++++++-. -@@@@@@@-       
         .-+++++++++++=.  =@@@@@@@+        
            .:=====-.  .:%@@@@@@@*.        
                    .-*@@@@@@@@@+.         
                :%@@@@@@@@@@@@#.           
                :@@@@@@@@@@@%.             
                :@@@@@@@@#=.               
                :@@%#+-.                   
                                           
"@

Clear-Host
Write-Host $SteamDeckASCII -ForegroundColor Cyan
Write-Host ""
Write-Host ""
Write-Host "Steam Deck: ROG XBOX ALLY Graphics Driver Patcher" -ForegroundColor Cyan
Write-Host ""
Write-Host ""
Write-Host "This script will automatically patch and sign the AMD Graphics Driver from the ROG XBOX ALLY to work on the Steam Deck." -ForegroundColor Cyan
Write-Host "Before we start, you must manually download the driver from the ASUS website." -ForegroundColor Cyan
Write-Host "https://rog.asus.com/gaming-handhelds/rog-ally/rog-xbox-ally-2025/helpdesk_download/" -ForegroundColor Yellow
Write-Host "This script was made for personal use, with the help of Copilot." -ForegroundColor Cyan
Write-Host ""
Write-Host ""
Write-Host "I am not responsible for any issues caused by using this script, such as:" -ForegroundColor Cyan
Write-Host "- You caught a virus." -ForegroundColor Cyan
Write-Host "- Your Steam Deck stopped working." -ForegroundColor Cyan
Write-Host "- Your house burned down." -ForegroundColor Cyan
Write-Host ""
Write-Host ""
Write-Host "If you are aware of the risks, press any key to continue." -ForegroundColor Cyan
try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host -Prompt "Press Enter to continue" }

# -------------------------
# 3. DEPENDENCY CHECKS AND INSTALL
# -------------------------
function Test-7Zip {
    try {
        if (Get-Command 7z -ErrorAction SilentlyContinue) { return $true }
        $paths = @("$env:ProgramFiles\7-Zip\7z.exe","$env:ProgramFiles(x86)\7-Zip\7z.exe")
        foreach ($p in $paths) { if (Test-Path $p) { return $true } }
        return $false
    } catch { return $false }
}

Write-Host "Checking dependencies..." -ForegroundColor Cyan

if (-not (Test-7Zip)) {
    Write-Host "7-Zip not found. Installing via winget..." -ForegroundColor Yellow
    try {
        Start-Process "winget" -ArgumentList "install","-e","--id","7zip.7zip" -Wait -NoNewWindow -ErrorAction Stop
    } catch { Write-Host "winget install failed or not available. Please install 7-Zip manually and re-run." -ForegroundColor Red; Fail "7-Zip missing." }
    if (-not (Test-7Zip)) { Fail "7-Zip installation failed." }
    Write-Host "7-Zip installed." -ForegroundColor Green
} else { Write-Host "7-Zip detected." -ForegroundColor Green }

if (-not (Test-Path -LiteralPath $SignToolPath)) {
    Write-Host "signtool not found. Attempting to download Windows SDK Signing Tools..." -ForegroundColor Yellow
    $downloadOk = $false
    for ($i=1; $i -le 3; $i++) {
        Write-Host "Download attempt $i of 3..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest $SdkFwlink -OutFile $InstallerTemp -UseBasicParsing -ErrorAction Stop
            if ((Get-Item $InstallerTemp).Length -gt 10240) { $downloadOk = $true; break }
        } catch { Start-Sleep -Seconds 2 }
    }
    if (-not $downloadOk) { Write-Host "Failed to download SDK installer. Please install Windows SDK Signing Tools manually." -ForegroundColor Red; Fail "Signing tools missing." }
    Move-Item $InstallerTemp $InstallerLocal -Force -ErrorAction SilentlyContinue
    Write-Host "Installing SDK Signing Tools..." -ForegroundColor Cyan
    try {
        Start-Process $InstallerLocal -ArgumentList "/quiet","/norestart","/features","OptionId.SigningTools" -Verb RunAs -Wait -ErrorAction Stop
    } catch { Write-Host "SDK installer failed. Please install manually." -ForegroundColor Red; Fail "SDK install failed." }
    if (-not (Test-Path -LiteralPath $SignToolPath)) { Fail "Signing Tools still missing after install." }
    Write-Host "signtool installed." -ForegroundColor Green
} else { Write-Host "signtool detected." -ForegroundColor Green }

# -------------------------
# 4. EXE HELPER: ENSURE AMDDRIVER.EXE PRESENT
# -------------------------
if (-not (Test-Path -LiteralPath $DriverExe)) {
    ShowUserDownloadHint -ExpectedName "AMDDriver.exe" -DownloadUrl "https://rog.asus.com/gaming-handhelds/rog-ally/rog-xbox-ally-2025/helpdesk_download/"
    if (-not (Test-Path -LiteralPath $DriverExe)) { Fail "AMDDriver.exe still not found in script folder." }
}

# -------------------------
# 5. EXTRACTION HELPERS
# -------------------------
function Find7z {
    $c = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $p1 = Join-Path $env:ProgramFiles "7-Zip\7z.exe"
    if (Test-Path $p1) { return $p1 }
    $p2 = Join-Path ${env:ProgramFiles(x86)} "7-Zip\7z.exe"
    if (Test-Path $p2) { return $p2 }
    return $null
}

$SevenZip = Find7z
if (-not $SevenZip) { Fail "7z.exe not found after install." }

# prepare output folder
if (Test-Path -LiteralPath $ExtractRoot) {
    Write-Host "Removing existing DRIVERS folder..." -ForegroundColor Yellow
    try { Remove-Item -LiteralPath $ExtractRoot -Recurse -Force -ErrorAction Stop } catch { Fail "Failed to remove existing DRIVERS folder: $($_.Exception.Message)" }
}
try { New-Item -ItemType Directory -Path $ExtractRoot -ErrorAction Stop | Out-Null } catch { Fail "Failed to create DRIVERS folder: $($_.Exception.Message)" }

Write-Host "Extracting driver EXE to $ExtractRoot ..." -ForegroundColor Cyan
try { & $SevenZip x -y ("-o{0}" -f $ExtractRoot) $DriverExe | Out-Null } catch { Fail "Extraction failed: $($_.Exception.Message)" }

# -------------------------
# 6. PATCH
# -------------------------
# Auto-discover the display INF folder (search anywhere under Packages\Drivers\Display)
$DisplayBase = Join-Path $ExtractRoot "Packages\Drivers\Display"
Write-Host "Searching for amdkmdag.sys under $DisplayBase ..." -ForegroundColor Cyan
$sysMatches = @(Get-ChildItem -LiteralPath $DisplayBase -Recurse -Filter "amdkmdag.sys" -ErrorAction SilentlyContinue)
if ($sysMatches.Count -eq 0) { Fail "amdkmdag.sys not found anywhere under $DisplayBase." }
$DisplayInfFolder = $sysMatches[0].DirectoryName
# Walk up until we find the folder that directly contains .inf files
while ($DisplayInfFolder -and -not (Get-ChildItem -LiteralPath $DisplayInfFolder -Filter "*.inf" -ErrorAction SilentlyContinue)) {
    $DisplayInfFolder = Split-Path $DisplayInfFolder -Parent
}
Write-Host "Display INF folder: $DisplayInfFolder" -ForegroundColor Green
if ($sysMatches.Count -gt 1) {
    Write-Host "Multiple amdkmdag.sys found - picking the largest (most likely the main driver):" -ForegroundColor Yellow
    $sysMatches | ForEach-Object { Write-Host "  $($_.FullName) ($($_.Length) bytes)" -ForegroundColor Gray }
    $sysMatches = @($sysMatches | Sort-Object Length -Descending)
}
$path = $sysMatches[0].FullName
Write-Host "Using: $path" -ForegroundColor Green

$backupPath = $path + ".bak"
$offset = 0x56550

try { Copy-Item -LiteralPath $path -Destination $backupPath -Force; Write-Host "Backup created: $backupPath" -ForegroundColor Green } catch { Fail "Failed to create backup: $($_.Exception.Message)" }

try { $bytes = [System.IO.File]::ReadAllBytes($path) } catch { Fail "Failed to read file bytes: $($_.Exception.Message)" }

try { $before = $bytes[$offset..($offset+4)] | ForEach-Object { $_.ToString('X2') }; Write-Host "Before patch:" ($before -join ' ') -ForegroundColor Yellow } catch { Write-Host "Unable to display before bytes (index out of range)." -ForegroundColor Yellow }

$patch = @(0x31,0xC0,0xC3,0x90,0x90)
for ($i = 0; $i -lt $patch.Length; $i++) { $bytes[$offset + $i] = $patch[$i] }

try { $after = $bytes[$offset..($offset+4)] | ForEach-Object { $_.ToString('X2') }; Write-Host "After patch:" ($after -join ' ') -ForegroundColor Yellow } catch { Write-Host "Unable to display after bytes (index out of range)." -ForegroundColor Yellow }

try { [System.IO.File]::WriteAllBytes($path, $bytes); Write-Host "Patch applied successfully!" -ForegroundColor Green } catch { Fail "Failed to write patched file: $($_.Exception.Message)" }

# -------------------------
# 7. INF TWEAK
# -------------------------
# Auto-discover the display INF (prefer amduw23e.inf, fall back to any .inf with DEV_163F entries)
Write-Host "Searching for display INF under $DisplayInfFolder ..." -ForegroundColor Cyan
$SteamDeckLine = '"%AMD163F.2%" = ati2mtag_VanGogh, PCI\VEN_1002&DEV_163F&SUBSYS_01231002&REV_AE'

# Find all .inf files that reference VanGogh or DEV_163F
$infCandidates = @(Get-ChildItem -LiteralPath $DisplayInfFolder -Filter "*.inf" -ErrorAction SilentlyContinue |
    Where-Object { (Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue) -match "ati2mtag_VanGogh|VEN_1002&DEV_163F" })
if ($infCandidates.Count -eq 0) { Fail "No compatible display INF found under $DisplayInfFolder." }

# Prefer amduw23e.inf if present, otherwise use first match
$preferred = $infCandidates | Where-Object { $_.Name -eq "amduw23e.inf" } | Select-Object -First 1
$InfFile = if ($preferred) { $preferred } else { $infCandidates[0] }
$InfPath = $InfFile.FullName
Write-Host "Using INF: $InfPath" -ForegroundColor Green

$infLines = Get-Content -LiteralPath $InfPath
if ($infLines -contains $SteamDeckLine) {
    Write-Host "Steam Deck ID already present in INF." -ForegroundColor Yellow
} else {
    # Find the first VEN_1002&DEV_163F VanGogh line to use as anchor
    $baseIndex = -1
    for ($i = 0; $i -lt $infLines.Count; $i++) {
        if ($infLines[$i] -match [regex]::Escape("ati2mtag_VanGogh") -and $infLines[$i] -match "VEN_1002&DEV_163F") {
            $baseIndex = $i; break
        }
    }
    if ($baseIndex -lt 0) { Fail "No VEN_1002&DEV_163F VanGogh entry found in $InfPath." }
    Write-Host "Anchor line found at index ${baseIndex}: $($infLines[$baseIndex])" -ForegroundColor Gray
    $before = $infLines[0..$baseIndex]
    $after  = if ($baseIndex -lt $infLines.Count - 1) { $infLines[($baseIndex + 1)..($infLines.Count - 1)] } else { @() }
    $newLines = $before + $SteamDeckLine + $after
    Set-Content -LiteralPath $InfPath -Value $newLines -Encoding ASCII
    Write-Host "Inserted Steam Deck hardware ID into INF." -ForegroundColor Green
}

# Add AMD163F.2 string entry if missing (required for device name resolution)
$infLines = Get-Content -LiteralPath $InfPath
$StringKey = 'AMD163F.2 = "AMD Radeon(TM) Graphics"'
$StringAnchor = 'AMD163F.1 = "AMD Radeon(TM) Graphics"'
if ($infLines -contains $StringKey) {
    Write-Host "AMD163F.2 string already present." -ForegroundColor Yellow
} else {
    $strIndex = -1
    for ($i = 0; $i -lt $infLines.Count; $i++) {
        if ($infLines[$i] -match [regex]::Escape("AMD163F.1")) { $strIndex = $i; break }
    }
    if ($strIndex -lt 0) { Write-Host "Warning: AMD163F.1 string anchor not found, skipping string insert." -ForegroundColor Yellow }
    else {
        $sBefore = $infLines[0..$strIndex]
        $sAfter  = if ($strIndex -lt $infLines.Count - 1) { $infLines[($strIndex + 1)..($infLines.Count - 1)] } else { @() }
        $newLines = $sBefore + $StringKey + $sAfter
        Set-Content -LiteralPath $InfPath -Value $newLines -Encoding ASCII
        Write-Host "Inserted AMD163F.2 string entry into INF." -ForegroundColor Green
    }
}

# -------------------------
# 8. CERTIFICATE CREATION AND SIGNING
# -------------------------
Write-Host "Creating or reusing test certificate..." -ForegroundColor Cyan
$CertName = "AMD Driver Signing Certificate"
$CertPassword = "DriverSign123!"

# Use paths already discovered in sections 6 and 7
$DriverFolder = $DisplayInfFolder
$SysFile = $path

# Auto-discover the matching .cat (same base name as INF, fall back to first .cat in folder)
$catBaseName = [System.IO.Path]::GetFileNameWithoutExtension($InfPath) + ".cat"
$catPreferred = Join-Path $DriverFolder $catBaseName
if (Test-Path -LiteralPath $catPreferred) {
    $CatFile = $catPreferred
} else {
    $catFallback = Get-ChildItem -LiteralPath $DriverFolder -Filter "*.cat" -ErrorAction SilentlyContinue | Select-Object -First 1
    $CatFile = if ($catFallback) { $catFallback.FullName } else { $catPreferred }
}
Write-Host "Using CAT: $CatFile" -ForegroundColor Green

# Export certificate artifacts next to the script (not inside DRIVERS)
$CertExportPath   = Join-Path $ScriptDir 'DriverCert.pfx'
$CertCerPath      = [System.IO.Path]::ChangeExtension($CertExportPath, '.cer')
$PasswordTxtPath  = Join-Path $ScriptDir 'password.txt'


try { $existing = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -like "*$CertName*" } | Select-Object -First 1 } catch { $existing = $null }
if (-not $existing) {
    $existing = New-SelfSignedCertificate `
        -Type CodeSigningCert `
        -Subject "CN=$CertName" `
        -KeyUsage DigitalSignature `
        -KeyAlgorithm RSA `
        -KeyLength 2048 `
        -KeyExportPolicy Exportable `
        -CertStoreLocation "Cert:\CurrentUser\My" `
        -NotAfter (Get-Date).AddYears(5)
    Write-Host "Certificate created" -ForegroundColor Green
} else {
    Write-Host "Using existing certificate" -ForegroundColor Green
}

Write-Host "[Step 2] Exporting PFX, CER, and password.txt..." -ForegroundColor Cyan
try {
    $secPwd = ConvertTo-SecureString -String $CertPassword -AsPlainText -Force
    Export-PfxCertificate -Cert $existing -FilePath $CertExportPath -Password $secPwd -Force | Out-Null

    $CertCerPath = [System.IO.Path]::ChangeExtension($CertExportPath, '.cer')
    Export-Certificate -Cert $existing -FilePath $CertCerPath -Force | Out-Null

    $PasswordTxtPath = Join-Path (Split-Path $CertExportPath -Parent) 'password.txt'
    $CertPassword | Out-File -FilePath $PasswordTxtPath -Encoding ASCII -Force

    Write-Host "Exported PFX to: $CertExportPath" -ForegroundColor Green
    Write-Host "Exported CER to: $CertCerPath" -ForegroundColor Green
    Write-Host "Wrote password to: $PasswordTxtPath" -ForegroundColor Green
} catch { Fail "Failed to export certificate artifacts: $($_.Exception.Message)" }

Write-Host "[Step 3] Installing certificate to trust stores..." -ForegroundColor Cyan
try {
    $RootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
    $RootStore.Open("ReadWrite")
    $RootStore.Add($existing)
    $RootStore.Close()

    $PublisherStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPublisher", "LocalMachine")
    $PublisherStore.Open("ReadWrite")
    $PublisherStore.Add($existing)
    $PublisherStore.Close()
    Write-Host "Installed certificate to Root and TrustedPublisher stores." -ForegroundColor Green
} catch { Write-Host "Warning: failed to install certificate to LocalMachine stores: $($_.Exception.Message)" -ForegroundColor Yellow }

Write-Host "[Step 4] Removing original catalog file..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $CatFile) {
    $CatBackup = "$CatFile.bak"
    if (-not (Test-Path -LiteralPath $CatBackup)) {
        Move-Item -LiteralPath $CatFile -Destination $CatBackup -Force
        Write-Host "Catalog backed up and removed" -ForegroundColor Green
    } else {
        Remove-Item -LiteralPath $CatFile -Force -ErrorAction SilentlyContinue
        Write-Host "Catalog removed" -ForegroundColor Green
    }
} else {
    Write-Host "No existing catalog found at $CatFile (continuing)" -ForegroundColor Yellow
}

Write-Host "[Step 5] Signing amdkmdag.sys..." -ForegroundColor Cyan
$SignTool = $SignToolPath
if (-not (Test-Path -LiteralPath $SignTool)) {
    Write-Host "signtool not found at $SignTool. Attempting to use 'signtool' from PATH." -ForegroundColor Yellow
    $SignTool = "signtool"
}

& $SignTool sign /fd SHA256 /f $CertExportPath /p $CertPassword /tr http://timestamp.digicert.com /td SHA256 $SysFile
if ($LASTEXITCODE -eq 0) {
    Write-Host "Signed successfully!" -ForegroundColor Green
} else {
    Fail "Signing failed (signtool returned $LASTEXITCODE)."
}

Write-Host "[Step 6] Verifying signature..." -ForegroundColor Cyan
& $SignTool verify /pa $SysFile

Write-Host "[Step 7] Enabling test signing mode..." -ForegroundColor Cyan
try {
    bcdedit /set testsigning on | Out-Null
    Write-Host "Test signing mode enabled (may require reboot)." -ForegroundColor Green
} catch {
    Write-Host "Failed to enable test signing mode: $($_.Exception.Message)" -ForegroundColor Yellow
}

# -------------------------
# 9. SUCCESS MESSAGE
# -------------------------
Write-Host ""
Write-Host "ALL DONE. PFX, CER, and password.txt are in: $(Split-Path $CertExportPath -Parent)" -ForegroundColor Cyan
Write-Host ""
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "Disable driver signature enforcement for next boot" -ForegroundColor Cyan
Write-Host "Device Manager -> AMD Radeon Graphics" -ForegroundColor Cyan
Write-Host "Right-click -> Update driver" -ForegroundColor Cyan
Write-Host "Browse my computer -> Let me pick" -ForegroundColor Cyan
Write-Host "Have Disk -> Browse to:" -ForegroundColor Cyan
Write-Host $InfPath -ForegroundColor Green
Write-Host "Reboot" -ForegroundColor Cyan
Write-Host ""
Write-Host "Press any key to exit..." -ForegroundColor Yellow
try { $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown") } catch { Read-Host -Prompt "Press Enter to exit" }
