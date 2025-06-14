function Return-KprRecords {
    param(
        [string]$FromAdmin,
        [string]$ToUser,
        [string]$Expiry = '1d'
    )

    $records = Invoke-Keeper 'list' "--shared $FromAdmin --format json"
    foreach ($rec in $records) {
        Invoke-Keeper 'share' "$rec.uid --to $ToUser --one-time --expire $Expiry"
    }
}
