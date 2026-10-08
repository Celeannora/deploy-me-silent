<#
    MECommon.ps1 - shared helpers for Start-Wizard.ps1 and Deploy-MESilentInstall.ps1
    (dot-sourced by both, so they agree on folder names, versions and catalog overrides).
    Windows PowerShell 5.1 compatible.
#>

function Get-SafeFolderName {
    param([string]$Name)
    $s = $Name -replace '[\\/:*?"<>|]', '_'
    $s = $s -replace '\s+', ' '
    $s = $s.Trim().TrimEnd('.')
    if ($s.Length -gt 120) { $s = $s.Substring(0,120).TrimEnd() }
    return $s
}

function Get-BaseAppName {
    # "Notepad++ (x64) (8.9.7)" -> "Notepad++ (x64)"; keeps (x64)/(MSI) tags, drops version groups.
    param([string]$Name)
    $b = $Name -replace '\(\s*v?\d[^()]*\)', ' '
    $b = $b -replace '\s+v?\d+(\.\d+)+\s*$', ''
    $b = ($b -replace '\s+', ' ').Trim()
    if (-not $b) { $b = $Name.Trim() }
    return $b
}

function Get-AppFolderName {
    # Version-less folder so new versions of the same app land in the same place.
    param($App)
    if ($App.PSObject.Properties.Name -contains 'base' -and $App.base) { return (Get-SafeFolderName ([string]$App.base)) }
    return (Get-SafeFolderName (Get-BaseAppName ([string]$App.name)))
}

function ConvertTo-VersionKey {
    param([string]$Text)
    $m = [regex]::Match([string]$Text, '\d+(?:\.\d+){0,3}')
    if (-not $m.Success) { return [version]'0.0.0.0' }
    $parts = @($m.Value -split '\.' | ForEach-Object { [int][Math]::Min([double]$_, [double][int]::MaxValue) })
    while ($parts.Count -lt 4) { $parts += 0 }
    return New-Object version $parts[0], $parts[1], $parts[2], $parts[3]
}

function Get-VersionFromFileName {
    param([string]$FileName)
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)
    $m = [regex]::Match($base, '(?<![\dA-Za-z])(\d+(?:[._]\d+){1,3})(?!\d)')
    if ($m.Success) { return ($m.Groups[1].Value -replace '_', '.') }
    return ''
}

function Get-InstallerMetadata {
    # Reads product name / version / vendor from an MSI (Property table) or EXE (version resource)
    param([string]$Path)
    $meta = [ordered]@{
        Path = $Path; FileName = [IO.Path]::GetFileName($Path)
        Ext = [IO.Path]::GetExtension($Path).ToLower()
        ProductName = ''; Version = ''; VersionSource = ''; Manufacturer = ''; Description = ''; Arch = ''; Engine = ''
    }
    if ($meta.Ext -eq '.msi') {
        $wi = $null; $db = $null
        try {
            $wi = New-Object -ComObject WindowsInstaller.Installer
            $db = $wi.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$wi,@($Path,0))
            foreach ($prop in 'ProductName','ProductVersion','Manufacturer') {
                $view = $db.GetType().InvokeMember('OpenView','InvokeMethod',$null,$db,@("SELECT Value FROM Property WHERE Property='$prop'"))
                [void]$view.GetType().InvokeMember('Execute','InvokeMethod',$null,$view,$null)
                $rec = $view.GetType().InvokeMember('Fetch','InvokeMethod',$null,$view,$null)
                if ($rec) {
                    $val = [string]$rec.GetType().InvokeMember('StringData','GetProperty',$null,$rec,1)
                    switch ($prop) { 'ProductName' { $meta.ProductName = $val } 'ProductVersion' { $meta.Version = $val } 'Manufacturer' { $meta.Manufacturer = $val } }
                }
                [void]$view.GetType().InvokeMember('Close','InvokeMethod',$null,$view,$null)
                [void][Runtime.InteropServices.Marshal]::ReleaseComObject($view)
            }
            try {
                $si  = $db.GetType().InvokeMember('SummaryInformation','GetProperty',$null,$db,0)
                $tpl = [string]$si.GetType().InvokeMember('Property','GetProperty',$null,$si,7)
                if ($tpl -match '(?i)x64|amd64|arm64') { $meta.Arch = 'x64' } elseif ($tpl) { $meta.Arch = 'x86' }
            } catch { Write-Verbose ('Could not read MSI summary info: ' + $_.Exception.Message) }
            $meta.Engine = 'MSI'
        } catch { Write-Verbose ('Could not read MSI properties: ' + $_.Exception.Message) } finally {
            if ($db) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($db) }
            if ($wi) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wi) }
        }
    } else {
        try {
            $vi = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
            $meta.ProductName  = [string]$vi.ProductName
            $meta.Version      = [string]$vi.ProductVersion
            $meta.Manufacturer = [string]$vi.CompanyName
            $meta.Description  = [string]$vi.FileDescription
        } catch { Write-Verbose ('Could not read EXE version info: ' + $_.Exception.Message) }
        # Sniff the installer engine so we can suggest the right silent switches
        try {
            $fs = [IO.File]::OpenRead($Path)
            $len = [int][Math]::Min($fs.Length, 8MB)
            $buf = New-Object byte[] $len
            [void]$fs.Read($buf, 0, $len); $fs.Close()
            $txt = [Text.Encoding]::ASCII.GetString($buf)
            if     ($txt -match 'Inno Setup')                    { $meta.Engine = 'Inno' }
            elseif ($txt -match 'Nullsoft|NSIS')                 { $meta.Engine = 'NSIS' }
            elseif ($txt -match '\.wixburn|WixBundle|WiX Toolset') { $meta.Engine = 'WixBurn' }
            elseif ($txt -match 'InstallShield')                 { $meta.Engine = 'InstallShield' }
        } catch { Write-Verbose ('Could not sniff installer engine: ' + $_.Exception.Message) }
    }
    if (-not $meta.Version) {
        $meta.Version = Get-VersionFromFileName $meta.FileName
        if ($meta.Version) { $meta.VersionSource = 'filename' }
    } elseif (-not $meta.VersionSource) { $meta.VersionSource = 'file properties' }
    if (-not $meta.Arch) {
        if ($meta.FileName -match '(?i)x64|amd64|win64|64bit|_64') { $meta.Arch = 'x64' }
    }
    return [pscustomobject]$meta
}


function Find-AppInstaller {
    <#
        Locates the installer to use for an app. Looks in the app's version-less folder (and the
        older versioned folder name), considers EVERY installer of the right type there, and picks
        the highest version (ties: newest file). Falls back to the exact catalog filename in the
        staging root. Returns $null if nothing usable is found.
    #>
    param($App,[string]$StagingRoot)
    $expected = [string]$App.installer
    $ext = [IO.Path]::GetExtension($expected).ToLower()
    $folders = @(Get-AppFolderName $App)
    $legacy  = Get-SafeFolderName ([string]$App.name)
    if ($folders -notcontains $legacy) { $folders += $legacy }

    $cands = @()
    foreach ($f in $folders) {
        $dir = Join-Path $StagingRoot $f
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        if ($ext -eq '.msi' -or $ext -eq '.exe') {
            $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq $ext })
        } else {
            $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ieq $expected })
        }
        foreach ($file in $files) { $cands += [pscustomobject]@{ File = $file; Rel = (Join-Path $f $file.Name) } }
    }
    if ($cands.Count -eq 0) {
        $flat = Join-Path $StagingRoot $expected
        if ($expected -and (Test-Path -LiteralPath $flat -PathType Leaf)) {
            $cands += [pscustomobject]@{ File = (Get-Item -LiteralPath $flat); Rel = $expected }
        }
    }
    if ($cands.Count -eq 0) { return $null }

    $best = $null; $bestKey = $null; $bestVer = ''
    foreach ($c in $cands) {
        $ver = ''
        if ($cands.Count -gt 1 -or $c.File.Name -ine $expected) {
            $ver = [string](Get-InstallerMetadata -Path $c.File.FullName).Version
        }
        $key = ConvertTo-VersionKey $ver
        if ($null -eq $best -or $key -gt $bestKey -or ($key -eq $bestKey -and $c.File.LastWriteTime -gt $best.File.LastWriteTime)) {
            $best = $c; $bestKey = $key; $bestVer = $ver
        }
    }
    return [pscustomobject]@{
        Path       = $best.File.FullName
        RelPath    = $best.Rel
        FileName   = $best.File.Name
        Version    = $bestVer
        IsExpected = ($best.File.Name -ieq $expected)
        Candidates = $cands.Count
    }
}

function Merge-CustomCatalog {
    # Custom entries replace ManageEngine entries they override (and same-named entries).
    param($Catalog,[string]$CustomPath)
    if (-not (Test-Path -LiteralPath $CustomPath)) { return @($Catalog) }
    $custom = @(Get-Content -Raw -LiteralPath $CustomPath | ConvertFrom-Json)
    $drop = @{}
    foreach ($c in $custom) {
        $drop[[string]$c.name] = $true
        if ($c.PSObject.Properties.Name -contains 'overrides' -and $c.overrides) { $drop[[string]$c.overrides] = $true }
    }
    return @(@($Catalog | Where-Object { -not $drop.ContainsKey([string]$_.name) }) + $custom)
}
