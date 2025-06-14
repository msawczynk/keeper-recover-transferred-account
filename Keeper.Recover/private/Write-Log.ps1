function Write-Log {
    param([string]$Message)
    $stamp = (Get-Date).ToString('u')
    Write-Host "[$stamp] $Message"
}
