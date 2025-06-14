function Invoke-Keeper {
    param(
        [Parameter(Mandatory)][string]$Cmd,
        [Parameter(Mandatory)][string]$Args
    )
    & keeper $Cmd $Args
    if ($LASTEXITCODE) {
        throw "keeper $Cmd failed with code $LASTEXITCODE"
    }
    try {
        $out = Get-Content "$Env:TEMP\keeper_output.json" -Raw | ConvertFrom-Json
    } catch { $out = $null }
    return $out
}
