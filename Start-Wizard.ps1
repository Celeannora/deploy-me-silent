<#
.SYNOPSIS
    Interactive, menu-driven front end for Deploy-MESilentInstall.ps1.
    No command-line switches required - just double-click Start.cmd.

.DESCRIPTION
    Walks the user through every choice:
      1. Target discovery : Active Directory OU  |  hosts file  |  subnet sweep  |  type manually
      2. Staging folder   : where the installers live
      3. App selection    : searchable, paged picker over the full ManageEngine catalog
      4. Credentials      : local admin or domain admin (optional)
      5. Test-only preview or real deployment
    Then invokes Deploy-MESilentInstall.ps1 with the assembled parameters.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'Job/runspace values are passed via -ArgumentList/AddArgument().')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseCompatibleTypes', '', Justification = 'System.Windows.Forms is loaded with Add-Type before use.')]
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'MECommon.ps1')

# ---------------------------------------------------------------------------
# Global trap so the window never closes silently
# ---------------------------------------------------------------------------
trap {
    Write-Host ""
    Write-Host "==================== UNHANDLED EXCEPTION ====================" -ForegroundColor Red
    Write-Host ("MESSAGE : {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("AT      : {0}:{1}" -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
    Write-Host ("LINE    : {0}" -f $_.InvocationInfo.Line.Trim()) -ForegroundColor Yellow
    Write-Host "STACK   :" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkYellow
    Write-Host "=============================================================" -ForegroundColor Red
    Write-Host ""
    Read-Host "Press ENTER to close"
    exit 1
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Show-Banner {
    Clear-Host
    Write-Host ""
    Write-Host "  +============================================================+" -ForegroundColor Cyan
    Write-Host "  |       ManageEngine Silent Deployment Wizard                |" -ForegroundColor Cyan
    Write-Host "  |       No switches needed - just answer the prompts         |" -ForegroundColor Cyan
    Write-Host "  +============================================================+" -ForegroundColor Cyan
    Write-Host ""
}

function Read-Menu {
    param(
        [string]$Title,
        [string[]]$Options,
        [int]$Default = 1
    )
    Write-Host ""
    Write-Host $Title -ForegroundColor Yellow
    for ($i=0; $i -lt $Options.Count; $i++) {
        "  [{0}] {1}" -f ($i+1), $Options[$i] | Write-Host
    }
    while ($true) {
        $raw = Read-Host ("Choice [1-{0}] (default {1})" -f $Options.Count, $Default)
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        if ($raw -match '^\d+$') {
            $n = [int]$raw
            if ($n -ge 1 -and $n -le $Options.Count) { return $n }
        }
        Write-Host "  Invalid choice." -ForegroundColor Red
    }
}

function Read-YesNo {
    param([string]$Prompt, [bool]$Default = $false)
    $d = if ($Default) { 'Y' } else { 'N' }
    while ($true) {
        $r = Read-Host ("{0} (Y/N) [default {1}]" -f $Prompt, $d)
        if ([string]::IsNullOrWhiteSpace($r)) { return $Default }
        switch -Regex ($r.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$'  { return $false }
            default     { Write-Host "  Please answer Y or N." -ForegroundColor Red }
        }
    }
}

function Read-Required {
    param([string]$Prompt)
    while ($true) {
        $v = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v.Trim() }
        Write-Host "  A value is required." -ForegroundColor Red
    }
}

# ---------------------------------------------------------------------------
# Load catalog
# ---------------------------------------------------------------------------
$CatalogPath = Join-Path $PSScriptRoot 'SoftwareCatalog.json'
if (-not (Test-Path $CatalogPath)) { throw "SoftwareCatalog.json not found next to this script." }
$catalog = Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json
$catalog = @($catalog)
# Your own entries (installers ManageEngine doesn't list) live in CustomCatalog.json
$CustomCatalogPath = Join-Path $PSScriptRoot 'CustomCatalog.json'
$script:catTokCache = @{}     # name-token cache used by Find-CatalogMatches
$customCount = 0
try {
    $catalog = @(Merge-CustomCatalog -Catalog $catalog -CustomPath $CustomCatalogPath)
    if (Test-Path -LiteralPath $CustomCatalogPath) { $customCount = @(Get-Content -Raw -LiteralPath $CustomCatalogPath | ConvertFrom-Json).Count }
} catch { Write-Host "WARNING: CustomCatalog.json is unreadable and was ignored." -ForegroundColor Yellow }

Show-Banner
Write-Host ("Catalog loaded: {0} apps ({1} custom)." -f $catalog.Count, $customCount) -ForegroundColor Green

# ---------------------------------------------------------------------------
# Step 1: target discovery
# ---------------------------------------------------------------------------
$myName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
$targetMode = Read-Menu -Title "STEP 1 - How should we find target workstations?" -Options @(
    "THIS machine only (install locally on $myName)",
    "Active Directory (needs RSAT + domain join)",
    "Read from a hosts file (one machine per line)",
    "Sweep a subnet (ping range and use responders)",
    "Type machine names now"
) -Default 1

$targetSource = 'HostsFile'
$hostsFile    = $null
$searchBase   = $null

switch ($targetMode) {
    1 {
        # Local install - write a one-line hosts file with the computer's own name
        $tempRoot = if ($env:TEMP) { $env:TEMP } else { [System.IO.Path]::GetTempPath() }
        $me = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }
        $tmp = Join-Path $tempRoot ("wizhosts_local_{0}.txt" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
        Set-Content -LiteralPath $tmp -Value $me -Encoding UTF8
        $hostsFile = $tmp
        Write-Host ("  Target = {0} (local machine)." -f $me) -ForegroundColor Green
    }
    2 {
        $targetSource = 'AD'
        $useOU = Read-YesNo "Limit to a specific OU?" -Default $false
        if ($useOU) {
            $searchBase = Read-Required "Enter OU DN (e.g. OU=Workstations,DC=corp,DC=local)"
        }
    }
    3 {
        $defaultHosts = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'hosts.txt' } else { '.\hosts.txt' }
        $prompt = if (Test-Path $defaultHosts) { "Path to hosts file [default $defaultHosts]" } else { "Path to hosts file" }
        $p = Read-Host $prompt
        if ([string]::IsNullOrWhiteSpace($p)) { $p = $defaultHosts }
        if (-not (Test-Path $p)) { throw "Hosts file not found: $p" }
        $hostsFile = (Resolve-Path $p).Path
    }
    4 {
        $cidr = Read-Required "Enter subnet range (e.g. 192.168.1.1-254 or 10.0.0.1-100)"
        if ($cidr -notmatch '^(\d+\.\d+\.\d+)\.(\d+)-(\d+)$') { throw "Format must be A.B.C.START-END, e.g. 192.168.1.1-254" }
        $prefix = $Matches[1]; $start = [int]$Matches[2]; $end = [int]$Matches[3]
        if ($start -lt 1 -or $end -gt 254 -or $start -gt $end) { throw "Invalid range." }
        Write-Host ("Sweeping {0}.{1} through {0}.{2} ... (this may take up to a minute)" -f $prefix, $start, $end) -ForegroundColor Cyan
        $live = @()
        $range = $start..$end
        $jobs = $range | ForEach-Object {
            $ip = "$prefix.$_"
            Start-Job -ScriptBlock { param($i) if (Test-Connection $i -Count 1 -Quiet -ErrorAction SilentlyContinue) { $i } } -ArgumentList $ip
        }
        $live = @($jobs | Wait-Job | Receive-Job)
        $jobs | Remove-Job -Force
        if ($live.Count -eq 0) { throw "No hosts responded in that range." }
        Write-Host ("Found {0} responder(s)." -f $live.Count) -ForegroundColor Green
        $live | ForEach-Object { "  $_" | Write-Host }
        $tmp = Join-Path $env:TEMP ("wizhosts_{0}.txt" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
        $live | Set-Content -LiteralPath $tmp -Encoding UTF8
        $hostsFile = $tmp
    }
    5 {
        Write-Host "Enter machine names one per line. Blank line when done." -ForegroundColor Cyan
        $names = @()
        while ($true) {
            $n = Read-Host " host"
            if ([string]::IsNullOrWhiteSpace($n)) { break }
            $names += $n.Trim()
        }
        if ($names.Count -eq 0) { throw "You didn't enter any hosts." }
        $tmp = Join-Path $env:TEMP ("wizhosts_{0}.txt" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
        $names | Set-Content -LiteralPath $tmp -Encoding UTF8
        $hostsFile = $tmp
    }
}

# ---------------------------------------------------------------------------
# Step 2: staging folder
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "STEP 2 - Staging folder (your software repo). Installers are stored here, one subfolder per app." -ForegroundColor Yellow
$stagingPath = Read-Required "Staging folder path (e.g. C:\SW\Staging)"
if (-not (Test-Path $stagingPath)) {
    if (Read-YesNo "That folder does not exist. Create it now?" -Default $true) {
        New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
    } else { throw "Staging folder required." }
}

# ---------------------------------------------------------------------------
# GUI file picker (works in STA or MTA hosts; falls back to typed path)
# ---------------------------------------------------------------------------
function Show-InstallerPicker {
    param([string]$Title,[string]$ExpectedName,[string]$InitialDir,[switch]$Multi)
    $ext = [IO.Path]::GetExtension($ExpectedName).ToLower()
    $filter = switch ($ext) {
        '.msi'  { 'Windows Installer (*.msi)|*.msi|Installers (*.msi;*.exe)|*.msi;*.exe|All files (*.*)|*.*' }
        '.exe'  { 'Executables (*.exe)|*.exe|Installers (*.msi;*.exe)|*.msi;*.exe|All files (*.*)|*.*' }
        default { 'Installers (*.msi;*.exe)|*.msi;*.exe|All files (*.*)|*.*' }
    }
    if (-not $InitialDir -or -not (Test-Path -LiteralPath $InitialDir)) {
        $InitialDir = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE 'Downloads' } else { [IO.Path]::GetTempPath() }
    }
    $code = {
        param($Title,$Filter,$InitialDir,$Multi)
        $ErrorActionPreference = 'Stop'
        Add-Type -AssemblyName System.Windows.Forms
        # Hidden topmost owner so the dialog does not open behind the console window
        $owner = New-Object System.Windows.Forms.Form
        $owner.TopMost = $true; $owner.ShowInTaskbar = $false
        $owner.WindowState = 'Minimized'; $owner.Opacity = 0
        $owner.Show(); $owner.Hide()
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Title = $Title
        $dlg.Filter = $Filter
        $dlg.InitialDirectory = $InitialDir
        $dlg.Multiselect = [bool]$Multi
        $dlg.CheckFileExists = $true
        $result = $dlg.ShowDialog($owner)
        $owner.Dispose()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) { return @($dlg.FileNames) }
        return $null
    }
    try {
        if ([Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
            return @(& $code $Title $filter $InitialDir ([bool]$Multi))
        }
        # MTA host (e.g. some pwsh setups): run the dialog in a dedicated STA runspace
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'ReuseThread'; $rs.Open()
        $ps = [powershell]::Create(); $ps.Runspace = $rs
        [void]$ps.AddScript($code).AddArgument($Title).AddArgument($filter).AddArgument($InitialDir).AddArgument([bool]$Multi)
        $out = $ps.Invoke()
        $failed = $ps.HadErrors -or ($ps.Streams.Error.Count -gt 0)
        $errMsg = if ($ps.Streams.Error.Count -gt 0) { [string]$ps.Streams.Error[0] } else { 'unknown error' }
        $ps.Dispose(); $rs.Close()
        if ($failed) { throw $errMsg }
        if ($out -and $out.Count -gt 0) { return @($out | ForEach-Object { [string]$_ }) }
        return $null
    } catch {
        Write-Host ("  File dialog unavailable ({0}). Type the path instead." -f $_.Exception.Message) -ForegroundColor Yellow
        $typed = Read-Host "  Full path(s) to installer, separate several with ; (blank to cancel)"
        if ([string]::IsNullOrWhiteSpace($typed)) { return $null }
        return @($typed -split ';' | ForEach-Object { $_.Trim().Trim('"').Trim() } | Where-Object { $_ })
    }
}

function Import-InstallerFile {
    # Copies a user-supplied installer into the app's (version-less) repo folder, KEEPING its own
    # filename. Returns the stored filename, or $null on failure/cancel.
    param($App,[string]$SourceFile,[string]$StagingRoot)
    if (-not (Test-Path -LiteralPath $SourceFile -PathType Leaf)) {
        Write-Host "  File not found: $SourceFile" -ForegroundColor Red
        return $null
    }
    $wantExt = [IO.Path]::GetExtension([string]$App.installer).ToLower()
    $gotExt  = [IO.Path]::GetExtension($SourceFile).ToLower()
    if (($wantExt -eq '.msi' -or $wantExt -eq '.exe') -and $gotExt -ne $wantExt) {
        Write-Host ("  WARNING: catalog expects a {0} file but you picked a {1} file." -f $wantExt, $gotExt) -ForegroundColor Red
        Write-Host ("           Silent switches '{0}' are written for the {1} installer and will likely fail." -f $App.install_switches, $wantExt) -ForegroundColor Red
        if (-not (Read-YesNo "  Use this file anyway?" -Default $false)) { return $null }
    }
    $appDir = Join-Path $StagingRoot (Get-AppFolderName $App)
    if (-not (Test-Path -LiteralPath $appDir)) { New-Item -ItemType Directory -Path $appDir -Force | Out-Null }
    $fileName = ([IO.Path]::GetFileName($SourceFile)) -replace '[\\/:*?"<>|]', '_'
    $dest = Join-Path $appDir $fileName
    try {
        $srcFull = (Resolve-Path -LiteralPath $SourceFile).Path
        $dstFull = [IO.Path]::GetFullPath($dest)
        if ($srcFull -ieq $dstFull) {
            Write-Host "  Already in the repo: $dest" -ForegroundColor Green
        } else {
            Copy-Item -LiteralPath $SourceFile -Destination $dest -Force -ErrorAction Stop
            $sizeMB = [math]::Round((Get-Item -LiteralPath $dest).Length / 1MB, 1)
            Write-Host ("  Copied to {0}  ({1} MB)" -f $dest, $sizeMB) -ForegroundColor Green
        }
    } catch {
        Write-Host ("  Copy failed: {0}" -f $_.Exception.Message) -ForegroundColor Red
        return $null
    }
    Get-ChildItem -LiteralPath $appDir -Filter 'PLACE_INSTALLER_HERE_*.txt' -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    # Offer to clear out older installers of the same type so the repo holds one current version
    $older = @(Get-ChildItem -LiteralPath $appDir -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -ieq $gotExt -and $_.Name -ine $fileName })
    if ($older.Count -gt 0) {
        Write-Host ("  Other {0} installer(s) in this folder: {1}" -f $gotExt, (($older | ForEach-Object { $_.Name }) -join ', ')) -ForegroundColor DarkYellow
        if (Read-YesNo "  Remove them so only the new installer is kept?" -Default $true) {
            $older | Remove-Item -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host "  Kept. The highest version in the folder is used at deploy time." -ForegroundColor DarkYellow
        }
    }
    return $fileName
}

function Set-InstallerOverride {
    <#
        Records that $App should now use $FileName (at $Version). Writes/replaces an override entry in
        CustomCatalog.json that inherits the switches from the ManageEngine (or custom) entry, updates
        the in-memory catalog, and returns the new entry.
    #>
    param($App,[string]$FileName,[string]$Version)
    $props = @($App.PSObject.Properties.Name)
    $root  = if ($props -contains 'overrides' -and $App.overrides) { [string]$App.overrides } else { [string]$App.name }
    $base  = if ($props -contains 'base' -and $App.base) { [string]$App.base } else { Get-BaseAppName ([string]$App.name) }
    $name  = if ($Version) { "{0} ({1})" -f $base, $Version } else { $base }
    $entry = [pscustomobject]@{
        name             = $name
        base             = $base
        version          = $Version
        installer        = $FileName
        install_switches = [string]$App.install_switches
        uninstall_cmd    = if ($props -contains 'uninstall_cmd' -and $App.uninstall_cmd) { ([string]$App.uninstall_cmd).Replace([string]$App.installer, $FileName) } else { '' }
        source           = [string]$App.source
        overrides        = $root
        custom           = $true
        updated          = (Get-Date -Format 's')
    }
    $existing = @()
    if (Test-Path -LiteralPath $CustomCatalogPath) {
        try { $existing = @(Get-Content -Raw -LiteralPath $CustomCatalogPath | ConvertFrom-Json) } catch { $existing = @() }
    }
    $existing = @($existing | Where-Object {
        $n = [string]$_.name
        $o = if ($_.PSObject.Properties.Name -contains 'overrides') { [string]$_.overrides } else { '' }
        ($n -ne [string]$App.name) -and ($n -ne $name) -and ($o -ne $root)
    }) + $entry
    ConvertTo-Json -InputObject @($existing) -Depth 4 | Set-Content -LiteralPath $CustomCatalogPath -Encoding UTF8
    $script:catalog = @($script:catalog | Where-Object {
        $n = [string]$_.name
        $o = if ($_.PSObject.Properties.Name -contains 'overrides') { [string]$_.overrides } else { '' }
        ($n -ne [string]$App.name) -and ($n -ne $root) -and ($n -ne $name) -and ($o -ne $root)
    }) + $entry
    return $entry
}

function Update-Selection {
    param($Old,$New)
    $script:selected = @($script:selected | ForEach-Object { if ([string]$_.name -eq [string]$Old.name) { $New } else { $_ } })
}

function Register-ProvidedInstaller {
    # Import a file for $App and update the catalog to the file's version. Returns the entry to deploy.
    param($App,[string]$SourceFile,[string]$StagingRoot)
    $meta = Get-InstallerMetadata -Path $SourceFile
    $stored = Import-InstallerFile -App $App -SourceFile $SourceFile -StagingRoot $StagingRoot
    if (-not $stored) { return $null }
    if ($stored -ieq [string]$App.installer -and -not $meta.Version) { return $App }
    $entry = Set-InstallerOverride -App $App -FileName $stored -Version ([string]$meta.Version)
    $vtxt = if ($meta.Version) { "version {0} (from {1})" -f $meta.Version, $meta.VersionSource } else { "version unknown" }
    Write-Host ("  Catalog updated: '{0}' now uses {1}, {2}. Switches kept: {3}" -f $entry.name, $stored, $vtxt, $entry.install_switches) -ForegroundColor Green
    return $entry
}


# ---------------------------------------------------------------------------
# Map a user-supplied installer to the catalog (or a custom catalog entry)
# ---------------------------------------------------------------------------
function Get-NameTokens {
    param([string]$Text)
    if (-not $Text) { return @() }
    $t = $Text -creplace '([a-z])([A-Z])', '$1 $2'          # ChromeSetup -> Chrome Setup
    $t = $t.ToLower()
    $t = $t -replace '7-zip', '7zip' -replace '(^|[^a-z0-9])7z(?=\d|[^a-z]|$)', '$1 7zip '
    $t = $t -replace 'notepad\+\+', 'notepadpp'
    $t = $t -replace '([a-z])(\d)', '$1 $2'                  # dc2400 -> dc 2400
    $alias = @{ 'npp'='notepadpp'; 'acro'='acrobat'; 'rdr'='reader'; 'ff'='firefox'; 'vscode'='code' }
    # Architecture / packaging words are scored separately, not as name tokens
    $stop = @('setup','installer','install','the','for','and','inc','corp','corporation','llc','ltd','latest',
              'windows','win','bit','edition','version','x64','x86','win64','win32','amd64','arm64','64bit','32bit',
              'msi','exe','en','us','full','offline','standalone','enterprise64','release')
    $out = @()
    foreach ($w in ($t -split '[^a-z0-9]+')) {
        if ($w.Length -lt 2 -or $w -match '^\d+$' -or $stop -contains $w) { continue }
        if ($alias.ContainsKey($w)) { $w = $alias[$w] }
        if ($out -notcontains $w) { $out += $w }
    }
    return $out
}

function Get-ArchTag {
    param([string]$Text)
    if ($Text -match '(?i)x64|amd64|win64|64-?bit|x86_64|arm64|enterprise64') { return 'x64' }
    if ($Text -match '(?i)x86|win32|32-?bit') { return 'x86' }
    return ''
}

function Find-CatalogMatches {
    param($Meta,[int]$Top = 8)
    # Tokenize the catalog once per session
    $fileBase = [IO.Path]::GetFileNameWithoutExtension($Meta.FileName)
    $fileTok = @(Get-NameTokens $fileBase)
    $prodTok = @(Get-NameTokens ("{0} {1}" -f $Meta.ProductName, $Meta.Description))
    $allTok  = @(@($fileTok) + @($prodTok) | Select-Object -Unique)
    $fileArch = if ($Meta.Arch) { $Meta.Arch } else { Get-ArchTag $Meta.FileName }
    $scored = @()
    foreach ($e in $catalog) {
        $name = [string]$e.name; $inst = [string]$e.installer
        if (-not $script:catTokCache.ContainsKey($name)) {
            $script:catTokCache[$name] = @(
                ,@(Get-NameTokens $name)
                ,@(Get-NameTokens ([IO.Path]::GetFileNameWithoutExtension($inst)))
                ,[string](Get-ArchTag ("{0} {1}" -f $name, $inst))
            )
        }
        $cache = $script:catTokCache[$name]
        $entTok = @($cache[0]); $instTok = @($cache[1]); $entArch = [string]$cache[2]
        $score = 0
        if ($inst -and $inst -ieq $Meta.FileName) { $score += 100 }
        if ($entTok.Count -gt 0 -and $allTok.Count -gt 0) {
            $hit = @($entTok | Where-Object { $allTok -contains $_ }).Count
            if ($hit -gt 0) {
                $score += [int](50 * $hit / $entTok.Count)
                $score += [int](20 * $hit / $allTok.Count)
            }
        }
        if ($instTok.Count -gt 0 -and $fileTok.Count -gt 0) {
            $h2 = @($instTok | Where-Object { $fileTok -contains $_ }).Count
            $score += [int](25 * $h2 / $instTok.Count)
        }
        if ($score -lt 25) { continue }
        $eExt = [IO.Path]::GetExtension($inst).ToLower()
        if ($eExt -eq $Meta.Ext) { $score += 10 } elseif ($eExt) { $score -= 15 }
        if ($fileArch -and $entArch) {
            if ($fileArch -eq $entArch) { $score += 15 } else { $score -= 15 }
        } elseif ($fileArch -eq 'x64' -and -not $entArch) { $score -= 5 }
        if ($Meta.Version -and $name.Contains($Meta.Version)) { $score += 15 }
        $scored += [pscustomobject]@{ Score = $score; Entry = $e }
    }
    return @($scored | Sort-Object Score -Descending | Select-Object -First $Top)
}

function New-CustomCatalogEntry {
    # Creates a catalog entry for an installer ManageEngine doesn't list, and saves it to CustomCatalog.json
    param($Meta)
    $defName = (("{0} ({1})" -f $Meta.ProductName, $Meta.Version) -replace '\(\)','').Trim()
    if (-not $Meta.ProductName) { $defName = [IO.Path]::GetFileNameWithoutExtension($Meta.FileName) }
    $nm = Read-Host ("  App name [default: {0}]" -f $defName)
    if ([string]::IsNullOrWhiteSpace($nm)) { $nm = $defName }
    $nm = $nm.Trim()
    if ($Meta.Ext -eq '.msi') {
        $sw = Read-Host "  Silent switches [default: /qn /norestart]"
        if ([string]::IsNullOrWhiteSpace($sw)) { $sw = '/qn /norestart' }
    } else {
        $presets = [ordered]@{
            'Inno'          = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-'
            'NSIS'          = '/S'
            'WixBurn'       = '/quiet /norestart'
            'InstallShield' = '/s /v"/qn /norestart"'
        }
        $keys = @($presets.Keys)
        $def = if ($Meta.Engine -and $keys -contains $Meta.Engine) { $keys.IndexOf($Meta.Engine) + 1 } else { 5 }
        if ($Meta.Engine) { Write-Host ("  Detected installer engine: {0}" -f $Meta.Engine) -ForegroundColor Green }
        else { Write-Host "  Could not detect the installer engine - check the vendor's docs for its silent switch." -ForegroundColor Yellow }
        $opt = @()
        foreach ($k in $keys) { $opt += ("{0,-14} {1}" -f $k, $presets[$k]) }
        $opt += "Type my own switches"
        $c = Read-Menu -Title "  Which silent switches should this EXE use?" -Options $opt -Default $def
        if ($c -le $keys.Count) { $sw = $presets[$keys[$c-1]] }
        else {
            $sw = ''
            while ([string]::IsNullOrWhiteSpace($sw)) { $sw = Read-Host "  Silent switches (e.g. /S or /quiet /norestart)"; if ($null -eq $sw) { $sw = '/S' } }
        }
    }
    $safeFile = ($Meta.FileName -replace '[\\/:*?"<>|]','_')
    $entry = [pscustomobject]@{
        name             = $nm
        base             = (Get-BaseAppName $nm)
        version          = [string]$Meta.Version
        installer        = $safeFile
        install_switches = $sw
        uninstall_cmd    = ''
        source           = ('custom: {0}' -f $Meta.Path)
        custom           = $true
    }
    # Persist (replace any existing custom entry of the same name)
    $existing = @()
    if (Test-Path -LiteralPath $CustomCatalogPath) {
        try { $existing = @(Get-Content -Raw -LiteralPath $CustomCatalogPath | ConvertFrom-Json) } catch { $existing = @() }
    }
    $existing = @($existing | Where-Object { [string]$_.name -ne $nm }) + $entry
    ConvertTo-Json -InputObject @($existing) -Depth 4 | Set-Content -LiteralPath $CustomCatalogPath -Encoding UTF8
    $script:catalog = @($script:catalog | Where-Object { [string]$_.name -ne $nm }) + $entry
    Write-Host ("  Saved custom entry '{0}' to {1}" -f $nm, $CustomCatalogPath) -ForegroundColor Green
    return $entry
}

function Write-AppReadme {
    param($App,[string]$AppDir)
    $lines = @(
        ('App:        {0}' -f $App.name),
        ('Installer:  {0}' -f $App.installer),
        ('Switches:   {0}' -f $App.install_switches),
        ('Source:     {0}' -f $App.source),
        '',
        'You can drop a newer installer of the same type into this folder at any time.',
        'The highest version found here is used automatically, and the wizard updates',
        'CustomCatalog.json to match (switches are kept).',
        '',
        'The deployer will run:',
        ('  <installer> {0}' -f $App.install_switches)
    )
    Set-Content -LiteralPath (Join-Path $AppDir 'README.txt') -Value ($lines -join "`r`n") -Encoding UTF8
}

function Add-InstallersFromFiles {
    # Pick one or more MSI/EXE files, map each to a catalog entry (or create a custom one),
    # copy it into the staging repo under the expected name, and return the mapped apps.
    param([string]$StagingRoot)
    $files = @(Show-InstallerPicker -Title "Select installer file(s) to add (Ctrl+Click for several)" -ExpectedName '' -Multi)
    $files = @($files | Where-Object { $_ })
    if ($files.Count -eq 0) { Write-Host "  No files chosen." -ForegroundColor Yellow; return @() }
    $mapped = @()
    $n = 0
    foreach ($f in $files) {
        $n++
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { Write-Host "  Not found: $f" -ForegroundColor Red; continue }
        $meta = Get-InstallerMetadata -Path $f
        Write-Host ""
        Write-Host ("[{0}/{1}] {2}" -f $n, $files.Count, $meta.FileName) -ForegroundColor Cyan
        if ($meta.ProductName)  { Write-Host ("        product : {0} {1}" -f $meta.ProductName, $meta.Version) }
        if ($meta.Manufacturer) { Write-Host ("        vendor  : {0}" -f $meta.Manufacturer) }
        if ($meta.Arch)         { Write-Host ("        arch    : {0}" -f $meta.Arch) }
        $cands = @(Find-CatalogMatches -Meta $meta)
        if ($cands.Count -gt 0) {
            Write-Host "  Closest catalog matches:" -ForegroundColor Yellow
            for ($i = 0; $i -lt $cands.Count; $i++) {
                "    [{0}] {1}   (expects {2}, score {3})" -f ($i+1), $cands[$i].Entry.name, $cands[$i].Entry.installer, $cands[$i].Score | Write-Host
            }
        } else {
            Write-Host "  No close catalog match found." -ForegroundColor Yellow
        }
        Write-Host "  Enter a number to map to that entry, 's' to search the catalog, 'n' for a new custom entry, or Enter to skip." -ForegroundColor Cyan
        $target = $null
        while ($true) {
            $ans = Read-Host "  Map to"
            if ([string]::IsNullOrWhiteSpace($ans)) { break }
            $ans = $ans.Trim()
            if ($ans -match '^\d+$' -and [int]$ans -ge 1 -and [int]$ans -le $cands.Count) { $target = $cands[[int]$ans-1].Entry; break }
            if ($ans -ieq 'n') { $target = New-CustomCatalogEntry -Meta $meta; break }
            if ($ans -ieq 's') {
                $q = Read-Host "    Search catalog"
                if ([string]::IsNullOrWhiteSpace($q)) { continue }
                $cands = @()
                foreach ($e in $catalog) { try { if ([string]$e.name -match [regex]::Escape($q) -or [string]$e.name -match $q) { $cands += [pscustomobject]@{ Score = 0; Entry = $e } } } catch { Write-Verbose ('Invalid search pattern: ' + $_.Exception.Message) } }
                if ($cands.Count -gt 25) { $cands = $cands[0..24] }
                if ($cands.Count -eq 0) { Write-Host "    No matches." -ForegroundColor Red; continue }
                for ($i = 0; $i -lt $cands.Count; $i++) { "    [{0}] {1}   (expects {2})" -f ($i+1), $cands[$i].Entry.name, $cands[$i].Entry.installer | Write-Host }
                continue
            }
            Write-Host "  Invalid choice." -ForegroundColor Red
        }
        if (-not $target) { Write-Host "  Skipped." -ForegroundColor DarkYellow; continue }
        $final = Register-ProvidedInstaller -App $target -SourceFile $f -StagingRoot $StagingRoot
        if ($final) {
            $appDir = Join-Path $StagingRoot (Get-AppFolderName $final)
            Write-AppReadme -App $final -AppDir $appDir
            $mapped += $final
            Write-Host ("  Mapped to: {0}" -f $final.name) -ForegroundColor Green
        }
    }
    return $mapped
}

# ---------------------------------------------------------------------------
# Step 3: app selection (searchable picker)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "STEP 3 - Choose apps to deploy from the ManageEngine catalog." -ForegroundColor Yellow
$selected = @()
$patterns = @()

while ($true) {
    Write-Host ""
    Write-Host "Type part of an app name (regex OK), or:" -ForegroundColor Cyan
    Write-Host "  file     = add installer file(s) you already have (MSI/EXE picker) and map them to the catalog" -ForegroundColor DarkCyan
    Write-Host "  [Enter]  = finish selection" -ForegroundColor DarkCyan
    Write-Host "  list     = show current selection" -ForegroundColor DarkCyan
    Write-Host "  clear    = clear selection" -ForegroundColor DarkCyan
    $q = Read-Host "Search"
    if ([string]::IsNullOrWhiteSpace($q)) {
        if ($selected.Count -eq 0) {
            Write-Host "  You haven't picked anything yet." -ForegroundColor Red
            continue
        }
        break
    }
    if ($q -eq 'list') {
        if ($selected.Count -eq 0) { Write-Host "  (empty)" } else { $selected | ForEach-Object { "  * $($_.name)" | Write-Host } }
        continue
    }
    if ($q -eq 'file') {
        $added = @(Add-InstallersFromFiles -StagingRoot $stagingPath)
        $have = @{}
        foreach ($item in $selected) { $have[[string]$item.name] = $true }
        foreach ($item in $added) {
            if (-not $have.ContainsKey([string]$item.name)) { $selected += ,$item; $have[[string]$item.name] = $true }
        }
        Write-Host ("  Selection now has {0} app(s)." -f $selected.Count) -ForegroundColor Green
        continue
    }
    if ($q -eq 'clear') { $selected = @(); $patterns = @(); Write-Host "  Cleared." -ForegroundColor Yellow; continue }

    $hits = @()
    foreach ($entry in $catalog) {
        try {
            if ($entry.name -match [regex]::Escape($q) -or $entry.name -match $q) { $hits += $entry }
        } catch { Write-Verbose ('Skipped catalog entry (invalid regex): ' + $_.Exception.Message) }
    }
    if ($hits.Count -eq 0) { Write-Host "  No matches." -ForegroundColor Red; continue }
    if ($hits.Count -gt 40) {
        Write-Host ("  {0} matches - showing first 40. Refine your search for more precision." -f $hits.Count) -ForegroundColor Yellow
        $hits = $hits[0..39]
    }
    for ($i=0; $i -lt $hits.Count; $i++) {
        "  [{0,3}] {1}" -f ($i+1), $hits[$i].name | Write-Host
    }
    Write-Host "  Enter numbers separated by commas (e.g. 1,3,5), 'all' to take everything shown," -ForegroundColor Cyan
    Write-Host "  or press Enter to skip and search again." -ForegroundColor Cyan
    $pick = Read-Host "Pick"
    if ([string]::IsNullOrWhiteSpace($pick)) { continue }
    $toAdd = @()
    if ($pick -eq 'all') {
        $toAdd = $hits
    } else {
        foreach ($tok in ($pick -split ',')) {
            $t = $tok.Trim()
            if ($t -match '^\d+$') {
                $n = [int]$t
                if ($n -ge 1 -and $n -le $hits.Count) { $toAdd += $hits[$n-1] }
            }
        }
    }
    # Dedup by name (kept as parallel arrays to avoid strict-mode property access games)
    $existingNames = @{}
    foreach ($item in $selected) { $existingNames[[string]$item.name] = $true }
    foreach ($item in $toAdd) {
        $nm = [string]$item.name
        if (-not $existingNames.ContainsKey($nm)) {
            $selected += ,$item
            $existingNames[$nm] = $true
        }
    }
    Write-Host ("  Selection now has {0} app(s)." -f $selected.Count) -ForegroundColor Green
}

# Convert to exact-name patterns for the deploy script
$patterns = @()
foreach ($item in $selected) { $patterns += [string]$item.name }

# ---------------------------------------------------------------------------
# Scaffold staging layout + check for installer files
# ---------------------------------------------------------------------------
Write-Host ""
$doScaffold = Read-YesNo "Scaffold per-app folders in the staging path? (creates one folder per selected app with a README pointing at the vendor download page)" -Default $true

if ($doScaffold) {
    Write-Host ""
    Write-Host ("Scaffolding {0} app folder(s) under {1}..." -f $selected.Count, $stagingPath) -ForegroundColor Yellow
    $created = 0; $existed = 0
    foreach ($app in $selected) {
        $appDir = Join-Path $stagingPath (Get-AppFolderName $app)
        if (-not (Test-Path -LiteralPath $appDir)) { New-Item -ItemType Directory -Path $appDir -Force | Out-Null; $created++ } else { $existed++ }
        if (-not (Test-Path -LiteralPath (Join-Path $appDir 'README.txt'))) { Write-AppReadme -App $app -AppDir $appDir }
        if (-not (Find-AppInstaller -App $app -StagingRoot $stagingPath)) {
            $ext = [IO.Path]::GetExtension([string]$app.installer)
            $marker = Join-Path $appDir ("PLACE_INSTALLER_HERE_{0}.txt" -f $app.installer)
            if (-not (Test-Path -LiteralPath $marker)) {
                Set-Content -LiteralPath $marker -Encoding UTF8 -Value (
                    "Put the {0} installer for {1} in this folder (any filename; e.g. {2}).`r`nDownload: {3}" -f $ext, (Get-BaseAppName ([string]$app.name)), $app.installer, $app.source)
            }
        }
    }
    Write-Host ("  Created {0} folder(s), reused {1}." -f $created, $existed) -ForegroundColor Green
}

function Write-RepoIndex {
    # _index.csv = what the repo holds right now, per selected app
    $esc = { param($v) $v = [string]$v; if ($v -match '[,"]') { '"' + ($v -replace '"','""') + '"' } else { $v } }
    $rows = @('AppName,Folder,InstallerInRepo,Version,InstallSwitches,SourceURL')
    foreach ($app in $script:selected) {
        $hit = Find-AppInstaller -App $app -StagingRoot $stagingPath
        $file = ''; $ver = ''
        if ($hit) { $file = $hit.FileName; $ver = $hit.Version }
        $rows += (@((& $esc $app.name), (& $esc (Get-AppFolderName $app)), (& $esc $file), (& $esc $ver),
                    (& $esc $app.install_switches), (& $esc $app.source)) -join ',')
    }
    Set-Content -LiteralPath (Join-Path $stagingPath '_index.csv') -Value ($rows -join "`r`n") -Encoding UTF8
}

function Sync-SelectedInstallers {
    <#
        For each selected app, find the best installer in the repo. If it's a different file or a
        newer version than the catalog entry, update the catalog entry to match it (dynamic update).
        Returns the apps that still have no installer.
    #>
    $missingList = @()
    foreach ($app in @($script:selected)) {
        $hit = Find-AppInstaller -App $app -StagingRoot $stagingPath
        if (-not $hit) { $missingList += $app; continue }
        $props = @($app.PSObject.Properties.Name)
        $curVer = if ($props -contains 'version') { [string]$app.version } else { '' }
        $changed = (-not $hit.IsExpected) -or ($hit.Version -and $curVer -and $hit.Version -ne $curVer)
        if (-not $changed) { continue }
        $entry = Set-InstallerOverride -App $app -FileName $hit.FileName -Version $hit.Version
        Update-Selection -Old $app -New $entry
        $vtxt = if ($hit.Version) { "v$($hit.Version)" } else { 'version unknown' }
        Write-Host ("  {0}: using {1} ({2}) - catalog entry updated to '{3}'." -f (Get-BaseAppName ([string]$app.name)), $hit.FileName, $vtxt, $entry.name) -ForegroundColor Green
        if ($hit.Candidates -gt 1) { Write-Host ("        ({0} installers in the folder; picked the highest version)" -f $hit.Candidates) -ForegroundColor DarkGray }
    }
    return $missingList
}

Write-Host ""
Write-Host "Checking the repo for installers (newest version in each app folder wins)..." -ForegroundColor Yellow
$missing = @(Sync-SelectedInstallers)

if ($missing.Count -gt 0) {
    Write-Host ("  MISSING {0} installer(s):" -f $missing.Count) -ForegroundColor Red
    $missing | ForEach-Object { "    - {0}   (any {1} file, e.g. {2})" -f $_.name, [IO.Path]::GetExtension([string]$_.installer), $_.installer | Write-Host }
    Write-Host ""

    if (Read-YesNo "Provide the missing installer files now? (opens a file picker for each one)" -Default $true) {
        $lastDir = $null
        $skipped = @()
        $i = 0
        foreach ($app in $missing) {
            $i++
            Write-Host ""
            Write-Host ("[{0}/{1}] {2}" -f $i, $missing.Count, $app.name) -ForegroundColor Cyan
            Write-Host ("        catalog file: {0}  (your own file/version is fine)" -f $app.installer)
            Write-Host ("        source      : {0}" -f $app.source) -ForegroundColor DarkGray
            $done = $false
            while (-not $done) {
                $choice = Read-Menu -Title "  How do you want to provide it?" -Options @(
                    "Browse for the file (opens a window)",
                    "Type or paste a file path",
                    "Remove this app from the deployment",
                    "Leave it missing for now"
                ) -Default 1
                $f = $null
                switch ($choice) {
                    1 {
                        $f = Show-InstallerPicker -Title ("Select installer for {0}" -f (Get-BaseAppName ([string]$app.name))) `
                                                  -ExpectedName $app.installer -InitialDir $lastDir
                        $f = @($f | Where-Object { $_ }) | Select-Object -First 1
                        if (-not $f) { Write-Host "  No file chosen." -ForegroundColor Yellow }
                    }
                    2 {
                        $f = Read-Host "  Full path to installer (blank to go back)"
                        if ([string]::IsNullOrWhiteSpace($f)) { $f = $null } else { $f = $f.Trim().Trim('"') }
                    }
                    3 { $skipped += [string]$app.name; Write-Host "  Removed from this run." -ForegroundColor Yellow; $done = $true }
                    4 { $done = $true }
                }
                if ($f) {
                    $entry = Register-ProvidedInstaller -App $app -SourceFile $f -StagingRoot $stagingPath
                    if ($entry) {
                        Update-Selection -Old $app -New $entry
                        Write-AppReadme -App $entry -AppDir (Join-Path $stagingPath (Get-AppFolderName $entry))
                        $lastDir = Split-Path -Parent $f; $done = $true
                    }
                }
            }
        }
        if ($skipped.Count -gt 0) {
            $selected = @($selected | Where-Object { $skipped -notcontains [string]$_.name })
            if ($selected.Count -eq 0) {
                Write-Host "No apps left to deploy." -ForegroundColor Red
                Read-Host "Press ENTER to exit"; exit 1
            }
        }
        Write-Host ""
        Write-Host "Re-checking the repo..." -ForegroundColor Yellow
        $missing = @(Sync-SelectedInstallers)
    }

    if ($missing.Count -gt 0) {
        Write-Host ("  STILL MISSING {0} installer(s):" -f $missing.Count) -ForegroundColor Red
        $missing | ForEach-Object {
            "    - {0}" -f $_.name | Write-Host
            "        drop any {0} into: {1}\{2}\" -f [IO.Path]::GetExtension([string]$_.installer), $stagingPath, (Get-AppFolderName $_) | Write-Host
        }
        if (-not (Read-YesNo "Continue anyway? (missing apps will error out at deploy)" -Default $false)) {
            Write-RepoIndex
            Write-Host "Fill in the listed installers and re-run." -ForegroundColor Yellow
            Read-Host "Press ENTER to exit"
            exit 1
        }
    } else {
        Write-Host "  All required installers present." -ForegroundColor Green
    }
} else {
    Write-Host "  All required installers present." -ForegroundColor Green
}
Write-RepoIndex

# Names handed to the deploy engine (rebuilt here because entries may have been updated above)
$patterns = @()
foreach ($item in $selected) { $patterns += [string]$item.name }

# ---------------------------------------------------------------------------
# Step 4: credentials
# ---------------------------------------------------------------------------
Write-Host ""
# Local-only runs never need remote credentials.
$isLocalOnly = ($targetMode -eq 1)
if ($isLocalOnly) {
    $useCred = $false
    Write-Host ""
    Write-Host "STEP 4 - Skipped (local install; using current elevated session)." -ForegroundColor DarkYellow
} else {
    Write-Host ""
    $useCred = Read-YesNo "STEP 4 - Supply credentials to reach the target machines? (yes for workgroup or cross-domain)" -Default $true
}
$cred = $null
if ($useCred) {
    Write-Host "  Enter an account with LOCAL ADMIN rights on each target." -ForegroundColor Cyan
    Write-Host "  Format: DOMAIN\User, or .\LocalAdmin, or MACHINE\LocalAdmin" -ForegroundColor DarkCyan
    $cred = Get-Credential -Message "Local admin credentials for target workstations"
}

# If local-only and NOT elevated, warn now - installers will fail otherwise.
if ($isLocalOnly) {
    $isAdmin = $true
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        # Non-Windows or restricted runtime - skip the check
        $isAdmin = $true
    }
    if (-not $isAdmin) {
        Write-Host ""
        Write-Host "WARNING: This PowerShell session is NOT elevated (not running as Administrator)." -ForegroundColor Red
        Write-Host "         Silent installers will fail with access-denied errors." -ForegroundColor Red
        Write-Host "         Close this window, right-click Start.cmd, and choose Run as administrator." -ForegroundColor Yellow
        if (-not (Read-YesNo "Continue anyway?" -Default $false)) {
            Read-Host "Press ENTER to exit"; exit 1
        }
    }
}

# ---------------------------------------------------------------------------
# Step 5: dry run or real?
# ---------------------------------------------------------------------------
Write-Host ""
$mode = Read-Menu -Title "STEP 5 - Ready to go. What do you want to do?" -Options @(
    "Dry run  (enumerate targets, validate staging, show plan; do NOT install)",
    "Deploy   (copy installers and run them silently)"
) -Default 1
$testOnly = ($mode -eq 1)

# ---------------------------------------------------------------------------
# Confirmation
# ---------------------------------------------------------------------------
Show-Banner
Write-Host "===== Review =====" -ForegroundColor Yellow
"Target source : {0}" -f $targetSource | Write-Host
if ($targetSource -eq 'AD' -and $searchBase) { "Search base   : {0}" -f $searchBase | Write-Host }
if ($hostsFile) { "Hosts file    : {0}" -f $hostsFile | Write-Host }
"Staging path  : {0}" -f $stagingPath | Write-Host
"Apps selected : {0}" -f $selected.Count | Write-Host
$selected | ForEach-Object { "                * $($_.name)" | Write-Host }
$credLabel = if ($cred) { $cred.UserName } else { '(current user)' }
$modeLabel = if ($testOnly) { 'DRY RUN' } else { 'REAL DEPLOY' }
"Credential    : {0}" -f $credLabel | Write-Host
"Mode          : {0}" -f $modeLabel | Write-Host
Write-Host "==================" -ForegroundColor Yellow
Write-Host ""
if (-not (Read-YesNo "Proceed?" -Default $true)) {
    Write-Host "Cancelled." -ForegroundColor Yellow
    Read-Host "Press ENTER to exit"; exit 0
}

# ---------------------------------------------------------------------------
# Invoke the deployment engine
# ---------------------------------------------------------------------------
$deployScript = Join-Path $PSScriptRoot 'Deploy-MESilentInstall.ps1'
if (-not (Test-Path $deployScript)) { throw "Deploy-MESilentInstall.ps1 not found next to this wizard." }

$params = @{
    TargetSource = $targetSource
    StagingPath  = $stagingPath
    CatalogPath  = $CatalogPath
    Apps         = $patterns
    Pause        = $true
}
if ($hostsFile)  { $params.HostsFile  = $hostsFile }
if ($searchBase) { $params.SearchBase = $searchBase }
if ($cred)       { $params.Credential = $cred }
if ($testOnly)   { $params.TestOnly   = $true }

Write-Host ""
Write-Host "Handing off to Deploy-MESilentInstall.ps1 ..." -ForegroundColor Cyan
Write-Host ""
& $deployScript @params

Write-Host ""
Read-Host "All done. Press ENTER to close this window"
