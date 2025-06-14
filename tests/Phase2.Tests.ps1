<#
   Pester 5 unit test – verifies that Phase 2 wires together the helper
   functions and does not throw when run in ‑WhatIf (dry‑run) mode.
#>

Import-Module "$PSScriptRoot/../Keeper.Recover" -Force

Describe 'Invoke‑Phase2' {

    # ── mocks ────────────────────────────────────────────────────────────────
    Mock Invoke-Keeper                { @{ roles=@(); teams=@() } }
    Mock Get-KprUserAffiliations      { @{ Roles=@('Role1'); Teams=@('TeamA') } }
    Mock Restore-KprAffiliations      {}
    Mock Return-KprRecords            {}

    $cfg = @{
        TargetUser = 'legacy@corp.com'
        AdminUser  = 'vaultadmin@corp.com'
        NewUser    = @{
            Email    = 'legacy.new@corp.com'
            FullName = 'Legacy User'
            Node     = 'Engineering'
            SSO      = $true
        }
        Options    = @{
            CreateMode          = 'Invite'
            OneTimeShareExpiry  = '1d'
        }
    }

    It 'runs without error and calls key helpers once each' {
        { Invoke-Phase2 -Config $cfg -WhatIf } | Should -Not -Throw

        Assert-MockCalled Get-KprUserAffiliations -Times 1 -Exactly
        Assert-MockCalled Restore-KprAffiliations -Times 1 -Exactly
        Assert-MockCalled Return-KprRecords      -Times 1 -Exactly
    }
}
