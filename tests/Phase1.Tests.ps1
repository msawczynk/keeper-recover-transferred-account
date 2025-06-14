Describe 'Invoke-Phase1' {
    It 'returns without error in dry‑run' {
        $cfg = @{
            TargetUser = 'dummy@corp.com'
            AdminUser  = 'admin@corp.com'
        }
        { Invoke-Phase1 -Config $cfg -WhatIf } | Should -Not -Throw
    }
}
