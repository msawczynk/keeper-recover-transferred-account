function Invoke-Phase2 {
    [CmdletBinding(SupportsShouldProcess)]
    param([hashtable]$Config)

    $new = $Config.NewUser
    $admin = $Config.AdminUser

    if ($PSCmdlet.ShouldProcess($new.Email, 'create / invite new account')) {
        $mode = $Config.Options.CreateMode
        Invoke-Keeper 'enterprise-user' "--add $($new.Email) --name '$($new.FullName)' --node $($new.Node) --$mode --format json"
    }

    $aff = Get-KprUserAffiliations -OriginalEmail $Config.TargetUser
    Restore-KprAffiliations -NewEmail $new.Email -Affiliations $aff

    Return-KprRecords -FromAdmin $admin -ToUser $new.Email -Expiry $Config.Options.OneTimeShareExpiry

    Write-Log "Phase 2 complete – $($new.Email) reprovisioned."
}
