function Get-Checkpoint {
    param([string]$User)
    $path = Join-Path (Join-Path $env:USERPROFILE '.keeper-recover') "$User.json"
    if (Test-Path $path) { Get-Content $path | ConvertFrom-Json } else { @{ } }
}

function Save-Checkpoint {
    param([string]$User,[hashtable]$Data)
    $folder = Join-Path $env:USERPROFILE '.keeper-recover'
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
    $file = Join-Path $folder "$User.json"
    $Data | ConvertTo-Json | Set-Content $file
}
