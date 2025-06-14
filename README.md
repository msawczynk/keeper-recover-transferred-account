
# keeper-recover

Robust, **two-phase** PowerShell toolkit that locks, transfers, recreates and re-shares a Keeper Security user account—**safely, repeatably, and with full auditability**.

---

## Table of Contents
1. [Why you need it](#why-you-need-it)  
2. [How it works](#how-it-works)  
3. [Quick start](#quick-start)  
4. [Manifest reference](#manifest-reference)  
5. [Architecture & file map](#architecture--file-map)  
6. [Safety rails](#safety-rails)  
7. [Logging, checkpoints & state](#logging-checkpoints--state)  
8. [Tests & coverage](#tests--coverage)  
9. [CI/CD](#cicd)  
10. [Deployment patterns](#deployment-patterns)  
11. [Troubleshooting](#troubleshooting)  
12. [Security considerations](#security-considerations)  
13. [Roadmap](#roadmap)  
14. [Contributing](#contributing)  
15. [License](#license)

---

## Why you need it
* **Data-loss insurance** – locks the source account *before* vault deletion can happen.  
* **Zero hand-typing** – a YAML manifest drives every call; runs are deterministic.  
* **Resume after failure** – checkpoints allow safe re-entry if the network drops or a token expires.  
* **Dry-run by default** – `-WhatIf` lets you test in production without touching data.  
* **First-class CI hooks** – Pester tests and ScriptAnalyzer linting gate every commit.  

---

## How it works

| Phase | Action | keeper-cli verb | Result |
|-------|--------|-----------------|--------|
| **1** | Lock legacy user | `enterprise-user --lock` | User can’t log in |
|       | Transfer vault    | `enterprise-user --transfer` | Admin owns all records |
| **2** | Create / invite replacement | `enterprise-user --add / --invite` | New blank vault |
|       | Restore roles & teams | `enterprise-role / team --add-*` | Permissions match old user |
|       | Return records   | `share --one-time` | User regains their data |

---

## Quick start

```powershell
# install dependency
Install-Module powershell-yaml -Scope CurrentUser -Force

# clone repo
git clone https://github.com/<org>/keeper-recover.git
cd keeper-recover

# edit example manifest
code examples\case-42.yml

# dry-run
pwsh -File .\Recover.ps1 -Config .\examples\case-42.yml -Verbose -WhatIf

# live run (remove -WhatIf)
pwsh -File .\Recover.ps1 -Config .\examples\case-42.yml -Verbose
```

**Authentication**  
Supply a Keeper Commander session token with:

```powershell
$env:KPR_TOKEN = '<your keeper device token>'
```

or let the interactive Keeper login prompt appear.

---

## Manifest reference

All configuration lives in a single YAML file. **No secrets here**.

| Key | Type | Required | Notes |
|-----|------|----------|-------|
| `TenantId` | int | ✔︎ | Enterprise ID |
| `TargetUser` | string | ✔︎ | User to be de-provisioned |
| `AdminUser` | string | ✔︎ | Vault transfer recipient |
| `NewUser.Email` | string | ✔︎ | Replacement account email |
| `NewUser.FullName` | string | ✔︎ | Display name |
| `NewUser.Node` | string | ✔︎ | Org node / OU |
| `NewUser.SSO` | bool | ✖︎ | Default `false` |
| `Options.CreateMode` | enum | ✖︎ | `Invite` (default) or `Add` |
| `Options.OneTimeShareExpiry` | string | ✖︎ | `1h`, `1d`, `2d` … |
| `Options.DryRun` | bool | ✖︎ | Overrides CLI `-WhatIf` |

---

## Architecture & file map

```
Keeper.Recover/                       # PowerShell module root
├─ public/                            # exported cmdlets
│  ├─ Invoke-KeeperRecovery.ps1       # orchestrator
│  ├─ Invoke-Phase1.ps1               # lock + transfer
│  ├─ Invoke-Phase2.ps1               # recreate + share back
│  ├─ Get-KprUserAffiliations.ps1
│  ├─ Restore-KprAffiliations.ps1
│  └─ Return-KprRecords.ps1
├─ private/                           # internal helpers
│  ├─ Invoke-Keeper.ps1
│  ├─ Write-Log.ps1
│  └─ Utilities.ps1
├─ Keeper.Recover.psm1                # root module – auto-imports above
└─ Keeper.Recover.psd1                # manifest

Recover.ps1                           # thin entry wrapper
examples/case-42.yml                  # sample manifest
tests/                                # Pester unit tests
.github/workflows/ci.yml              # GitHub Actions pipeline
```

---

## Safety rails
1. **`SupportsShouldProcess`** everywhere → `-WhatIf` blocks all mutations.  
2. **Checkpoint JSON** prevents repeating a completed phase.  
3. Script **aborts** on any non-zero `$LASTEXITCODE` from keeper-cli.  
4. Operator must type the **exact** email being deleted (confirmation prompt).  
5. Functions are **idempotent** – they check current state before acting.

---

## Logging, checkpoints & state

| File | Purpose | Location |
|------|---------|----------|
| Console output | Human-readable audit log | Stdout |
| `%USERPROFILE%\.keeper-recover\<user>.json` | Phase completion & timestamps | Per-machine |
| `$Env:TEMP\keeper_output.json` | keeper-cli JSON payload (auto-cleaned) | Volatile |

Delete the checkpoint only if you must **restart from scratch**.

---

## Tests & coverage

| File | What it checks |
|------|----------------|
| `tests/Phase1.Tests.ps1` | Phase 1 flow runs in dry-run |
| `tests/Phase2.Tests.ps1` | Phase 2 calls its helpers exactly once |

Run everything with:

```powershell
Invoke-Pester tests -Output Detailed
```

Aim for **≥ 80 %** line coverage for new code.

---

## CI/CD

The default GitHub Actions workflow:

* Installs dependencies  
* Runs ScriptAnalyzer – **no warnings tolerated**  
* Executes Pester tests  
* (Optionally) signs and publishes the module to an internal PSGallery

---

## Deployment patterns

| Need | Pattern | Notes |
|------|---------|-------|
| **One-off manual fix** | Run `Recover.ps1` locally with `-WhatIf`, then live | No infra change |
| **Scheduled cleanup** | Windows Task Scheduler calling `pwsh -File Recover.ps1 …` | Manifest pulled from Git |
| **DevOps pipeline** | Azure DevOps / GitHub Actions job with `pwsh` step | Secrets via pipeline variables |
| **Help-desk self-service** | Wrap script in a ServiceNow catalog item | Ensure `-WhatIf` not exposed |

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Script hangs at keeper-cli | No auth token / device approval pending | Approve device or set `$KPR_TOKEN` |
| Checkpoint says phase 1 done but data missing | Checkpoint deleted mid-run | Rerun with fresh checkpoint |
| `keeper … failed with code 3` | Network timeout | Rerun; checkpoint ensures resume |
| Records not returned | Admin cleaned up temp folder prematurely | Run Phase 2 again |

---

## Security considerations
* **No secrets** in repo or manifests.  
* Keeper session token stored in memory or CI secret vault only.  
* All scripts can be **signed**; thumbprint pinned in the runbook.  
* Least-privilege: admin user needs vault-transfer rights only.

---

## Roadmap

| Milestone | Target date | Status |
|-----------|-------------|--------|
| Cross-platform port (Python + KeeperCommander SDK) | 2025-Q4 | Planned |
| Automated code-signing in CI | 2025-Q3 | In progress |
| MS Teams webhook alerts on completion/error | 2025-Q3 | Backlog |
| Full integration test against Keeper sandbox tenant | 2025-Q4 | Backlog |

---

## Contributing

1. Fork → feature branch.  
2. Write or update **Pester tests**.  
3. Run `Invoke-ScriptAnalyzer -Recurse` – must be clean.  
4. Open a pull request; CI must pass before review.

---

### Authors

*Maintainer*: **Martin** (with love from the Sales-Engineering cave).  
PRs are welcome—just keep them tidy and tested.
