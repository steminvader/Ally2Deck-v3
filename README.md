# Ally2Deck-v3 (No Test Mode / WHQL-Preserved Edition)

**Ally2Deck-v3** patches the **ASUS ROG Xbox Ally AMD Radeon Graphics Driver** so that it installs and runs natively on the **Steam Deck (LCD & OLED)** on Windows **without requiring Windows Test Mode (`testsigning`) or disabling Secure Boot**.

Because the kernel driver (`amdkmdag.sys`) remains 100% untouched and retains its original **Microsoft Windows Hardware Compatibility Publisher (WHQL)** kernel signature, anti-cheat systems (Easy Anti-Cheat, BattlEye, Ricochet, Vanguard, etc.) and Secure Boot work normally.

---

## What Changed in v3?

1. **No Windows Test Mode (`testsigning`) Required**:
   - Previous versions (`ally2deck` / `ally2deckV2`) binary-patched `amdkmdag.sys` (replacing `33 C0 89 43 04` with `B0 01 89 43 04`) to force the driver's hardware whitelist check to return `true`. Modifying a single byte of `amdkmdag.sys` invalidated Microsoft's embedded WHQL signature, forcing Windows into `testsigning` mode and breaking Secure Boot and anti-cheat games.
   - **Ally2Deck-v3 leaves `amdkmdag.sys` completely untouched**, preserving all 3 embedded Authenticode / Microsoft WHQL signatures.

2. **`amdgcf.dat` Whitelist & 64-Bit Integrity Hash Reconstruction**:
   - Instead of patching code inside `amdkmdag.sys`, `BuildDriver.ps1` now reconstructs the external GCF hardware whitelist file (`amdgcf.dat`) with the Steam Deck's VanGogh GPU revisions and recalculates the exact 64-bit integrity hash that `amdkmdag.sys` verifies at boot.

3. **Full Steam Deck LCD & OLED Support**:
   - Adds both **Steam Deck LCD** (`PCI\VEN_1002&DEV_163F&SUBSYS_01231002&REV_AE`) and **Steam Deck OLED** (`PCI\VEN_1002&DEV_163F&SUBSYS_01231002&REV_E1`) hardware IDs into both the main display INF (`u0420842.inf`) and extension INF (`amduw23e.inf`), as well as `amdgcf.dat`.
   - `InstallDriver.ps1` automatically detects whether it is running on an LCD (`REV_AE`) or OLED (`REV_E1`) Steam Deck and binds the matching hardware ID.

4. **Automatic Test Mode Cleanup**:
   - `InstallDriver.ps1` automatically turns `testsigning` **OFF** (`bcdedit /set testsigning off`) so there is no desktop watermark and no test-signing security downgrade.

---

## How It Works Under the Hood

When `amdkmdag.sys` initializes on Windows, it runs an internal GCF validation routine (`0x140056510`) to check whether the detected PCI Device ID and Revision ID are authorized for that OEM driver package:

1. **Reading `amdgcf.dat`**:
   The driver loads `\SystemRoot\System32\DriverStore\FileRepository\<inf_folder>\<bin_folder>\amdgcf.dat`.
   The binary format of `amdgcf.dat` is:
   - **Bytes `0x00..0x03`** (`uint32` little-endian): Number of device entries (`N`).
   - **Bytes `0x04..0x0B`** (`uint64` big-endian): 64-bit custom integrity hash over the encoded entries + the driver's `ReleaseVersion` registry string.
   - **Bytes `0x0C..`** (`N × 3` bytes): Sorted array of 3-byte records, where each record at index `i` (byte offset `offset = 12 + i * 3`) stores:
     - `uint16` little-endian: `EncodedDeviceID = DeviceID + offset`
     - `uint8`: `RevisionID`

2. **Computing the 64-Bit GCF Hash**:
   `amdkmdag.sys` concatenates the raw `N × 3` encoded entry bytes with the ASCII bytes of the INF's `ReleaseVersion` string (for example, `25.10.25.27-251031a-420842C-Asus`) and hashes the buffer using AMD's custom 64-bit multiply-rotate hash function (`0x1400566A0`, using primes `0xD6D018F5`, `0xA2AA033B`, `0x62992FC1`, and `0x30BC5B29`).
   - In the stock ROG Xbox Ally driver (`V32.0.21025.27003`), `amdgcf.dat` only contains 1 entry for `DEV_163F` Revision `0xAF`:
     `01 00 00 00 15 E9 DC 87 F2 55 05 6A 4B 16 AF`
   - `BuildDriver.ps1` embeds `AmdGcfBuilder` (an exact C# implementation of `0x1400566A0`), inserts the Steam Deck VanGogh revisions (`0xAE`, `0xAF`, `0xE1`) in ascending order, and writes the new valid `amdgcf.dat`:
     `03 00 00 00 7F 32 DF 19 1F 7F E2 B1 4B 16 AE 4E 16 AF 51 16 E1`

3. **Preserving Kernel WHQL Enforcement**:
   - Windows Kernel Mode Code Signing (KMCS) requires `.sys` kernel drivers to have a valid Microsoft WHQL signature when Secure Boot is enabled and `testsigning` is off. Because `amdkmdag.sys` is never modified, its embedded Microsoft WHQL signature passes KMCS verification directly.
   - Windows PnP package installation (`pnputil` / `UpdateDriverForPlugAndPlayDevices`) verifies the INF and `amdgcf.dat` against the `.cat` catalog file in User Mode. By regenerating the `.cat` file (`inf2cat` / `makecat`) and signing the catalog with a locally trusted certificate (`LocalMachine\Root` and `LocalMachine\TrustedPublisher`), Windows PnP accepts the modified INF and `amdgcf.dat` while the kernel loads the genuine WHQL-signed `amdkmdag.sys`.

---

## Requirements

- **Windows 10 / 11 (64-bit)** on Steam Deck LCD or Steam Deck OLED
- **[7-Zip](https://www.7-zip.org/)** installed (`7z.exe` in `Program Files` or `PATH`)
- **Windows SDK Signing Tools** (`signtool.exe` and `inf2cat.exe` or `makecat.exe` under `C:\Program Files (x86)\Windows Kits\10\bin\`)
- **ROG Xbox Ally AMD Graphics Driver** installer downloaded from the [ASUS ROG Xbox Ally Driver Page](https://rog.asus.com/gaming-handhelds/rog-ally/rog-xbox-ally-2025/helpdesk_download/)
  - *Recommended version*: `V32.0.21025.27003` (GPU video encoder works in OBS)

---

## How To Use

1. Clone or download this repository (`BuildDriver.ps1`, `InstallDriver.ps1`, `UninstallDriver.ps1`, `Run_Installer_Admin.bat`).
2. Download the AMD Graphics Driver from the [ASUS ROG Xbox Ally Driver Page](https://rog.asus.com/gaming-handhelds/rog-ally/rog-xbox-ally-2025/helpdesk_download/).
3. Place the downloaded driver installer in the same folder as the scripts and rename it to **`AMDDriver.exe`**.
4. Right-click **`BuildDriver.ps1`** -> **Run with PowerShell**:
   - Extracts `AMDDriver.exe` into `DRIVERS\`
   - Patches `amdgcf.dat` with the Steam Deck LCD & OLED revision IDs and valid 64-bit GCF hash
   - Adds the Steam Deck hardware IDs to the display `.inf` files
   - Leaves `amdkmdag.sys` untouched (WHQL-signed)
   - Generates and signs the updated `.cat` catalog
5. Run **`Run_Installer_Admin.bat`** (or right-click **`InstallDriver.ps1`** -> **Run with PowerShell**):
   - Installs the package catalog certificate into `LocalMachine\Root` and `LocalMachine\TrustedPublisher`
   - Ensures Windows `testsigning` is turned **OFF**
   - Stages and force-binds the driver onto the Steam Deck GPU (`REV_AE` or `REV_E1`)
6. **Restart Windows** to complete the installation.

### Uninstalling
To remove the driver package and catalog certificate, right-click **`UninstallDriver.ps1`** -> **Run with PowerShell** and restart Windows.

---

## Credits

- Original research & AMD driver analysis by [otti83](https://github.com/otti83/apu_driver_test)
- Original automation scripts by [4PERTURE](https://github.com/4PERTURE/ally2deck) and [ally2deckV2](https://github.com/ryanrudolfoba/ally2deckV2)
- **Ally2Deck-v3** `amdgcf.dat` 64-bit hash reconstruction & WHQL/Secure Boot preservation

## Disclaimer
AMD drivers are proprietary software owned by Advanced Micro Devices, Inc. This repository does **not** redistribute any AMD binaries—only automation scripts that patch your locally downloaded copy. Use at your own risk.
