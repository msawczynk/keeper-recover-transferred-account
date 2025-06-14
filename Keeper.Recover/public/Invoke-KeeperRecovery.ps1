function Invoke-KeeperRecovery {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable]$Config,
        [switch]$WhatIf,
        [switch]$Verbose
    )

    Set-StrictMode -Version Latest
    $checkpoint = Get-Checkpoint $Config.TargetUser

    if (-not $checkpoint.Phase1Complete) {
        Invoke-Phase1 -Config $Config @PSBoundParameters
        $checkpoint.Phase1Complete = $true
        Save-Checkpoint $Config.TargetUser $checkpoint
    }

    if (-not $checkpoint.Phase2Complete) {
        Invoke-Phase2 -Config $Config @PSBoundParameters
        $checkpoint.Phase2Complete = $true
        Save-Checkpoint $Config.TargetUser $checkpoint
    }

    Write-Log "Recovery workflow finished for $($Config.TargetUser)"
}
