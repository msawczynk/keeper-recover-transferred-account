function Invoke-Phase1 {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Config)

    $target = $Config.TargetUser
    $admin  = $Config.AdminUser

    if ($PSCmdlet.ShouldProcess($target, 'lock account')) {
        Invoke-Keeper 'enterprise-user' "--lock $target"
    }

    if ($PSCmdlet.ShouldProcess($target, 'transfer vault')) {
        Invoke-Keeper 'enterprise-user' "--transfer $target --to $admin --format json"
    }

    Write-Log "Phase 1 complete – $target locked and vault transferred."
}
