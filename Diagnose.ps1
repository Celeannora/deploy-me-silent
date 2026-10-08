# Diagnose.ps1 - environment sanity check for Deploy-MESilentInstall.
# Run this FIRST to find out why the deploy script is aborting.

$ErrorActionPreference = 'Continue'
$out = [ordered]@{}

$out.PSVersion          = $PSVersionTable.PSVersion.ToString()
$out.PSEdition          = $PSVersionTable.PSEdition
$out.OS                 = [System.Environment]::OSVersion.VersionString
$out.Is64BitProcess     = [Environment]::Is64BitProcess
$out.Is64BitOS          = [Environment]::Is64BitOperatingSystem
$out.CurrentUser        = "$env:USERDOMAIN\$env:USERNAME"
$out.IsElevated         = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$out.ExecutionPolicy    = (Get-ExecutionPolicy -List | ForEach-Object { "$($_.Scope)=$($_.ExecutionPolicy)" }) -join '; '

# AD module?
$out.ADModulePresent    = [bool](Get-Module -ListAvailable -Name ActiveDirectory)
$out.GetADComputer      = [bool](Get-Command Get-ADComputer -ErrorAction SilentlyContinue)

# WinRM local?
try { $null = winrm quickconfig -quiet 2>$null; $out.WinRMService = (Get-Service WinRM -ErrorAction Stop).Status } catch { $out.WinRMService = "unavailable" }

# PsExec?
$psexec = @(
    (Join-Path $PSScriptRoot 'PsExec.exe'),
    (Join-Path $PSScriptRoot 'PsExec64.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $psexec) { $psexec = (Get-Command PsExec.exe -ErrorAction SilentlyContinue).Source }
$out.PsExecFound        = if ($psexec) { $psexec } else { '(not found - PsExec fallback disabled)' }

# Catalog?
$catalogPath = Join-Path $PSScriptRoot 'SoftwareCatalog.json'
if (Test-Path $catalogPath) {
    try {
        $c = Get-Content $catalogPath -Raw | ConvertFrom-Json
        $out.CatalogPath  = $catalogPath
        $out.CatalogCount = $c.Count
    } catch {
        $out.CatalogPath  = $catalogPath
        $out.CatalogError = $_.Exception.Message
    }
} else {
    $out.CatalogPath = "MISSING at $catalogPath"
}

Write-Host ""
Write-Host "===== Deploy-MESilentInstall diagnostics =====" -ForegroundColor Cyan
$out.GetEnumerator() | ForEach-Object {
    "{0,-20} : {1}" -f $_.Key, $_.Value | Write-Host
}
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""
Read-Host "Press ENTER to close"
