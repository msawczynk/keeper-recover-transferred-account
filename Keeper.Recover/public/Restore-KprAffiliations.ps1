function Restore-KprAffiliations {
    param(
        [string]$NewEmail,
        [pscustomobject]$Affiliations
    )

    foreach ($role in $Affiliations.Roles) {
        Invoke-Keeper 'enterprise-role' "--add-user $role $NewEmail"
    }
    foreach ($team in $Affiliations.Teams) {
        Invoke-Keeper 'team' "--add-member $team $NewEmail"
    }
}
