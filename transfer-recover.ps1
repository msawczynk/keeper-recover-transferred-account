#requires -Version 5.1
<#
.SYNOPSIS
    Guides an administrator through the multi-step process of recovering a user's
    vault access when their master password is forgotten. This involves securing
    the old vault, capturing their roles/teams, creating a new account,
    re-assigning affiliations, and transferring the old vault's contents.
.DESCRIPTION
    This script orchestrates a complex administrative workflow:

    Phase 1: Secure Old Account & Transfer Vault to Admin
    1. Prompts for the email of the user who forgot their password (target user).
    2. Captures the target user's current Role and Team assignments.
    3. Prompts for the email of the administrator performing the recovery (recipient admin).
    4. Issues strong warnings and requires explicit confirmation.
    5. Locks the target user's account using 'enterprise-user --lock'.
    6. Initiates the server-side Account Transfer Policy using 'enterprise-user --transfer'
       to move the target user's vault into a new folder within the recipient admin's vault.
       (The original target user account is typically DELETED by Keeper during this process).

    Phase 2: Re-Provision New User Account & Return Items
    7. Prompts for the NEW email address for the user.
    8. Creates/Invites the new user account. If "Add User" is chosen, it can create a
       one-time share link for the record containing the temporary password.
    9. Verifies the new user's account status.
    10. Automatically attempts to assign captured Roles to the new user.
    11. Automatically attempts to add the new user to captured Teams.
    12. Optionally allows manual assignment of additional roles/teams.
    13. Helps the admin identify and select the folder in their vault that now
        contains the recovered items from the original account.
    14. Transfers ownership of all records and sub-folders within that selected
        folder to the user's new account using 'share-record --action owner'.
        Recursive behavior is controlled by the -NoRecursiveItemReturn switch.
    15. Provides guidance on how the new user can access their account.
    16. Optionally, offers to delete the (now re-homed) container folder from the admin's vault.

    IMPORTANT ADMINISTRATIVE ACTIONS:
    - The administrator running this script MUST have "Account Transfer" administrative
      permission and other necessary permissions (create user, manage roles/teams, share records).
    - The organization's Account Transfer Policy MUST be enabled.
    - Phase 1 (Account Transfer) typically results in the DELETION of the original user's account.
.NOTES
    Author: AI Assistant (Incorporating User Audit Feedback)
    Version: 2.23 (Implemented audit feedback: logging, tenant guard, -WhatIf, refined folder scanning, etc.)
    Prerequisites:
        - Keeper Commander CLI (keeper-commander.exe) installed and accessible via PATH.
        - The executing Keeper admin must have all necessary permissions.
#>

[CmdletBinding(SupportsShouldProcess=$true)]
param (
    [Switch]$RunAutomated,
    [string]$ConfigFilePath,
    [Switch]$NoRecursiveItemReturn 
)

# --- Initial Global Setup ---
if ($RunAutomated -and ([string]::IsNullOrWhiteSpace($ConfigFilePath))) {
    Write-Error "-ConfigFilePath is mandatory when -RunAutomated is specified. Please provide a valid path."
    Exit 1
}

$Global:KeeperExecutablePath = $null
try {
    $Global:KeeperExecutablePath = (Get-Command keeper-commander.exe -ErrorAction Stop).Source
    Write-Verbose "Using Keeper Commander executable at: $($Global:KeeperExecutablePath)"
}
catch {
    Write-Error "keeper-commander.exe not found in PATH. Please ensure Keeper Commander CLI is installed and accessible."
    Exit 1
}

$originalVerbosePreference = $VerbosePreference 
$VerbosePreference = if ($RunAutomated) { "SilentlyContinue" } else { $originalVerbosePreference } 
$Global:actionFailures = 0 
$oneTimeShareURLGenerated = $null 
$scriptConfigFileVersion = "2.23" # Version of config structure this script expects/generates

# Setup Transcript Logging
$transcriptLogPath = Join-Path $env:TEMP ("KeeperAccountRecovery-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
try {
    Start-Transcript -Path $transcriptLogPath -Append -Force -ErrorAction SilentlyContinue
    Write-Host "Transcript logging started. Log file: $transcriptLogPath" -ForegroundColor DarkGray
} catch {
    Write-Warning "Failed to start transcript logging to '$transcriptLogPath'. Error: $($_.Exception.Message)"
}


# --- Helper Functions ---
Function Invoke-KeeperCommand {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$CommandArguments, 
        [Parameter(Mandatory = $false)]
        [bool]$AttemptJson = $true
    )
    try {
        $argumentsToExecute = $CommandArguments
        if ($AttemptJson -and $CommandArguments -notmatch '--format\s+json') {
            if ($CommandArguments -match '^\s*folder-info\s+([a-zA-Z0-9_-]{22}(\s+[a-zA-Z0-9_-]{22})*)' -or `
                $CommandArguments -match '^\s*get\s+([a-zA-Z0-9_-]{22}(\s+[a-zA-Z0-9_-]{22})*)' -or `
                $CommandArguments -like "user-info*" -or `
                $CommandArguments -like "enterprise-user*info*" -or `
                $CommandArguments -like "enterprise-info" -or ` # For basic enterprise info
                $CommandArguments -like "lsf*" -or `
                $CommandArguments -like "enterprise-info --teams*") { 
                $argumentsToExecute = "$CommandArguments --format json"
            }
        }
        Write-Verbose "Executing Keeper Command: $($Global:KeeperExecutablePath) $argumentsToExecute"
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo; $processInfo.FileName = $Global:KeeperExecutablePath; $processInfo.Arguments = $argumentsToExecute; $processInfo.RedirectStandardOutput = $true; $processInfo.RedirectStandardError = $true; $processInfo.UseShellExecute = $false; $processInfo.CreateNoWindow = $true
        $process = New-Object System.Diagnostics.Process; $process.StartInfo = $processInfo; $process.Start() | Out-Null
        $outputLinesList = New-Object System.Collections.Generic.List[string]; while (-not $process.StandardOutput.EndOfStream) { $outputLinesList.Add($process.StandardOutput.ReadLine()) }; $errorOutput = $process.StandardError.ReadToEnd(); $process.WaitForExit(); $Global:KeeperCliExitCode = $process.ExitCode
        $outputLinesArray = $outputLinesList.ToArray(); $rawOutputString = $outputLinesArray -join [Environment]::NewLine; Write-Verbose "Raw output string from '$($Global:KeeperExecutablePath) $argumentsToExecute':`n$rawOutputString"
        if ($errorOutput) { Write-Warning "Keeper command STDERR for '$($Global:KeeperExecutablePath) $argumentsToExecute':`n$errorOutput" }
        if ($Global:KeeperCliExitCode -ne 0) { Write-Error "Keeper command failed: $($Global:KeeperExecutablePath) $argumentsToExecute`nError code: $($Global:KeeperCliExitCode)`nOutput: $rawOutputString`nErrorStream: $errorOutput"; return $null }
        if ([string]::IsNullOrWhiteSpace($rawOutputString)) { Write-Verbose "Command '$($Global:KeeperExecutablePath) $argumentsToExecute' returned empty output."; return [System.Collections.ArrayList]::new() }
        
        if ($AttemptJson -and ($CommandArguments -like "user-info*" -or `
                               $CommandArguments -like "enterprise-user*info*" -or `
                               $CommandArguments -like "enterprise-info" -or `
                               $CommandArguments -like "folder-info*" -or `
                               $CommandArguments -like "lsf*" -or `
                               $CommandArguments -like "enterprise-info --teams*") ) { 
            try { return ($rawOutputString | ConvertFrom-Json -ErrorAction Stop) } catch { Write-Warning "Failed to parse as JSON: $($Global:KeeperExecutablePath) $argumentsToExecute. Error: $($_.Exception.Message). Returning text."; return $outputLinesArray }
        } else { return $outputLinesArray } 
    } catch { Write-Error "Generic failure in Invoke-KeeperCommand: $($Global:KeeperExecutablePath) $argumentsToExecute`n$($_.Exception.Message)"; $Global:KeeperCliExitCode = -1; return $null }
}

Function Invoke-KeeperActionCommand {
    [CmdletBinding(SupportsShouldProcess=$true)] 
    param ([Parameter(Mandatory = $true)][string]$CommandArguments)
    try { Write-Verbose "Executing Keeper Action Command: $($Global:KeeperExecutablePath) $CommandArguments"; if ($PSCmdlet.ShouldProcess("Keeper target (via command: $CommandArguments)", "Execute administrative action")) {
            $pInfo = New-Object System.Diagnostics.ProcessStartInfo; $pInfo.FileName = $Global:KeeperExecutablePath; $pInfo.Arguments = $CommandArguments; $pInfo.RedirectStandardOutput = $true; $pInfo.RedirectStandardError = $true; $pInfo.UseShellExecute = $false; $pInfo.CreateNoWindow = $true
            $p = New-Object System.Diagnostics.Process; $p.StartInfo = $pInfo; $p.Start() | Out-Null; $o = $p.StandardOutput.ReadToEnd(); $e = $p.StandardError.ReadToEnd(); $p.WaitForExit(); $ec = $p.ExitCode
            Write-Verbose "Action command STDOUT: $o"; if ($e) { Write-Warning "Action command STDERR for '$($Global:KeeperExecutablePath) $CommandArguments':`n$e" }
            if ($ec -ne 0) { Write-Error "Keeper action cmd failed: $($Global:KeeperExecutablePath) $CommandArguments`nCode: $ec`nSTDOUT: $o`nSTDERR: $e"; return $false }
            Write-Host "Keeper action cmd successful: $($Global:KeeperExecutablePath) $CommandArguments" -ForegroundColor Green; return $true
        } else { Write-Warning "Administrative action skipped."; return $false }} catch { Write-Error "Generic failure in Invoke-KeeperActionCommand: $($Global:KeeperExecutablePath) $CommandArguments`n$($_.Exception.Message)"; return $false }
}

Function Select-FromConsoleMenu-Single { 
    param([Parameter(Mandatory=$true)][System.Collections.IList]$Items, [Parameter(Mandatory=$true)][string]$Title)
    Write-Host "`n--- $Title ---" -ForegroundColor Yellow; if ($null -eq $Items -or @($Items).Count -eq 0) { Write-Warning "No items for selection."; return $null }; for ($i = 0; $i -lt @($Items).Count; $i++) { Write-Host ("[{0}] {1} (UID: {2})" -f ($i + 1), $Items[$i].Name, $Items[$i].UID) }; while ($true) { $uIn = Read-Host -Prompt "Enter number for your selection, or 'none'"; if ($uIn -ieq 'none') { return $null }; if ($uIn -match "^\d+$") { $cIdx = [int]$uIn - 1; if ($cIdx -ge 0 -and $cIdx -lt @($Items).Count) { return $Items[$cIdx] } else { Write-Warning "Invalid selection: '$uIn'." }} else { Write-Warning "Invalid input: '$uIn'."}}}
}

Function Get-AdminSharedFoldersList { 
    [OutputType([System.Collections.Generic.List[PSCustomObject]])] param()
    $sfList=[System.Collections.Generic.List[PSCustomObject]]::new();Write-Verbose "Fetching shared folders with 'lsf'.";$cOut=Invoke-KeeperCommand "lsf";if($cOut -is [string[]]){Write-Warning "Parsing 'lsf' as text.";$h=2;$d=$cOut|Select-Object -Skip $h;foreach($l in $d){if([string]::IsNullOrWhiteSpace($l)-or $l.Trim().StartsWith("---")){continue};$p=$l.Trim() -split '\s{2,}',2;if(@($p).Count -eq 2){$sfList.Add([PSCustomObject]@{UID=$p[0].Trim();Name=$p[1].Trim()})}else{Write-Warning "Could not parse 'lsf' line: $l"}}}elseif($cOut -is [System.Array]){$cOut|ForEach-Object{$n=$null;$u=$null;if($_.PSObject.Properties['name']){$n=$_.name}elseif($_.PSObject.Properties['folder_name']){$n=$_.folder_name};if($_.PSObject.Properties['shared_folder_uid']){$u=$_.shared_folder_uid};if($n -and $u){$sfList.Add([PSCustomObject]@{Name=$n;UID=$u})}else{Write-Warning "Skipping SF (JSON): $($_.PSObject.Properties|Out-String)"}}}elseif($cOut){$n=$null;$u=$null;if($cOut.PSObject.Properties['name']){$n=$cOut.name}elseif($cOut.PSObject.Properties['folder_name']){$n=$cOut.folder_name};if($cOut.PSObject.Properties['shared_folder_uid']){$u=$cOut.shared_folder_uid};if($n -and $u){$sfList.Add([PSCustomObject]@{Name=$n;UID=$u})}else{Write-Warning "Skipping SF (JSON): $($cOut|Out-String)"}}; return $sfList
}

Function Get-KeeperUserAffiliations {
    [OutputType([PSCustomObject])]
    param([Parameter(Mandatory=$true)][string]$UserEmail)
    Write-Verbose "Fetching affiliations for user: $UserEmail"; $userInfo = Invoke-KeeperCommand "enterprise-user --email ""$UserEmail"" info"
    $capturedRoles = [System.Collections.Generic.List[PSCustomObject]]::new(); $capturedTeams = [System.Collections.Generic.List[PSCustomObject]]::new()
    if ($null -eq $userInfo -or $Global:KeeperCliExitCode -ne 0) { Write-Warning "Could not retrieve affiliations for '$UserEmail'."; return [PSCustomObject]@{ OriginalRoles = $capturedRoles; OriginalTeams = $capturedTeams } }
    if ($userInfo -is [string[]]) { Write-Warning "Text output for 'enterprise-user info' for '$UserEmail'. Cannot parse."; return [PSCustomObject]@{ OriginalRoles = $capturedRoles; OriginalTeams = $capturedTeams } }
    if ($userInfo.PSObject.Properties['roles'] -and $userInfo.roles -is [System.Array]) { foreach ($rEntry in $userInfo.roles) { $rId=$null;$rName=$null;if($rEntry.PSObject.Properties['role_id']){$rId=$rEntry.role_id};if($rEntry.PSObject.Properties['name']){$rName=$rEntry.name};if($rId -or $rName){$id=if($rId){$rId}else{$rName};$disp=if($rName){$rName}else{$rId};$capturedRoles.Add([PSCustomObject]@{Identifier=$id;Name=$disp});Write-Verbose "  Captured Role: $disp (ID/Name: $id)"}}}else{Write-Verbose "No 'roles' for '$UserEmail'."}
    if ($userInfo.PSObject.Properties['teams'] -and $userInfo.teams -is [System.Array]) { foreach ($tEntry in $userInfo.teams) { $tUid=$null;$tName=$null;if($tEntry.PSObject.Properties['team_uid']){$tUid=$tEntry.team_uid};if($tEntry.PSObject.Properties['name']){$tName=$tEntry.name};if($tUid -or $tName){$id=if($tUid){$tUid}else{$tName};$disp=if($tName){$tName}else{$tUid};$capturedTeams.Add([PSCustomObject]@{Identifier=$id;Name=$disp});Write-Verbose "  Captured Team: $disp (UID/Name: $id)"}}}else{Write-Verbose "No 'teams' for '$UserEmail'."}
    return [PSCustomObject]@{ OriginalRoles = $capturedRoles; OriginalTeams = $capturedTeams }
}

Function Get-AllSharedFolderDetailsCached { # Fetches details for all listed folders once
    [OutputType([hashtable])]
    param([Parameter(Mandatory=$true)][System.Collections.IList]$AllSharedFoldersFromLsf)
    $folderCache = @{}; if (@($AllSharedFoldersFromLsf).Count -eq 0) { Write-Warning "No shared folders to fetch details for."; return $folderCache }
    Write-Host "Caching details for $(@($AllSharedFoldersFromLsf).Count) shared folder(s)..." -F Yellow; $totalFoldersToCache=@($AllSharedFoldersFromLsf).Count; $cachedCount=0
    foreach ($sfSummary in $AllSharedFoldersFromLsf) { $cachedCount++; $statusMsg = "Caching folder {0} of {1}: {2}" -f $cachedCount, $totalFoldersToCache, $sfSummary.Name; Write-Progress -Activity "Caching SF Details" -Status $statusMsg -PercentComplete (($cachedCount / $totalFoldersToCache) * 100); if (-not $sfSummary.UID) { Write-Warning "Skipping SF w/o UID: $($sfSummary|Out-String)"; continue }; $detail = Invoke-KeeperCommand "folder-info $($sfSummary.UID)"; if ($null -ne $detail -and -not ($detail -is [string[]])) { $folderCache[$sfSummary.UID] = $detail } else { Write-Warning "Failed to get/parse details for $($sfSummary.Name) (UID: $($sfSummary.UID))."; $Global:actionFailures++ }}
    Write-Progress -Activity "Caching SF Details" -Completed; return $folderCache
}

Function Get-AssociatedSharedFoldersForTeams { # Uses the cache
    [OutputType([System.Collections.Generic.List[PSCustomObject]])]
    param([Parameter(Mandatory=$true)][System.Collections.IList]$SelectedTeams, [Parameter(Mandatory=$true)][hashtable]$FolderDetailCache, [Parameter(Mandatory=$true)][System.Collections.IList]$AllSharedFoldersFromLsf)
    $associatedFolders=[System.Collections.Generic.List[PSCustomObject]]::new();if(@($SelectedTeams).Count -eq 0 -or $FolderDetailCache.Count -eq 0){Write-Verbose "No teams or cached details.";return $associatedFolders}
    $totalTeamsToScan=@($SelectedTeams).Count;$teamsScanned=0
    foreach($teamToScan in $SelectedTeams){$teamsScanned++;$statusMsgTeamScan="Team '$($teamToScan.Name)': Processing folder cache ({0} of {1} teams)" -f $teamsScanned,$totalTeamsToScan;Write-Progress -Activity "Identifying Team Folder Associations" -Status $statusMsgTeamScan -PercentComplete (($teamsScanned/$totalTeamsToScan)*100);Write-Verbose "Scanning for team: $($teamToScan.Name)";foreach($entry in $FolderDetailCache.GetEnumerator()){$sfUidCurrent=$entry.Key;$sfDetailsCurrent=$entry.Value;$origFolderInfo=$AllSharedFoldersFromLsf|Where-Object{$_.UID -eq $sfUidCurrent}|Select-Object -First 1;$sfNameCurrent=if($origFolderInfo){$origFolderInfo.Name}else{"UID: $sfUidCurrent"};Write-Verbose "  Checking cached SF: '$sfNameCurrent' for team '$($teamToScan.Name)'";if($sfDetailsCurrent.PSObject.Properties['teams'] -and $sfDetailsCurrent.teams -is [System.Array]){foreach($tpEntry in $sfDetailsCurrent.teams){$eTeamUid=$null;$eTeamName=$null;if($tpEntry.PSObject.Properties['team_uid']){$eTeamUid=$tpEntry.team_uid}elseif($tpEntry.PSObject.Properties['uid']){$eTeamUid=$tpEntry.uid};if($tpEntry.PSObject.Properties['name']){$eTeamName=$tpEntry.name};if(($eTeamUid -and ($eTeamUid -eq $teamToScan.UID)) -or ($eTeamName -and ($eTeamName -eq $teamToScan.Name))){if(-not($associatedFolders|Where-Object{$_.UID -eq $sfUidCurrent})){$associatedFolders.Add([PSCustomObject]@{Name=$sfNameCurrent;UID=$sfUidCurrent});Write-Verbose "    Added folder '$sfNameCurrent' for team '$($teamToScan.Name)'."};break}}}}}
    Write-Progress -Activity "Identifying Team Folder Associations" -Completed;return $associatedFolders|Select-Object -Unique -Property UID,Name
}

# --- Main Script Logic ---
$choiceYes = New-Object System.Management.Automation.Host.ChoiceDescription "&Yes", "Confirm."
$choiceNo = New-Object System.Management.Automation.Host.ChoiceDescription "&No", "Cancel."
$yesNoOptions = [System.Management.Automation.Host.ChoiceDescription[]]($choiceYes, $choiceNo)
$outGridViewCommand = Get-Command Out-GridView -ErrorAction SilentlyContinue

$targetUserOriginalEmail = $null; $recipientAdminEmail = $null; $newUserEmail = $null
$userCreationMethod = ""; $originalUserAffiliations = $null

try { 
    Write-Host ("-"*68) -F Cyan; Write-Host "Keeper Full Account Recovery Assistant Script" -F Cyan; Write-Host ("-"*68) -F Cyan
    Write-Warning "CRITICAL SCRIPT: Performs account locking, vault transfer (typically DELETES original account), and new user creation. PROCEED WITH EXTREME CAUTION."; Write-Host ""

    $logTitle="Log Detail";$logMsg="Select log level:";$logOpts=[System.Management.Automation.Host.ChoiceDescription[]]@($choiceNo,$choiceYes);$logIdx=$Host.UI.PromptForChoice($logTitle,$logMsg,$logOpts,0);if($logIdx -eq 1){$VerbosePreference="Continue"}else{$VerbosePreference="SilentlyContinue"};Write-Host "Log detail: $($VerbosePreference)." -F Magenta
    Write-Host "`nVerifying Admin Login..." -F Yellow;$loginChkOut=Invoke-KeeperCommand "whoami" -AttemptJson $false;$loggedInUserEmailWhoAmI=($loginChkOut|Where{$_ -match "User:"}|%{$_ -split ':',2})[1].Trim();if($loginChkOut -eq $null -or $Global:KeeperCliExitCode -ne 0){Write-Warning "Keeper 'whoami' failed (Code: $($Global:KeeperCliExitCode)).";Write-Host "Login via 'keeper-commander.exe shell' in this window, then 'exit'.";$loginOpts=[System.Management.Automation.Host.ChoiceDescription[]]@($choiceYes,$choiceNo);$loginIdx=$Host.UI.PromptForChoice("Login Status","Proceed anyway?",$loginOpts,1);if($loginIdx -ne 0){Write-Host "Exiting.";Exit 0}}else{Write-Host "Keeper 'whoami' OK. Logged in as: $loggedInUserEmailWhoAmI" -F Green;Write-Verbose "Login check: $($loginChkOut -join [Environment]::NewLine)"}
    
    # Tenant/Enterprise Confirmation
    $entInfo = Invoke-KeeperCommand "enterprise-info"; $entName = "Unknown"; $entId = "Unknown"
    if ($entInfo -is [pscustomobject] -and $entInfo.PSObject.Properties["enterprise_name"]) { $entName = $entInfo.enterprise_name }
    if ($entInfo -is [pscustomobject] -and $entInfo.PSObject.Properties["enterprise_id"]) { $entId = $entInfo.enterprise_id }
    Write-Host "`nOperating on Keeper Enterprise: '$entName' (ID: $entId)" -ForegroundColor Yellow
    $tenantConfirm = $Host.UI.PromptForChoice("Confirm Target Enterprise", "Is this the correct Keeper Enterprise you intend to modify?", $yesNoOptions, 1)
    if ($tenantConfirm -ne 0) { Write-Host "Operation cancelled by user. Incorrect enterprise selected."; Exit 0 }

    # --- Phase 1: Secure Old Account & Transfer Vault to Admin ---
    Write-Host "`n--- Phase 1: Secure Old Account & Transfer to Admin ---" -F Cyan
    while(-not $targetUserOriginalEmail){$targetUserOriginalEmail=Read-Host -Prompt "Email of user (FORGOT PASSWORD)";try{[void][System.Net.Mail.MailAddress]::new($targetUserOriginalEmail)}catch{Write-Warning "Invalid email. Try again.";$targetUserOriginalEmail=$null}}
    Write-Host "`nCapturing affiliations for '$targetUserOriginalEmail'..." -F Yellow;$originalUserAffiliations=Get-KeeperUserAffiliations -UserEmail $targetUserOriginalEmail
    if($originalUserAffiliations){if(@($originalUserAffiliations.OriginalRoles).Count -gt 0){Write-Host "  Found Roles:" -F Green;$originalUserAffiliations.OriginalRoles|ForEach-Object{Write-Host "    - $($_.Name) (ID/Name: $($_.Identifier))"}}else{Write-Host "  No roles for '$targetUserOriginalEmail'." -F Yellow};if(@($originalUserAffiliations.OriginalTeams).Count -gt 0){Write-Host "  Found Teams:" -F Green;$originalUserAffiliations.OriginalTeams|ForEach-Object{Write-Host "    - $($_.Name) (UID/Name: $($_.Identifier))"}}else{Write-Host "  No teams for '$targetUserOriginalEmail'." -F Yellow}}else{Write-Warning "Could not capture affiliations for '$targetUserOriginalEmail'."}
    while(-not $recipientAdminEmail){$recipientAdminEmailInput=Read-Host -Prompt "Email of Admin to receive vault (default: '$loggedInUserEmailWhoAmI')";if([string]::IsNullOrWhiteSpace($recipientAdminEmailInput) -and -not [string]::IsNullOrWhiteSpace($loggedInUserEmailWhoAmI)){$recipientAdminEmail=$loggedInUserEmailWhoAmI}else{$recipientAdminEmail=$recipientAdminEmailInput};try{[void][System.Net.Mail.MailAddress]::new($recipientAdminEmail)}catch{Write-Warning "Invalid admin email. Try again.";$recipientAdminEmail=$null}};Write-Host "Target User: $targetUserOriginalEmail" -F Yellow;Write-Host "Recipient Admin: $recipientAdminEmail" -F Yellow
    Write-Warning "`nCRITICAL: Phase 1!" -F Red;Write-Warning "LOCK account '$targetUserOriginalEmail' & TRANSFER VAULT to '$recipientAdminEmail'.";Write-Warning "This usually DELETES original account '$targetUserOriginalEmail'.";$confirmP1Idx=$Host.UI.PromptForChoice("Confirm Lock & Transfer","Proceed with LOCK & TRANSFER of '$targetUserOriginalEmail'?",$yesNoOptions,1);if($confirmP1Idx -ne 0){Write-Host "Phase 1 cancelled. Exiting.";Exit 0}
    Write-Host "`nLocking '$targetUserOriginalEmail'..." -F Yellow;if(Invoke-KeeperActionCommand "enterprise-user --lock ""$targetUserOriginalEmail"""){Write-Host "Account '$targetUserOriginalEmail' locked." -F Green}else{Write-Error "Failed to lock '$targetUserOriginalEmail'. Aborting.";$Global:actionFailures++;Exit 1}
    Write-Host "`nInitiating vault transfer for '$targetUserOriginalEmail' to '$recipientAdminEmail'..." -F Yellow;if(Invoke-KeeperActionCommand "enterprise-user --transfer ""$targetUserOriginalEmail"" --to ""$recipientAdminEmail"""){Write-Host "Account transfer initiated." -F Green}else{Write-Error "Failed to initiate transfer for '$targetUserOriginalEmail'.";Write-Warning "Account '$targetUserOriginalEmail' was locked. Manual intervention needed.";$Global:actionFailures++;Exit 1};Write-Host "Phase 1 complete. Verify folder in '$recipientAdminEmail""'s vault." -F Green;Write-Host "Folder name often 'Vault from $targetUserOriginalEmail' or localized.";Read-Host -Prompt "Press Enter for Phase 2 (Re-Provision New User)..."

    # --- Phase 2: Re-Provision New User Account & Return Items ---
    Write-Host "`n--- Phase 2: Re-Provision New User & Return Items ---" -F Cyan
    while(-not $newUserEmail){$newUserEmail=Read-Host -Prompt "NEW email for user '$targetUserOriginalEmail'";try{[void][System.Net.Mail.MailAddress]::new($newUserEmail)}catch{Write-Warning "Invalid email. Try again.";$newUserEmail=$null};if($newUserEmail -eq $targetUserOriginalEmail){Write-Warning "New email same as original.";$newUserEmail=$null}}
    $createOpts=[System.Management.Automation.Host.ChoiceDescription[]]@(New-Object System.Management.Automation.Host.ChoiceDescription "&Invite User";New-Object System.Management.Automation.Host.ChoiceDescription "&Add User (create-user)");$createTitle="New User Creation";$createMsg="Create for '$newUserEmail' via Invite or Add?";$createIdx=$Host.UI.PromptForChoice($createTitle,$createMsg,$createOpts,0);$userCreateCmdArgs=[System.Collections.Generic.List[string]]::new();$userCreateCmdArgs.Add("""$newUserEmail""");if($createIdx -eq 0){$userCreationMethod="invite";$userCreateBaseCmd="enterprise-user --invite"}else{$userCreationMethod="add";$userCreateBaseCmd="enterprise-user --add";Write-Host "For 'Add User', details (optional):";$newUName=Read-Host -Prompt "Full Name";if(-not[string]::IsNullOrWhiteSpace($newUName)){$userCreateCmdArgs.Add("--name ""$newUName""")};$newNode=Read-Host -Prompt "Node Name/UID";if(-not[string]::IsNullOrWhiteSpace($newNode)){$userCreateCmdArgs.Add("--node ""$newNode""")};$ssoChoice=$Host.UI.PromptForChoice("SSO User?","Is new user SSO?",$yesNoOptions,1);if($ssoChoice -eq 0){$userCreateCmdArgs.Add("--sso-user")}};$fullUserCreateCmd="$userCreateBaseCmd $($userCreateCmdArgs -join ' ')";Write-Host "Attempting to $userCreationMethod user '$newUserEmail'..." -F Yellow
    if(Invoke-KeeperActionCommand $fullUserCreateCmd){Write-Host "New user '$newUserEmail' $userCreationMethod initiated." -F Green;if($userCreationMethod -eq "add"){Write-Host "Record 'Keeper Account: $newUserEmail' (temp pwd) in YOUR vault." -F Yellow;$otsChoice=$Host.UI.PromptForChoice("One-Time Share","Create one-time share for this record?",$yesNoOptions,0);if($otsChoice -eq 0){$otsExp=Read-Host -Prompt "Expiration (e.g., 1h,1d; default:1d)";if([string]::IsNullOrWhiteSpace($otsExp)){$otsExp="1d"};$otsRecName="Keeper Account: $newUserEmail";$otsCmd="share create ""$otsRecName"" --expire ""$otsExp""";Write-Host "Creating one-time share..." -F Yellow;$shareOut=Invoke-KeeperCommand $otsCmd -AttemptJson $false;if($Global:KeeperCliExitCode -eq 0 -and $shareOut -is [System.Array] -and @($shareOut).Count -gt 0 -and $shareOut[0] -like "https://*"){$oneTimeShareURLGenerated=$shareOut[0];Write-Host "One-Time Share URL:" -F Green;Write-Host $oneTimeShareURLGenerated -F Cyan;Write-Host "Securely provide to '$newUserEmail'."}else{Write-Warning "Failed to create one-time share for '$otsRecName'.";$Global:actionFailures++}}};Write-Host "Verifying new user status..." -F Yellow;Start-Sleep -Seconds 3;$usrInfo=Invoke-KeeperCommand "user-info --email ""$newUserEmail""";if($Global:KeeperCliExitCode -eq 0 -and $null -ne $usrInfo -and ($usrInfo -isnot [string[]] -or @($usrInfo).Count -gt 0)){Write-Host "User '$newUserEmail' found." -F Green;if($userCreationMethod -eq "invite"){Write-Host "User needs to accept invite." -F Yellow}}else{Write-Warning "Could not verify '$newUserEmail' (Exit: $($Global:KeeperCliExitCode)).";if($userCreationMethod -eq "invite"){Write-Warning "User may need to accept invite."};$pOpts=[System.Management.Automation.Host.ChoiceDescription[]]@(New-Object System.Management.Automation.Host.ChoiceDescription "&Yes, proceed";New-Object System.Management.Automation.Host.ChoiceDescription "&No, wait");$pIdx=$Host.UI.PromptForChoice("User Verification","Not verified. Proceed anyway?",$pOpts,1);if($pIdx -ne 0){Write-Host "Exiting.";Exit 0}}}else{Write-Error "Failed to $userCreationMethod user '$newUserEmail'.";$Global:actionFailures++;Exit 1}
    if($originalUserAffiliations -and @($originalUserAffiliations.OriginalRoles).Count -gt 0){Write-Host "`nRe-assigning Captured Roles to '$newUserEmail'..." -F Cyan;foreach($role in $originalUserAffiliations.OriginalRoles){Write-Host "  Assigning: '$($role.Name)' (ID: $($role.Identifier))" -F Yellow;$assignRoleCmd="enterprise-role --add-user ""$($role.Identifier)"" ""$newUserEmail""";if(-not(Invoke-KeeperActionCommand $assignRoleCmd)){Write-Warning "Failed role '$($role.Name)'.";$Global:actionFailures++}}}else{Write-Host "`nNo original roles to assign."};$addMoreRoles=$Host.UI.PromptForChoice("Assign More Roles","Assign other roles?",$yesNoOptions,1);if($addMoreRoles -eq 0){$rolesInput=Read-Host -Prompt "Additional Role(s) (comma-sep)";if(-not[string]::IsNullOrWhiteSpace($rolesInput)){$roles=$rolesInput -split ','|%{$_.Trim()}|?{-not[string]::IsNullOrWhiteSpace($_)};if(@($roles).Count -gt 0){Write-Host "Assigning additional roles:" -F Yellow;foreach($role in $roles){Write-Host "  Assigning: '$role'";$assignRoleCmd="enterprise-role --add-user ""$role"" ""$newUserEmail""";if(-not(Invoke-KeeperActionCommand $assignRoleCmd)){Write-Warning "Failed role '$role'.";$Global:actionFailures++}}}}}
    if($originalUserAffiliations -and @($originalUserAffiliations.OriginalTeams).Count -gt 0){Write-Host "`nRe-assigning Captured Teams to '$newUserEmail'..." -F Cyan;foreach($team in $originalUserAffiliations.OriginalTeams){Write-Host "  Adding to: '$($team.Name)' (ID: $($team.Identifier))" -F Yellow;$assignTeamCmd="enterprise-team --add-user ""$($team.Identifier)"" ""$newUserEmail""";if(-not(Invoke-KeeperActionCommand $assignTeamCmd)){Write-Warning "Failed team '$($team.Name)'.";$Global:actionFailures++}}}else{Write-Host "`nNo original teams to assign."};$addMoreTeams=$Host.UI.PromptForChoice("Assign More Teams","Add to other teams?",$yesNoOptions,1);if($addMoreTeams -eq 0){$teamsInput=Read-Host -Prompt "Additional Team(s) (comma-sep)";if(-not[string]::IsNullOrWhiteSpace($teamsInput)){$teams=$teamsInput -split ','|%{$_.Trim()}|?{-not[string]::IsNullOrWhiteSpace($_)};if(@($teams).Count -gt 0){Write-Host "Adding to additional teams:" -F Yellow;foreach($team in $teams){Write-Host "  Adding to: '$team'";$assignTeamCmd="enterprise-team --add-user ""$team"" ""$newUserEmail""";if(-not(Invoke-KeeperActionCommand $assignTeamCmd)){Write-Warning "Failed team '$team'.";$Global:actionFailures++}}}}}
    Write-Host "`nTransfer Items from Recovered Vault Folder to '$newUserEmail'..." -F Cyan;Write-Host "Select folder in YOUR vault with items from '$targetUserOriginalEmail'." -F Yellow;$adminSFs=Get-AdminSharedFoldersList;if(@($adminSFs).Count -eq 0){Write-Error "No shared folders in your vault.";Exit 1};$cleanSFs=$adminSFs|Where{$_ -ne $null -and $_.PSObject.Properties['UID'] -and -not[string]::IsNullOrWhiteSpace($_.UID) -and $_.PSObject.Properties['Name'] -and -not[string]::IsNullOrWhiteSpace($_.Name)};if(@($cleanSFs).Count -eq 0){Write-Error "No valid folders to display.";Exit 1};$selSrcFolder=$null;if($outGridViewCommand){$selSrcFolder=$cleanSFs|Out-GridView -Title "Select Source Folder (Recovered vault of $targetUserOriginalEmail)"}else{$selSrcFolder=Select-FromConsoleMenu-Single -Items $cleanSFs -Title "Select Source Folder (Recovered vault of $targetUserOriginalEmail)"};if(-not $selSrcFolder){Write-Error "No source folder selected.";Exit 1};Write-Host "Source folder: '$($selSrcFolder.Name)' (UID: $($selSrcFolder.UID))" -F Green;$transferRecursive=$if($NoRecursiveItemReturn){""}else{"--recursive"};if($NoRecursiveItemReturn){Write-Warning "Item transfer NOT recursive."}else{Write-Warning "Item transfer WILL BE RECURSIVE."};$confirmItems=$Host.UI.PromptForChoice("Confirm Item Transfer","Transfer items from '$($selSrcFolder.Name)' to '$newUserEmail'?",$yesNoOptions,1);if($confirmItems -ne 0){Write-Host "Item transfer cancelled.";Exit 0};Write-Host "`nProcessing item transfer to '$newUserEmail'..." -F Yellow;$transferCmd="share-record --action owner --email ""$newUserEmail"" $transferRecursive -- ""$($selSrcFolder.UID)""";if(Invoke-KeeperActionCommand $transferCmd){Write-Host "Item transfer from '$($selSrcFolder.Name)' to '$newUserEmail' initiated." -F Green}else{$Global:actionFailures++;Write-Error "Item transfer FAILED for '$($selSrcFolder.Name)'."}
    $delFolderChoice=$Host.UI.PromptForChoice("Delete Source Folder","Delete folder '$($selSrcFolder.Name)' from YOUR vault?",$yesNoOptions,1);if($delFolderChoice -eq 0){Write-Host "Deleting '$($selSrcFolder.Name)'..." -F Yellow;$delCmd="rmdir ""$($selSrcFolder.UID)""";if(Invoke-KeeperActionCommand $delCmd){Write-Host "Folder '$($selSrcFolder.Name)' removed." -F Green}else{Write-Warning "Could not remove '$($selSrcFolder.Name)'.";$Global:actionFailures++}}else{Write-Host "Source folder not deleted."}

} catch { Write-Error "An unhandled error: $($_.Exception.ToString())"; $Global:actionFailures++ }
finally { if ($VerbosePreference -ne $originalVerbosePreference) { Write-Verbose "Restoring original VerbosePreference: $originalVerbosePreference"; $VerbosePreference = $originalVerbosePreference }} 

Write-Host "`n--- Guidance for New User '$newUserEmail' ---" -F Cyan
if($userCreationMethod -eq "invite"){Write-Host "1. User '$newUserEmail' check email for Keeper invite.";Write-Host "2. Click link to create account & set Master Password."}elseif($userCreationMethod -eq "add"){Write-Host "1. User '$newUserEmail' added to enterprise.";if($oneTimeShareURLGenerated){Write-Host "2. Securely provide One-Time Share URL for temp password:" -F Yellow;Write-Host "   $oneTimeShareURLGenerated" -F Cyan;Write-Host "   User logs in with temp password & will be prompted to change it."}else{Write-Host "2. Login method depends on enterprise setup (SSO/etc.). Provide instructions."}}
Write-Host "3. Once logged in, they should find items from old vault.";Write-Host "4. Previously shared records need re-sharing from new account.";Write-Host ""

Write-Host "`n$( '-'*53 )" -F Cyan;Write-Host "Full Account Recovery Assistant Script Finished." -F Cyan
if($Global:actionFailures -gt 0){Write-Warning "$($Global:actionFailures) action(s) failed. Review logs.";Write-Host "Exiting with code 2 (partial failure)." -F Yellow;Exit 2}else{Write-Host "All actions reported success." -F Green}
Write-Host "Verify all steps & have user confirm access." -F Yellow;Write-Host "$( '-'*53 )" -F Cyan
if($Global:actionFailures -eq 0 -and ($Global:KeeperCliExitCode -eq 0 -or $Global:KeeperCliExitCode -eq $null -or $Global:KeeperCliExitCode -eq -1)){Exit 0}elseif($Global:KeeperCliExitCode -ne 0 -and $Global:KeeperCliExitCode -ne -1){Write-Warning "A Keeper CLI command failed (Exit: $($Global:KeeperCliExitCode)).";Exit $Global:KeeperCliExitCode}else{Exit 0}
