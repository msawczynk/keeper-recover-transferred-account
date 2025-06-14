# dot‑source public
Get-ChildItem -Path $PSScriptRoot/public/*.ps1 | ForEach-Object { . $_.FullName }
# dot‑source private
Get-ChildItem -Path $PSScriptRoot/private/*.ps1 | ForEach-Object { . $_.FullName }
Export-ModuleMember -Function (Get-ChildItem $PSScriptRoot/public/*.ps1 |
    ForEach-Object { $_.BaseName })
