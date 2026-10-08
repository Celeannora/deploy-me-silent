# Deploy-MESilentInstall

Silent, no-reboot software deployment to Windows workstations, powered by
[ManageEngine Endpoint Central's silent-install command database](https://www.manageengine.com/products/desktop-central/software-installation/windows-software.html).

## Just want to run it? Double-click `Start.cmd`.

That launches an interactive wizard — no switches, no PowerShell knowledge required.
It asks how to find target machines (**this machine only** / AD / hosts file /
subnet sweep / type them in), lets you search the app catalog by keyword, checks
the staging folder, prompts for credentials if needed, offers a dry run first,
then hands off to the deployment engine.

### Local install (single machine)

Pick **[1] THIS machine only** at the first prompt. The wizard sets the target
to your own computer name, skips the credentials step, and the deploy engine
detects it as localhost — no SMB copy, no WinRM/PsExec/SchTask ladder, just
runs the installer directly out of the staging folder in an elevated child
process. Right-click `Start.cmd` → **Run as administrator** so the installers
inherit the elevation.

## What's in the package

| File | Purpose |
| --- | --- |
| `Start.cmd` | **Double-click launcher for the interactive wizard.** |
| `Start-Wizard.ps1` | The menu-driven wizard front end. |
| `Deploy-MESilentInstall.ps1` | The deployment engine (accepts CLI switches for scripted use). |
| `Run.cmd` | Launcher for the engine directly (passes `-Pause -Debug2` and captures full output). |
| `Diagnose.ps1` | Environment sanity check — run first if anything looks off. |
| `MECommon.ps1` | Shared helpers (version detection, repo folder rules, catalog overrides) used by the wizard and the engine. |
| `PSScriptAnalyzerSettings.psd1` | Lint settings: Windows PowerShell 5.1 + PowerShell 7 compatibility checks. |
| `CustomCatalog.json` | *(Created on first use.)* Version overrides and custom apps recorded by the wizard. |
| `SoftwareCatalog.json` | 2,649 apps with vendor-published installer filename, silent install switches, silent uninstall command, and source URL. Built by parsing every `silent_install_*.html` page on ManageEngine. |
| `README.md` | This file. |
| `PsExec.exe` / `PsExec64.exe` | *(You supply.)* Optional — drop into the script folder to enable the PsExec fallback. |

## Absolute simplest workflow

1. Extract the zip.
2. Create an empty staging folder such as `C:\SW\Staging`.
3. Double-click **`Start.cmd`**.
4. Answer the prompts. The wizard offers to **scaffold** the staging layout
   for you — it creates one subfolder per selected app, drops a `README.txt`
   with the vendor URL and the exact required filename, and writes a
   `_index.csv` at the root listing everything you need to download. Fill in
   the empty folders, re-run, and it'll deploy.

### Bring your own installer files

Already have an MSI/EXE? At the STEP 3 `Search:` prompt, type **`file`**.

1. A standard Windows file picker opens (Ctrl+Click to choose several).
2. For each file, the wizard reads the product name, version, vendor and
   architecture (MSI properties or EXE version info, falling back to the version
   in the filename) and lists the closest ManageEngine catalog matches.
3. Type a number to map it, `s` to search the catalog yourself, or `n` to create
   a **custom entry** for software ManageEngine doesn't list.
4. The file is copied into `Staging\<App>\` **keeping its own filename**, and the
   catalog entry is updated to that version. Silent switches are inherited from
   the ManageEngine entry.

If installers are still missing after STEP 3, the wizard offers the same file
picker for each missing app (or a typed path, or dropping the app from the run).

### Versions update automatically

App folders have no version in their name (`Notepad++ (x64)\`, not
`Notepad++ (x64) (8.9.7)\`). To update an app, drop the new installer into its
folder. On the next run:

- every installer of the right type (`.msi` or `.exe`) in the folder is
  considered, and **the highest version wins** (ties go to the newest file);
- the wizard updates the entry in `CustomCatalog.json`, e.g.
  `Notepad++ (x64) (8.6.9)` becomes `Notepad++ (x64) (8.7.1)`, with the same switches;
- the deploy engine applies the same rule on its own, so scripted runs
  (`-Apps ...`) also pick up the newest file.

When you add a file through the wizard, it offers to delete the older installers
in that folder so the repo keeps one current version.

`CustomCatalog.json` holds your overrides and custom apps. An override replaces
the ManageEngine entry it came from, so you only ever see the current version.

### Staging layout

```
C:\SW\Staging\
  _index.csv                    <- what the repo holds now (app, folder, installer, version, switches, source)
  Notepad++ (x64)\
    README.txt
    npp.8.7.1.Installer.x64.exe <- your file, your filename
  Google Chrome (x64)\
    README.txt
    ChromeSetup.msi
```

Older layouts still work: versioned folder names from earlier versions of this
toolkit, and installers placed directly in the staging root under the catalog's
exact filename.

## Requirements

**Admin workstation**
- Windows PowerShell 5.1 or PowerShell 7+ (7+ enables parallelism via `-ThrottleLimit`).
- RSAT ActiveDirectory module (only if `-TargetSource AD`).
- Local admin / domain admin rights on the target hosts.
- SMB access to each target's `\\host\admin$` share.

**Targets**
- Windows 10 or 11 workstations.
- Reachable by ping + `\\host\admin$`.
- At least ONE of:
  - WinRM enabled (default on domain-joined boxes with the WinRM GPO), OR
  - `schtasks.exe` reachable to the host (works out of the box on any domain-joined machine with SMB), OR
  - `PsExec.exe` available on the admin workstation.

## Staging the installers

The script does not download anything. Place every installer file referenced by
the apps you plan to deploy into a single local folder on the admin
workstation. The filename must match the `installer` field in the catalog for
that app.

Look up an app's expected filename:

```powershell
$c = Get-Content .\SoftwareCatalog.json -Raw | ConvertFrom-Json
$c | Where-Object { $_.name -like 'Google Chrome*' } | Select name, installer, install_switches, source
```

Tip: the catalog reflects vendor names exactly as ManageEngine publishes them,
version numbers and all. Some common names (7-Zip, VLC, Zoom) may not appear
if ManageEngine has retired that page — always grep the catalog first:

```powershell
$c | Where-Object { $_.name -match '(?i)7[-]?zip|vlc|zoom' } | Select name
```

The `source` URL points to the ManageEngine page for that app, which lists the
vendor download URL.

## Typical usage

**Interactive: query AD, pick apps in a grid**

```powershell
.\Deploy-MESilentInstall.ps1 `
    -TargetSource AD `
    -SearchBase 'OU=Workstations,OU=Corp,DC=corp,DC=local' `
    -StagingPath 'C:\SW\Staging'
```

An Out-GridView picker opens; multi-select apps, click OK.

**Non-interactive: hosts file, explicit app list**

```powershell
.\Deploy-MESilentInstall.ps1 `
    -TargetSource HostsFile `
    -HostsFile .\hosts.txt `
    -StagingPath D:\Installers `
    -Apps 'Google Chrome*','Notepad++ *','Mozilla Firefox *','Adobe Acrobat Reader*'
```

`-Apps` accepts wildcards matched against the `name` field.

**Dry run (enumerate + validate, do nothing)**

```powershell
.\Deploy-MESilentInstall.ps1 -TargetSource AD -StagingPath C:\SW\Staging -TestOnly
```

**Parallel across 32 hosts (PS7 only)**

```powershell
pwsh -File .\Deploy-MESilentInstall.ps1 `
    -TargetSource AD -StagingPath C:\SW\Staging `
    -Apps 'Google Chrome*' -ThrottleLimit 32
```

## `hosts.txt` format

```
# corporate helpdesk workstations
PC-100.corp.local
PC-101.corp.local
10.20.30.44
```

Blank lines and `#` comments are ignored.

## What the script does per host

1. Pings the host. Skips if unreachable.
2. Copies the entire staging folder to `\\host\admin$\Temp\MESilent`
   (uses `-Credential` if supplied).
3. Builds a self-contained per-run PowerShell script that iterates every
   selected app, invokes it silently with the exact ManageEngine switches,
   and captures exit codes into `C:\Windows\Temp\MESilent\result.csv`.
4. Executes that script on the target using the first method that works:
   1. **PowerShell Remoting** (`Invoke-Command` over WinRM) — preferred.
   2. **PsExec** — used if `PsExec.exe` is next to the script or on PATH.
   3. **Scheduled Task** (`schtasks.exe /S \\host /Create /RU SYSTEM /SC ONCE`)
      — most compatible, works whenever SMB works.
5. Parses per-app results and writes them to the central log.

## No-reboot guarantee

- Every ManageEngine-published switch string is used exactly as published.
- For MSI installers the runtime wrapper adds `/norestart` if not already present.
- For EXE installers the wrapper appends `/norestart` when the switch string
  does not already contain a no-reboot directive (`/norestart`, `/noreboot`,
  or `REBOOT=ReallySuppress`).
- Exit codes `0`, `1641` (reboot initiated — suppressed), and `3010` (reboot
  required — not performed) are all treated as success.
- The script itself never issues `Restart-Computer`.

If a specific vendor installer ignores its documented `/norestart` and reboots
anyway, that's a vendor bug — the log will still capture the exit code.

## Central log

One file per run, e.g.
`.\Logs\Deploy-MESilentInstall_20260916_105500.log`

Columns: timestamp, level (INFO/WARN/ERROR/OK/STEP), host, app, message.

Grep patterns:

```powershell
Select-String -Path .\Logs\*.log -Pattern '^\S+\s+ERROR'   # failures
Select-String -Path .\Logs\*.log -Pattern 'ExitCode=3010'  # reboot-pending
```

## Refreshing the catalog

To rebuild `SoftwareCatalog.json` when ManageEngine publishes new app versions,
run the helper (Python 3, any OS):

```python
# See scripts/build_catalog.py in the source repo — or reuse the two-step
# process used to build this catalog:
#   1) Fetch https://www.manageengine.com/products/desktop-central/software-installation/windows-software.html
#      and extract every silent_install_*.html link.
#   2) Fetch each detail page; extract the "Silent Installation Switch" and
#      "Silent Uninstallation Switch" values from the text.
```

## Security & auditability

- No installers are downloaded at runtime.
- No inbound listeners are opened on the admin workstation.
- Every command executed on a target is echoed to the central log verbatim,
  including full switch string.
- Credentials, if supplied, live only in the current process memory and in the
  transient `schtasks /U/P` argv while a task is being created.

## Known limitations

- Some catalog entries have `"--"` as the uninstall command where the vendor
  page did not publish one; those entries were removed. `-Apps` will simply
  report no match if you request a name that doesn't exist.
- Version numbers in app names change over time. Prefer wildcards
  (`'Google Chrome*'`) over exact matches in `-Apps`.
- Scheduled Task fallback polls every 10s for up to 30 min; installers that
  take longer will still complete but the CSV pickup may lag by one poll.
- The parallel path (PS7 `-ThrottleLimit > 1`) spawns child pwsh processes; on
  very large fleets prefer running the script from a job server that has the
  resources for that many concurrent SMB copies.

## Source of truth

Every entry in `SoftwareCatalog.json` carries a `source` field pointing back
to the exact ManageEngine page it was parsed from — e.g.
`https://www.manageengine.com/products/desktop-central/software-installation/silent_install_Foxit-Reader-(2025.1.0.27937).html`.

## Linting

Settings follow the current PSScriptAnalyzer docs (fetched via Context7):

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1
```

This checks syntax, commands and .NET types against Windows PowerShell 5.1
(Windows 10) and PowerShell 7. All `.ps1` files are ASCII-only and saved as
UTF-8 **with BOM**, so Windows PowerShell 5.1 reads them correctly.
