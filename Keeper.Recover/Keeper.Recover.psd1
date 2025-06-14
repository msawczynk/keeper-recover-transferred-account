@{
    RootModule        = 'Keeper.Recover.psm1'
    ModuleVersion     = '0.2.0'
    GUID              = '4ca916c3-1b7c-4ee5-aa7d-8c0d00bf4d72'
    Author            = 'YOUR‑NAME'
    Copyright         = '(c) 2025'
    Description       = 'Safely transfer and recreate Keeper accounts.'
    PowerShellVersion = '5.1'
    RequiredModules   = @('powershell-yaml')
    FunctionsToExport = @(
        'Invoke-KeeperRecovery',
        'Invoke-Phase1',
        'Invoke-Phase2',
        'Get-KprUserAffiliations',
        'Restore-KprAffiliations',
        'Return-KprRecords'
    )
    PrivateData = @{}
}
