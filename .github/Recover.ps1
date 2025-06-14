param(
    [Parameter(Mandatory)][string]$ConfigFile,
    [switch]$WhatIf,
    [switch]$Verbose
)

Import-Module "$PSScriptRoot\Keeper.Recover" -Force
$cfg = ConvertFrom-Yaml (Get-Content $ConfigFile -Raw)
Invoke-KeeperRecovery -Config $cfg @PSBoundParameters
