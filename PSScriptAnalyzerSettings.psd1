# Lint settings for this toolkit (format per PSScriptAnalyzer docs via Context7).
# Run:  Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning', 'Information')
    ExcludeRules = @(
        'PSAvoidUsingWriteHost'                         # interactive console wizard: Write-Host is intentional
        'PSUseSingularNouns'                            # naming style only
        'PSUseApprovedVerbs'                            # naming style only (Process-Result)
        'PSUseShouldProcessForStateChangingFunctions'   # internal helpers, not exported cmdlets
    )
    Rules = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'  # Windows 10, PS 5.1
                'win-4_x64_10.0.18362.0_7.0.0_x64_3.1.2_core'                          # Windows 10, PS 7
            )
            IgnoreCommands = @(
                'Get-ADComputer'    # only used after an explicit RSAT/ActiveDirectory module check
                'Start-ThreadJob'   # only used on the PowerShell 7 code path ($isPS7)
                'Clear-Host'        # built-in function on 5.1; missing from the analyzer profile
            )
        }
        PSUseCompatibleTypes = @{
            Enable         = $true
            TargetProfiles = @(
                'win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework'
                'win-4_x64_10.0.18362.0_7.0.0_x64_3.1.2_core'
            )
        }
    }
}
