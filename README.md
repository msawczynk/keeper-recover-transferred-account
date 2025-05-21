Keeper Full Account Recovery Assistant PowerShell Script
Version: 1.3 (as per the script this README is based on for capturing affiliations)

1. Purpose
This PowerShell script is an administrative tool designed to guide an administrator through the complex, multi-step process of recovering a Keeper user's vault access when their master password has been forgotten. It orchestrates actions that involve securing the user's old vault, capturing their roles/teams, creating a new account for the user, re-applying their previous affiliations, and transferring the contents of their old vault to their new account.

This script performs highly sensitive and potentially destructive operations. It should be used with extreme caution and a full understanding of its actions.

2. Workflow Overview
The script operates in two main phases:

Phase 1: Secure Old Account & Transfer Vault to Admin

Identify Target User: Prompts for the email address of the user who has forgotten their master password.

Capture Affiliations: Attempts to retrieve and display the target user's current Role and Team assignments from Keeper using enterprise-user --email "<user_email>" info. This information is crucial for re-provisioning and must be noted by the admin, as it won't be automatically available after the original account is processed by Keeper's Account Transfer Policy.

Identify Recipient Admin: Prompts for the email address of the administrator who will temporarily receive the target user's vault contents. This is typically the admin running the script.

Critical Warnings & Confirmation: Displays explicit warnings about the consequences of this phase, including the likely deletion of the original user's account by Keeper. Requires explicit confirmation to proceed.

Lock Account: Executes keeper-commander.exe enterprise-user --lock for the target user.

Initiate Account Transfer: Executes keeper-commander.exe enterprise-user --transfer --to to move the target user's entire vault into a new folder within the recipient administrator's vault. (The original target user account is typically DELETED by Keeper during this process).

Phase 2: Re-Provision New User Account & Return Items
7.  New User Email: Prompts for the email address that will be used for the user's new Keeper account. This cannot be the same as the original email if the original account was deleted.
8.  Create/Invite New User:
* Offers to either "Invite User" (enterprise-user --invite) or "Add User" (enterprise-user --add).
* If "Add User" is chosen, it can optionally prompt for Full Name, Node, and SSO status.
* If "Add User" is chosen, it informs the admin that a record named Keeper Account: <new_user_email> containing a temporary password is created in the admin's vault and offers to create a one-time share link for this record.
9.  Verify New User Status: Attempts to verify the new user's existence using user-info. May require the user to complete the invitation process if that method was chosen.
10. Re-assign Roles: Automatically attempts to assign the roles captured in Phase 1 to the new user. Also allows the admin to assign additional roles manually.
11. Re-assign Teams: Automatically attempts to add the new user to the teams captured in Phase 1. Also allows the admin to add the user to additional teams manually.
12. Identify Recovered Vault Folder: Helps the admin select the folder in their (the admin's) vault that now contains the items from the original user's transferred vault.
13. Transfer Items to New User: Transfers ownership of all records and sub-folders within the selected source folder to the user's new account using share-record --action owner. The recursive nature of this transfer is controlled by the -NoRecursiveItemReturn switch.
14. Guidance for New User: Provides instructions for the admin to relay to the new user on how to access their account.
15. Optional Cleanup: Offers to delete the (now re-homed) container folder from the admin's vault.

3. Prerequisites
PowerShell: Version 5.1 or higher.

Keeper Commander CLI:

keeper-commander.exe must be installed.

The script attempts to locate it via Get-Command. Ensure it's in your system's PATH.

Keeper Administrator Permissions: The Keeper user account executing the script (or whose session is active) MUST have the following permissions:

"Account Transfer" administrative permission (to lock and transfer user accounts).

Permission to create/invite enterprise users.

Permission to view user information (including roles and teams via enterprise-user ... info).

Permission to assign users to roles (enterprise-role --add-user).

Permission to add users to teams (enterprise-team --add-user).

Permission to list their own shared folders (lsf).

Permission to get details of shared folders (folder-info).

Ownership of records to be transferred (which they will have after the initial vault transfer to their account).

Organization's Account Transfer Policy: This policy must be enabled in your Keeper enterprise.

Authenticated Keeper Session: Before running this script, ensure you are logged into Keeper Commander in the same PowerShell window:

Open PowerShell.

Run keeper-commander.exe shell.

Log in with your master password and 2FA.

Type exit to leave the Keeper shell (the session remains active for that window).

Then, run this script.

The script includes a basic login check using keeper-commander.exe whoami.

Graphical Environment (Optional): Out-GridView is used for GUI-based item selection. If unavailable, the script falls back to a console-based menu.

4. Script Parameters
.\keeper_full_account_recovery_assistant.ps1
    [-NoRecursiveItemReturn]
    [-WhatIf]
    [-Confirm]
    [-Verbose]

-NoRecursiveItemReturn: (Switch) If present, the final transfer of items from the admin's recovered folder to the new user's account will NOT be recursive (omits --recursive from the share-record command). Defaults to recursive.

-WhatIf: (Switch) Shows what actions would be taken by Invoke-KeeperActionCommand without actually performing them.

-Confirm: (Switch) Prompts for confirmation before performing actions that change data via Invoke-KeeperActionCommand. (Note: The script has its own explicit, detailed confirmation prompts for critical steps).

-Verbose: (Switch) Overrides the script's internal log level selection and enables detailed verbose output for all script operations.

5. How to Use (Interactive Mode Only)
This script is designed for interactive use by an administrator.

Ensure Prerequisites: Especially the Keeper Commander login in the same PowerShell window.

Run the Script:

.\keeper_full_account_recovery_assistant.ps1

(Or use the full path to the script. Optionally add -Verbose for maximum detail from the start).

Follow the Prompts Carefully:

Select your preferred log detail level.

The script will verify your Keeper login and the target Keeper Enterprise.

Phase 1:

Enter the email of the user who forgot their password.

The script will attempt to display their current roles and teams. Note these down manually if needed for absolute certainty, as this capture is best-effort based on enterprise-user info output.

Enter the email of the admin account that will receive the transferred vault (usually your own).

Heed all warnings and confirm the account lock and transfer.

Wait for Phase 1 to complete.

Phase 2:

Enter the new email address for the user.

Choose to "Invite User" or "Add User". Provide additional details if "Add User" is chosen.

If "Add User" was chosen, decide if you want to create a one-time share link for the temporary password record.

The script will attempt to re-assign captured roles and teams. You'll be prompted to add any additional ones.

Select the shared folder in your vault that now contains the recovered items.

Confirm the transfer of these items to the new user's account.

Decide if you want to delete the source folder from your vault after the transfer.

Review Output & Verify:

Carefully review all messages and warnings from the script.

Check the transcript log located in your $env:TEMP directory (e.g., KeeperAccountRecovery-YYYYMMDD-HHMMSS.log).

Crucially, verify all actions in the Keeper Admin Console and have the user log in to their new account to confirm their access and data.

6. Important Considerations
DESTRUCTIVE ACTIONS: Phase 1 of this script (locking and transferring an account) is a destructive process that typically results in the deletion of the original user's account by Keeper. There is no undo button for this server-side action.

DATA INTEGRITY: While Keeper's Account Transfer Policy is designed to move all vault data, it's the administrator's responsibility to verify that all expected data appears in the folder within their vault after Phase 1.

ROLE AND TEAM RE-ASSIGNMENT: The script attempts to capture and re-apply roles and teams using the Identifier (UID if available, otherwise Name). The accuracy depends on the output of enterprise-user ... info and the reliability of these identifiers for re-assignment. Always verify that the new user has the correct affiliations. Some complex role/team settings might require manual adjustment in the Admin Console.

SHARED RECORD PERMISSIONS: When items are transferred to the new user, they become the owner. Any shares they had initiated from their old account on those records will be broken. The new user will need to re-share records as needed from their new account.

SCRIPT IS AN ASSISTANT: This script automates CLI
