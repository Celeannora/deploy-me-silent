<#
.SYNOPSIS
    Silent software deployment to Windows workstations using the ManageEngine
    Endpoint Central silent-install command database.

.DESCRIPTION
    - Enumerates targets from Active Directory (workstation OS filter, optional
      OU / SearchBase) OR reads a plain-text hosts file (one host per line).
    - Presents an interactive picker over the full ManageEngine silent-install
      catalog (SoftwareCatalog.json, ~2,700 apps) so the admin can select any
      subset.
    - Copies the required installers from a local staging folder to each target
      (admin$ share), then executes each installer silently with the exact
      switches published by ManageEngine, forcing /norestart-equivalent flags.
    - Tries three remote execution methods in order and falls back on failure:
        1. PowerShell Remoting (Invoke-Command over WinRM)
        2. PsExec.exe   (if present next to this script or on PATH)
        3. Scheduled Task push (schtasks.exe /S \\host  SYSTEM one-shot)
    - Writes a single, timestamped central log file on the admin workstation.

    Reboots are suppressed for every app: the ManageEngine switches already
    include /norestart or equivalent, and the script never issues a reboot.

.PARAMETER TargetSource
    'AD'        Query Active Directory (default)
    'HostsFile' Read -HostsFile

.PARAMETER SearchBase
    Optional AD SearchBase DN, e.g. 'OU=Workstations,DC=corp,DC=local'.
    If omitted the whole domain is searched.

.PARAMETER HostsFile
    Path to a text file with one hostname per line. Blank lines and lines
    starting with '#' are ignored.

.PARAMETER StagingPath
    Local folder on the admin workstation containing the installers referenced
    by the catalog entries (matched on installer filename). Required.

.PARAMETER CatalogPath
    Path to SoftwareCatalog.json. Defaults to the file next to this script.

.PARAMETER Apps
    Optional array of catalog "name" values (or wildcard patterns) to install
    non-interactively. If omitted an Out-GridView / console picker is shown.

.PARAMETER LogPath
    Central log file path. Defaults to
    .\Logs\Deploy-MESilentInstall_<yyyyMMdd_HHmmss>.log next to this script.

.PARAMETER Credential
    Optional PSCredential used for remote execution and \\host\admin$ copy.

.PARAMETER ThrottleLimit
    Parallel host count. Default 16.

.PARAMETER TestOnly
    Enumerate targets and print the plan; do not copy or execute anything.

.EXAMPLE
    .\Deploy-MESilentInstall.ps1 -TargetSource AD `
        -SearchBase 'OU=Workstations,DC=corp,DC=local' `
        -StagingPath 'C:\SW\Staging' `
        -Apps '7-Zip*','Google Chrome*','Notepad*'

.EXAMPLE
    .\Deploy-MESilentInstall.ps1 -TargetSource HostsFile `
        -HostsFile .\hosts.txt -StagingPath D:\Installers

.NOTES
    Data source        : ManageEngine Endpoint Central silent-install DB
                         https://www.manageengine.com/products/desktop-central/software-installation/windows-software.html
    Requires (admin)   : RSAT ActiveDirectory module for AD mode.
    Requires (targets) : SMB admin$ reachable + one of WinRM / PsExec / schtasks.
    Runs as            : A domain admin (or account with local admin on every
                         target) on the admin workstation.
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Script parameters are read inside functions (script scope).')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseUsingScopeModifierInNewRunspaces', '', Justification = 'Thread job values are passed via -ArgumentList/param().')]
[CmdletBinding()]
param(
    [switch]$Pause,
    [switch]$Debug2,

    [ValidateSet('AD','HostsFile')]
    [string]$TargetSource = 'AD',

    [string]$SearchBase,

    [string]$HostsFile,

    [Parameter(Mandatory=$true)]
    [string]$StagingPath,

    [string]$CatalogPath = (Join-Path $PSScriptRoot 'SoftwareCatalog.json'),

    [string[]]$Apps,

    [string]$LogPath = (Join-Path $PSScriptRoot ("Logs\Deploy-MESilentInstall_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))),

    [pscredential]$Credential,

    [int]$ThrottleLimit = 16,

    [switch]$TestOnly
)

# ---------------------------------------------------------------------------
# Global error surfacing so nothing gets swallowed
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Continue'          # don't die silently on non-terminating errors
# Set-StrictMode intentionally NOT 'Latest' -- some AD/CIM objects and single-
# element collections lose properties under strict mode. Version 2 is a good
# balance: catches undeclared vars but tolerates missing properties.
Set-StrictMode -Version 2
. (Join-Path $PSScriptRoot 'MECommon.ps1')
if ($Debug2) { $VerbosePreference = 'Continue'; $DebugPreference = 'Continue' }

trap {
    Write-Host ""
    Write-Host "==================== UNHANDLED EXCEPTION ====================" -ForegroundColor Red
    Write-Host ("MESSAGE : {0}" -f $_.Exception.Message) -ForegroundColor Red
    Write-Host ("TYPE    : {0}" -f $_.Exception.GetType().FullName) -ForegroundColor Red
    Write-Host ("AT      : {0}:{1}" -f $_.InvocationInfo.ScriptName, $_.InvocationInfo.ScriptLineNumber) -ForegroundColor Red
    Write-Host ("LINE    : {0}" -f $_.InvocationInfo.Line.Trim()) -ForegroundColor Yellow
    Write-Host "STACK   :" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor DarkYellow
    Write-Host "=============================================================" -ForegroundColor Red
    try { Add-Content -LiteralPath $LogPath -Value ("UNHANDLED: {0}`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace) -Encoding UTF8 } catch { Write-Verbose ('Could not write crash entry to log: ' + $_.Exception.Message) }
    Write-Host ""
    Read-Host "Press ENTER to close this window"
    exit 1
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
$logDir = Split-Path -Parent $LogPath
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogLock = New-Object System.Object

function Write-DeployLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','STEP')][string]$Level = 'INFO',
        [string]$Target = '-',
        [string]$App    = '-'
    )
    $line = "{0}  {1,-5}  {2,-24}  {3,-40}  {4}" -f `
        (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Target, $App, $Message
    [System.Threading.Monitor]::Enter($script:LogLock)
    try {
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    } finally {
        [System.Threading.Monitor]::Exit($script:LogLock)
    }
    $color = @{INFO='Gray';WARN='Yellow';ERROR='Red';OK='Green';STEP='Cyan'}[$Level]
    Write-Host $line -ForegroundColor $color
}

Write-DeployLog -Level STEP -Message "=== Deploy-MESilentInstall starting ==="
Write-DeployLog -Message ("PSVersion={0}  User={1}  Host={2}" -f `
    $PSVersionTable.PSVersion, $env:USERNAME, $env:COMPUTERNAME)

# ---------------------------------------------------------------------------
# Load catalog
# ---------------------------------------------------------------------------
if (-not (Test-Path $CatalogPath)) {
    Write-DeployLog -Level ERROR -Message "Catalog not found: $CatalogPath"
    throw "Catalog file missing."
}
$catalog = @(Get-Content -Raw -LiteralPath $CatalogPath | ConvertFrom-Json)
Write-DeployLog -Message ("Catalog loaded: {0} entries from {1}" -f $catalog.Count, $CatalogPath)
# Merge user-defined entries / version overrides recorded by the wizard (CustomCatalog.json)
$customCatalogPath = Join-Path (Split-Path -Parent $CatalogPath) 'CustomCatalog.json'
try {
    $before = $catalog.Count
    $catalog = @(Merge-CustomCatalog -Catalog $catalog -CustomPath $customCatalogPath)
    if (Test-Path -LiteralPath $customCatalogPath) {
        Write-DeployLog -Message ("Custom catalog merged from {0} ({1} -> {2} entries)" -f $customCatalogPath, $before, $catalog.Count)
    }
} catch {
    Write-DeployLog -Level WARN -Message ("CustomCatalog.json unreadable, ignored: {0}" -f $_.Exception.Message)
}

# ---------------------------------------------------------------------------
# Resolve target hosts
# ---------------------------------------------------------------------------
function Get-Targets {
    if ($TargetSource -eq 'AD') {
        # Preflight: is the AD module actually available?
        if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
            Write-DeployLog -Level ERROR -Message "ActiveDirectory PowerShell module is not installed on this machine."
            Write-DeployLog -Level ERROR -Message "Install it with:  Add-WindowsCapability -Online -Name 'Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0'"
            Write-DeployLog -Level ERROR -Message "...or switch to hosts-file mode:  -TargetSource HostsFile -HostsFile .\hosts.txt"
            throw "ActiveDirectory module missing. See log for remediation."
        }
        try {
            Import-Module ActiveDirectory -ErrorAction Stop
        } catch {
            Write-DeployLog -Level ERROR -Message ("Failed to import ActiveDirectory module: {0}" -f $_.Exception.Message)
            throw
        }
        if (-not (Get-Command Get-ADComputer -ErrorAction SilentlyContinue)) {
            Write-DeployLog -Level ERROR -Message "Get-ADComputer not found even after importing ActiveDirectory module. Use -TargetSource HostsFile instead."
            throw "Get-ADComputer unavailable."
        }
        # Workstation OS filter (excludes Server SKUs).
        $filter = "OperatingSystem -like '*Windows*' -and OperatingSystem -notlike '*Server*' -and Enabled -eq 'True'"
        $params = @{ Filter = $filter; Properties = 'DNSHostName','OperatingSystem' }
        if ($SearchBase) { $params.SearchBase = $SearchBase }
        $sbLabel = if ($SearchBase) { $SearchBase } else { '<domain root>' }
        Write-DeployLog -Level STEP -Message ("Querying AD (SearchBase='{0}')..." -f $sbLabel)
        $comps = Get-ADComputer @params |
                 Where-Object { $_.DNSHostName } |
                 Select-Object -ExpandProperty DNSHostName
        return $comps | Sort-Object -Unique
    }
    else {
        if (-not $HostsFile -or -not (Test-Path $HostsFile)) {
            throw "HostsFile mode requires -HostsFile pointing at an existing file."
        }
        return Get-Content -LiteralPath $HostsFile |
               ForEach-Object { ($_ -split '#',2)[0].Trim() } |
               Where-Object { $_ } |
               Sort-Object -Unique
    }
}

$targets = @(Get-Targets)   # force array so .Count works on single-host results
Write-DeployLog -Level OK -Message ("Resolved {0} target host(s)." -f $targets.Count)
if ($targets.Count -eq 0) { throw "No targets resolved." }

# ---------------------------------------------------------------------------
# Select apps
# ---------------------------------------------------------------------------
function Select-Apps {
    if ($Apps) {
        $sel = @()
        foreach ($pat in $Apps) {
            # Exact name first (names can contain [ ] which -like treats as wildcards)
            $found = @($catalog | Where-Object { [string]$_.name -eq $pat })
            if ($found.Count -eq 0) { $found = @($catalog | Where-Object { [string]$_.name -like $pat }) }
            if ($found.Count -eq 0) { Write-DeployLog -Level WARN -Message "No catalog match for pattern: $pat" }
            $sel += $found
        }
        return $sel | Sort-Object name -Unique
    }
    # interactive picker
    $picker = $catalog | Select-Object name, installer, install_switches, source
    if (Get-Command Out-GridView -ErrorAction SilentlyContinue) {
        return $picker | Out-GridView -Title "Select apps to deploy (Ctrl+Click for multi)" -PassThru |
               ForEach-Object { $c = $_; $catalog | Where-Object { $_.name -eq $c.name } } |
               Sort-Object name -Unique
    }
    # console fallback
    for ($i=0; $i -lt $catalog.Count; $i++) { "{0,5}  {1}" -f $i, $catalog[$i].name | Write-Host }
    $ans = Read-Host "Enter comma-separated indices (e.g. 12,44,88)"
    return $ans -split ',' | ForEach-Object { $catalog[[int]$_.Trim()] }
}

$selected = @(Select-Apps)   # force array
if (-not $selected -or $selected.Count -eq 0) { throw "No apps selected." }
Write-DeployLog -Level STEP -Message ("Selected {0} app(s):" -f $selected.Count)
$selected | ForEach-Object { Write-DeployLog -App $_.name -Message ("Installer='{0}' Switches='{1}'" -f $_.installer, $_.install_switches) }

# ---------------------------------------------------------------------------
# Verify installers exist in staging (accept flat OR scaffolded layout)
# ---------------------------------------------------------------------------
[System.Collections.ArrayList]$missing = @()
foreach ($app in $selected) {
    # Newest installer of the right type in the app's repo folder wins (dynamic version pickup)
    $hit = Find-AppInstaller -App $app -StagingRoot $StagingPath
    if (-not $hit) { [void]$missing.Add($app); continue }
    Add-Member -InputObject $app -NotePropertyName '_relPath' -NotePropertyValue $hit.RelPath -Force
    if (-not $hit.IsExpected) {
        $v = if ($hit.Version) { "v$($hit.Version)" } else { 'version unknown' }
        Write-DeployLog -App $app.name -Message ("Using repo installer '{0}' ({1}) instead of catalog file '{2}'" -f $hit.RelPath, $v, $app.installer)
    }
}
if ($missing.Count -gt 0) {
    Write-DeployLog -Level ERROR -Message ("Missing {0} installer(s) in staging '{1}':" -f $missing.Count, $StagingPath)
    $missing | ForEach-Object {
        Write-DeployLog -Level ERROR -App $_.name -Message ("Need any {0} in {1}\  (e.g. {2}; source: {3})" -f [IO.Path]::GetExtension([string]$_.installer), (Get-AppFolderName $_), $_.installer, $_.source)
    }
    throw "Place the listed installer files in $StagingPath and re-run."
}
Write-DeployLog -Level OK -Message "All required installers present in staging."

if ($TestOnly) {
    Write-DeployLog -Level STEP -Message "TestOnly: exiting before any remote action."
    return
}

# ---------------------------------------------------------------------------
# Remote-exec helpers
# ---------------------------------------------------------------------------
$psexec = @(
    (Join-Path $PSScriptRoot 'PsExec.exe'),
    (Join-Path $PSScriptRoot 'PsExec64.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $psexec) { $psexec = (Get-Command PsExec.exe -ErrorAction SilentlyContinue).Source }

function Test-Reachable {
    param([string]$ComputerName)
    return (Test-Connection -ComputerName $ComputerName -Count 1 -Quiet -ErrorAction SilentlyContinue)
}

function Test-WinRM {
    param([string]$ComputerName,[pscredential]$Cred)
    try {
        $p = @{ ComputerName = $ComputerName; ErrorAction = 'Stop' }
        if ($Cred) { $p.Credential = $Cred }
        Test-WSMan @p | Out-Null
        return $true
    } catch { return $false }
}

function Copy-ToRemote {
    param([string]$ComputerName,[string]$LocalDir,[pscredential]$Cred)
    $remoteRoot = "\\$ComputerName\admin$\Temp\MESilent"
    # UNC copy - Copy-Item handles credentials when a temporary PSDrive is used.
    if ($Cred) {
        $drive = "MEC_" + ([guid]::NewGuid().ToString('N').Substring(0,6))
        try {
            New-PSDrive -Name $drive -PSProvider FileSystem -Root ("\\$ComputerName\admin$") -Credential $Cred -Scope Local -ErrorAction Stop | Out-Null
            $dest = Join-Path ("${drive}:") 'Temp\MESilent'
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Copy-Item -Path (Join-Path $LocalDir '*') -Destination $dest -Recurse -Force -ErrorAction Stop
        } finally {
            Remove-PSDrive -Name $drive -Force -ErrorAction SilentlyContinue
        }
    } else {
        if (-not (Test-Path $remoteRoot)) { New-Item -ItemType Directory -Path $remoteRoot -Force | Out-Null }
        Copy-Item -Path (Join-Path $LocalDir '*') -Destination $remoteRoot -Recurse -Force -ErrorAction Stop
    }
    return 'C:\Windows\Temp\MESilent'    # local path on the target
}

function Build-InstallScript {
    param($AppList,[string]$RemoteDir)
    # Emits a script block string executed on the target. Runs each installer
    # with the exact ManageEngine switches, adds /norestart-equivalent flags
    # for known engines, captures exit codes, and writes a per-host result CSV
    # back into $RemoteDir\result.csv.
    $json = ($AppList | ConvertTo-Json -Compress -Depth 4) -replace "'","''"
@"
`$ErrorActionPreference = 'Continue'
`$dir  = '$RemoteDir'
`$apps = '$json' | ConvertFrom-Json
`$results = @()
foreach (`$a in `$apps) {
    # Prefer the resolved relative path computed at preflight (scaffold-aware).
    `$rel = if (`$a.PSObject.Properties.Name -contains '_relPath' -and `$a._relPath) { `$a._relPath } else { `$a.installer }
    `$installer = Join-Path `$dir `$rel
    `$switches  = `$a.install_switches
    `$ext = [IO.Path]::GetExtension(`$installer).ToLower()
    # Force no-reboot for common engines even if the catalog omitted it.
    switch (`$ext) {
        '.msi' { if (`$switches -notmatch '/norestart') { `$switches = "`$switches /norestart".Trim() }
                 `$cmd = 'msiexec.exe'
                 `$args = "/i `"`$installer`" `$switches"
               }
        default {
                 if (`$switches -notmatch '(?i)/norestart|/noreboot|REBOOT=ReallySuppress') {
                     `$switches = "`$switches /norestart".Trim()
                 }
                 `$cmd  = `$installer
                 `$args = `$switches
               }
    }
    `$t0 = Get-Date
    try {
        `$p = Start-Process -FilePath `$cmd -ArgumentList `$args -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        `$code = `$p.ExitCode
    } catch {
        `$code = -1
        `$err  = `$_.Exception.Message
    }
    # MSI success codes: 0, 1641 (reboot initiated - suppressed), 3010 (reboot required).
    `$ok = (`$code -eq 0) -or (`$code -eq 3010) -or (`$code -eq 1641)
    `$results += [pscustomobject]@{
        Host      = `$env:COMPUTERNAME
        App       = `$a.name
        Installer = `$a.installer
        Command   = "`$cmd `$args"
        ExitCode  = `$code
        Success   = `$ok
        StartedAt = `$t0.ToString('s')
        DurationS = [int]((Get-Date) - `$t0).TotalSeconds
        Error     = `$err
    }
}
`$results | Export-Csv -Path (Join-Path `$dir 'result.csv') -NoTypeInformation -Encoding UTF8
`$results | ConvertTo-Json -Depth 4
"@
}

function Invoke-OnHost-WinRM {
    param([string]$ComputerName,[string]$ScriptText,[pscredential]$Cred)
    $sb = [scriptblock]::Create($ScriptText)
    $p = @{ ComputerName = $ComputerName; ScriptBlock = $sb; ErrorAction = 'Stop' }
    if ($Cred) { $p.Credential = $Cred }
    return Invoke-Command @p
}

function Invoke-OnHost-PsExec {
    param([string]$ComputerName,[string]$ScriptText,[pscredential]$Cred)
    # Stage the script as a file on the target then execute via PsExec -s.
    $localScript = Join-Path $env:TEMP ("me_$($ComputerName)_$([guid]::NewGuid().ToString('N')).ps1")
    Set-Content -LiteralPath $localScript -Value $ScriptText -Encoding UTF8
    try {
        $remoteScriptUNC = "\\$ComputerName\admin$\Temp\MESilent\_run.ps1"
        Copy-Item -LiteralPath $localScript -Destination $remoteScriptUNC -Force
        $psargs = @('-accepteula','-nobanner','-s','-h','\\'+$ComputerName,
                    'powershell.exe','-NoProfile','-ExecutionPolicy','Bypass',
                    '-File','C:\Windows\Temp\MESilent\_run.ps1')
        if ($Cred) {
            $psargs = @('-u',$Cred.UserName,'-p',$Cred.GetNetworkCredential().Password) + $psargs
        }
        $o = & $psexec @psargs 2>&1
        return $o
    } finally {
        Remove-Item -LiteralPath $localScript -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OnHost-SchTask {
    param([string]$ComputerName,[string]$ScriptText,[pscredential]$Cred)
    $remoteScriptUNC = "\\$ComputerName\admin$\Temp\MESilent\_run.ps1"
    Set-Content -LiteralPath $remoteScriptUNC -Value $ScriptText -Encoding UTF8
    $taskName = "MESilent_" + (Get-Date -Format 'yyyyMMddHHmmss')
    $tr = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Windows\Temp\MESilent\_run.ps1'
    $create = @('/S',$ComputerName,'/Create','/TN',$taskName,'/RU','SYSTEM','/SC','ONCE',
                '/ST','23:59','/TR',$tr,'/RL','HIGHEST','/F')
    $run    = @('/S',$ComputerName,'/Run','/TN',$taskName)
    $query  = @('/S',$ComputerName,'/Query','/TN',$taskName,'/V','/FO','LIST')
    $delete = @('/S',$ComputerName,'/Delete','/TN',$taskName,'/F')
    if ($Cred) {
        $u = $Cred.UserName; $p = $Cred.GetNetworkCredential().Password
        $create = @('/U',$u,'/P',$p) + $create
        $run    = @('/U',$u,'/P',$p) + $run
        $query  = @('/U',$u,'/P',$p) + $query
        $delete = @('/U',$u,'/P',$p) + $delete
    }
    & schtasks.exe @create | Out-Null
    & schtasks.exe @run    | Out-Null
    # Poll every 10s up to 30 min.
    for ($i=0; $i -lt 180; $i++) {
        Start-Sleep -Seconds 10
        $q = & schtasks.exe @query 2>$null
        if ($q -match 'Status:\s+Ready' -or $q -match 'Last Result') {
            if ($q -notmatch 'Status:\s+Running') { break }
        }
    }
    & schtasks.exe @delete | Out-Null
    # Pull result.csv
    $csv = "\\$ComputerName\admin$\Temp\MESilent\result.csv"
    if (Test-Path $csv) { return Import-Csv $csv }
    return $null
}

# ---------------------------------------------------------------------------
# Localhost detection + local install path
# ---------------------------------------------------------------------------
function Test-IsLocalHost {
    param([string]$ComputerName)
    if ([string]::IsNullOrWhiteSpace($ComputerName)) { return $false }
    $n = $ComputerName.Trim().ToLower()
    $localAliases = @('localhost','127.0.0.1','::1','.',
                      $env:COMPUTERNAME.ToLower(),
                      "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)".ToLower().TrimEnd('.'))
    if ($localAliases -contains $n) { return $true }
    # Match any local IPv4 too
    try {
        $ips = @([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) |
                 ForEach-Object { $_.IPAddressToString.ToLower() })
        if ($ips -contains $n) { return $true }
    } catch { Write-Verbose ('Local IP lookup failed: ' + $_.Exception.Message) }
    return $false
}

function Invoke-LocalInstall {
    param([string]$ComputerName,$AppList,[string]$StagingPath)
    Write-DeployLog -Level STEP -Target $ComputerName -Message "LOCAL install: running installers directly from staging (no copy, no remote exec)."
    # Build the same install script text and run it in-process against the staging folder.
    $runScript = Build-InstallScript -AppList $AppList -RemoteDir $StagingPath
    $tmpScript = Join-Path $env:TEMP ("MESilent_local_{0}.ps1" -f ([guid]::NewGuid().ToString('N').Substring(0,8)))
    Set-Content -LiteralPath $tmpScript -Value $runScript -Encoding UTF8
    try {
        # Execute in the current session's runspace so we capture $results directly.
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $tmpScript 2>&1
        Process-Result -ComputerName $ComputerName -Out $out -Method 'Local'
    } finally {
        Remove-Item -LiteralPath $tmpScript -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------------------
# Per-host worker
# ---------------------------------------------------------------------------
function Invoke-TargetHost {
    param([string]$ComputerName,$AppList,[string]$StagingPath,[pscredential]$Cred)

    # Local machine? Skip the whole ping/copy/remote-exec dance.
    if (Test-IsLocalHost -ComputerName $ComputerName) {
        Invoke-LocalInstall -ComputerName $ComputerName -AppList $AppList -StagingPath $StagingPath
        return
    }

    if (-not (Test-Reachable -ComputerName $ComputerName)) {
        Write-DeployLog -Level ERROR -Target $ComputerName -Message "Unreachable (ping failed). Skipped."
        return
    }
    Write-DeployLog -Level STEP -Target $ComputerName -Message "Copying installers to \\$ComputerName\admin$\Temp\MESilent ..."
    try {
        $remoteDir = Copy-ToRemote -ComputerName $ComputerName -LocalDir $StagingPath -Cred $Cred
    } catch {
        Write-DeployLog -Level ERROR -Target $ComputerName -Message ("Copy failed: {0}" -f $_.Exception.Message)
        return
    }
    $runScript = Build-InstallScript -AppList $AppList -RemoteDir $remoteDir

    # 1) WinRM
    if (Test-WinRM -ComputerName $ComputerName -Cred $Cred) {
        Write-DeployLog -Target $ComputerName -Message "WinRM reachable - attempting Invoke-Command."
        try {
            $out = Invoke-OnHost-WinRM -ComputerName $ComputerName -ScriptText $runScript -Cred $Cred
            Process-Result -ComputerName $ComputerName -Out $out -Method 'WinRM'
            return
        } catch {
            Write-DeployLog -Level WARN -Target $ComputerName -Message ("WinRM run failed: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-DeployLog -Target $ComputerName -Message "WinRM not reachable - skipping to PsExec."
    }

    # 2) PsExec
    if ($psexec) {
        Write-DeployLog -Target $ComputerName -Message ("Trying PsExec ({0}) ..." -f $psexec)
        try {
            $out = Invoke-OnHost-PsExec -ComputerName $ComputerName -ScriptText $runScript -Cred $Cred
            Process-Result -ComputerName $ComputerName -Out $out -Method 'PsExec'
            return
        } catch {
            Write-DeployLog -Level WARN -Target $ComputerName -Message ("PsExec failed: {0}" -f $_.Exception.Message)
        }
    } else {
        Write-DeployLog -Target $ComputerName -Message "PsExec.exe not found - skipping."
    }

    # 3) Scheduled task
    Write-DeployLog -Target $ComputerName -Message "Trying Scheduled Task push (schtasks) ..."
    try {
        $out = Invoke-OnHost-SchTask -ComputerName $ComputerName -ScriptText $runScript -Cred $Cred
        Process-Result -ComputerName $ComputerName -Out $out -Method 'SchTask'
        return
    } catch {
        Write-DeployLog -Level ERROR -Target $ComputerName -Message ("SchTask failed: {0}" -f $_.Exception.Message)
    }

    Write-DeployLog -Level ERROR -Target $ComputerName -Message "All three remote-exec methods failed."
}

function Process-Result {
    param([string]$ComputerName,$Out,[string]$Method)
    if (-not $Out) {
        Write-DeployLog -Level WARN -Target $ComputerName -Message "Method=$Method returned no result data."
        return
    }
    # WinRM path returns JSON string, PsExec returns raw text, SchTask returns
    # imported CSV objects. Normalize.
    $rows = @()
    if ($Out -is [System.Array] -and $Out[0].PSObject.Properties.Name -contains 'App') {
        $rows = $Out
    } else {
        $joined = ($Out -join "`n").Trim()
        if ($joined) {
            try { $rows = $joined | ConvertFrom-Json } catch { $rows = @() }
        }
    }
    $rows = @($rows)
    if ($rows.Count -eq 0) {
        Write-DeployLog -Level WARN -Target $ComputerName -Message "Method=$Method - no parseable rows. Raw:`n$Out"
        return
    }
    foreach ($r in $rows) {
        $lvl = if ([bool]::Parse("$($r.Success)")) { 'OK' } else { 'ERROR' }
        Write-DeployLog -Level $lvl -Target $ComputerName -App $r.App -Message ("Method=$Method ExitCode={0} Duration={1}s Cmd={2}" -f `
            $r.ExitCode, $r.DurationS, $r.Command)
    }
}

# ---------------------------------------------------------------------------
# Fan out
# ---------------------------------------------------------------------------
Write-DeployLog -Level STEP -Message ("Deploying to {0} host(s) with ThrottleLimit={1} ..." -f $targets.Count, $ThrottleLimit)

$isPS7 = $PSVersionTable.PSVersion.Major -ge 7

if ($isPS7 -and $ThrottleLimit -gt 1) {
    # PowerShell 7+ parallel path via ForEach-Object -Parallel + Start-ThreadJob.
    # Each host runs in its own thread, calling this same script recursively in
    # single-host, single-thread mode against a temporary hosts file.
    $tempDir = Join-Path $env:TEMP ("MESilent_" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
    $appNames = @($selected | Select-Object -ExpandProperty name)
    [System.Collections.ArrayList]$jobs = @()
    foreach ($t in $targets) {
        $hostsTmp = Join-Path $tempDir ("$t.txt")
        Set-Content -LiteralPath $hostsTmp -Value $t -Encoding UTF8
        $childArgs = @(
            '-NoProfile','-ExecutionPolicy','Bypass','-File',$PSCommandPath,
            '-TargetSource','HostsFile','-HostsFile',$hostsTmp,
            '-StagingPath',$StagingPath,'-CatalogPath',$CatalogPath,
            '-LogPath',$LogPath,'-ThrottleLimit','1'
        )
        foreach ($n in $appNames) { $childArgs += @('-Apps',$n) }
        [void]$jobs.Add((Start-ThreadJob -ThrottleLimit $ThrottleLimit -ScriptBlock {
            param($exe,$a) & $exe @a
        } -ArgumentList (Get-Process -Id $PID).Path, $childArgs))
    }
    $jobs | Wait-Job | Receive-Job
    $jobs | Remove-Job -Force
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    # PS 5.1 or ThrottleLimit=1: sequential, safe and predictable.
    foreach ($t in $targets) {
        try   { Invoke-TargetHost -ComputerName $t -AppList $selected -StagingPath $StagingPath -Cred $Credential }
        catch { Write-DeployLog -Level ERROR -Target $t -Message ("Unhandled: {0}" -f $_.Exception.Message) }
    }
}

Write-DeployLog -Level STEP -Message ("=== Done. Central log: {0} ===" -f $LogPath)

if ($Pause) {
    Write-Host ""
    Read-Host "Press ENTER to close this window"
}
