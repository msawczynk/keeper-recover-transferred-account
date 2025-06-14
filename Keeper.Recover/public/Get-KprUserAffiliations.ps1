function Get-KprUserAffiliations {
    param([string]$OriginalEmail)

    $json = Invoke-Keeper 'enterprise-user' "--get $OriginalEmail --format json"
    [pscustomobject]@{
        Roles = $json.roles
        Teams = $json.teams
    }
}
