# OneDrive Sync Report for NinjaOne

Reports OneDrive / SharePoint sync status and Known Folder Move redirection for every signed-in OneDrive account (work and personal) and writes the results to NinjaOne custom fields.

## Overview

This script collects OneDrive data in the context of the logged-in user and displays it as an HTML card in NinjaOne, alongside a plain-text summary field suitable for alerting. It enumerates every configured OneDrive account (`Business1`, `Business2`, ..., and `Personal`), determines per-account sync health from the OneDrive `SyncDiagnostics` logs, detects Desktop/Documents/Pictures/Downloads redirection, and inventories synced SharePoint libraries (local disk usage and item count).

Because OneDrive is a per-user context, the script runs as **SYSTEM** and uses the [RunAsUser](https://www.powershellgallery.com/packages/RunAsUser) module to gather data as the currently logged-in user.

## Prerequisites

- Windows endpoint with OneDrive installed and a user logged in
- Script must run as **SYSTEM** (default for NinjaOne automations)
- Internet access to install the `RunAsUser` module from the PowerShell Gallery (installed automatically if missing)
- Two custom fields (see below)

> **Note:** Shared machines / terminal servers with multiple concurrent users are not targeted. The script reports for the single active console user.

---

## Custom Field Requirements

You need to create **two** device custom fields.

1. Navigate to **Administration** → **Devices** → **Device custom fields**
2. Click **Add custom Field**
3. Create each field as described below.

### 1. `onedriveSyncClient` (WYSIWYG)

Holds the combined config + synced libraries HTML card.

| Setting | Value |
|---------|-------|
| **Field Type** | WYSIWYG |
| **Name** | `onedriveSyncClient` |
| **Label** | `OneDrive Sync Client` |
| **Inheritance** | Device |
| **Permissions** | Automations: Read/Write, Technician: Read, API: None |

### 2. `onedriveSyncHealth` (Text / Multi-line)

Holds a concise per-account sync health summary that can be used for conditions/alerting.

| Setting | Value |
|---------|-------|
| **Field Type** | Text or Multi-line |
| **Name** | `onedriveSyncHealth` |
| **Label** | `OneDrive Sync Health` |
| **Inheritance** | Device |
| **Permissions** | Automations: Read/Write, Technician: Read |

---

## How It Works

1. Ensures the `RunAsUser` module is available (installs it if needed).
2. Runs a script block as the current user via `Invoke-AsCurrentUser`, which:
   - Reads configured OneDrive accounts from `HKCU:\Software\Microsoft\OneDrive\Accounts`.
   - Parses each account's most recent `SyncDiagnostics.log` to derive a human-readable sync state.
   - Detects Known Folder Move redirection for Desktop, Documents, Pictures, and Downloads.
   - Inventories synced SharePoint/OneDrive libraries, calculating on-disk size and item count.
   - Writes two JSON files to `C:\temp` (`OneDriveStatus.json` and `OneDriveLibraries.json`).
3. Back in the SYSTEM context, reads the JSON output, builds the HTML card, and writes both custom fields.

Stale JSON output from a previous run is deleted before each execution so old data is never reported.

---

## Sync Health States

Per-account status is derived from the OneDrive `SyncProgressState` code in the diagnostics log and mapped to friendly text:

| State | Meaning |
|-------|---------|
| Up-to-Date | Files are synced |
| Syncing | Sync in progress |
| Paused | Sync is paused |
| File merge conflict | A conflict needs resolution |
| File locked | A file is locked and cannot sync |
| Having syncing problems | OneDrive reports sync trouble |
| Not syncing | OneDrive is not actively syncing |
| OneDrive Not Running | `OneDrive.exe` process is not running (status may be stale) |
| OneDrive Not Syncing or Signed In | No parsable status; likely signed out |
| No recent sync log found | No diagnostics log within the last 24 hours |

A `(no files synced in N hours)` suffix is appended when the last sync exceeds the delay threshold (default **72 hours**).

---

## Report Card

The `onedriveSyncClient` WYSIWYG field renders a two-column card:

### OneDrive Config Details

- **Per-account health** — each account is listed with a work (💼) or personal (🏠) icon, display name, email, current sync status, and last synced timestamp.
- **Folder redirection** — Desktop, Documents, Pictures, and Downloads redirection status and the resolved local path. Redirected folders display a green check.

### Synced Libraries

A table of synced SharePoint/OneDrive libraries per account:

- **Account** — the OneDrive account email the library belongs to
- **Site Name** — SharePoint site title
- **Site URL** — library DAV namespace URL
- **Local Disk Used** — on-disk footprint (GB, or `< 10 MB`, nested shortcut mount points excluded)
- **Item Count** — number of items in the library

---

## Alerting

The `onedriveSyncHealth` text field contains a pipe-delimited, per-account summary, for example:

```
user@contoso.com: Up-to-Date | user@personal.com: Syncing
```

You can build a NinjaOne **Condition** on this field to alert on undesirable states (e.g. contains `conflict`, `Not Running`, or `problems`).

### Activity Log Output

The script also writes to the activity log:

- A health verdict based on total synced item count:
  - **Unhealthy** — more than **280,000** files syncing (investigate)
  - **Healthy** — fewer than 280,000 files, or none
  - Or a note that no SharePoint libraries were found
- Formatted tables of accounts and synced libraries

---

## Notes & Limitations

- Requires a user to be logged in at the console; if no user is present, the status file will not be generated and the script logs a message.
- The 280,000-file guidance reflects OneDrive's practical sync performance ceiling.
- Temporary JSON output is written to `C:\temp` and overwritten on each run.
