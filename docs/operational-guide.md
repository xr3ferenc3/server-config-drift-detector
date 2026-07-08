

# Operational Guide

## Purpose of This Document

This is the primary how-to document for server-config-drift-detector. It covers installation, first run, baseline establishment, scheduling, ongoing comparison and reporting, and output interpretation - written for a junior sysadmin operating this toolkit for the first time on a production or pre-production server.

Read this document in order on first use. After initial setup, it serves as a reference for specific tasks via the table of contents.

---

## Table of Contents

1. Prerequisites
2. Installation - Windows Server 2022
3. Installation - RHEL 9
4. Establishing a Baseline
5. Running a Comparison and Generating a Report
6. Enabling Scheduled Snapshots
7. The Weekly Review Workflow
8. Promoting a New Baseline
9. Interpreting Exit Codes
10. Where Everything Lives

---

## 1. Prerequisites

### Windows Server 2022

- PowerShell 5.1 or later (included by default)
- Local Administrator privileges
- No additional modules required

### RHEL 9

- Bash 4.0 or later (included by default)
- Python 3 (included by default on standard installations)
- `jq` - confirm with `jq --version`; install with `sudo dnf install jq` if missing
- root privileges (directly or via `sudo`)
- firewalld active (standard on RHEL 9)

### Both Platforms

- Git, to clone this repository
- A text editor to review and adjust configuration files before first use

---

## 2. Installation - Windows Server 2022

### Step 2.1 - Clone the Repository

```powershell
git clone https://github.com/YOUR-USERNAME/server-config-drift-detector.git
cd server-config-drift-detector
```

If Git is not installed, see Microsoft's documentation for installing Git on Windows Server, or download this repository as a ZIP file from GitHub and extract it to a permanent location such as `C:\Tools\server-config-drift-detector`.

**Verification:**
```powershell
Test-Path .\windows\scripts\New-ConfigSnapshot.ps1
```
Expected output: `True`

### Step 2.2 - Review the Configuration File

Open `windows\config\snapshot-config.json` in Notepad or a code editor. Review the `output` paths, `retention` values, and `captureCategories` settings. The defaults are suitable for most environments and require no changes for a first run.

### Step 2.3 - Confirm Execution Policy

PowerShell's default execution policy on Windows Server 2022 may prevent unsigned scripts from running. This toolkit's scripts are run with `-ExecutionPolicy Bypass` on each invocation, which avoids needing to change the system-wide execution policy. No action is required, but operators in environments with stricter script signing requirements should review their organisation's PowerShell execution policy guidance.

### Step 2.4 - Proceed to Section 4 (Establishing a Baseline)

---

## 3. Installation - RHEL 9

### Step 3.1 - Clone the Repository

```bash
sudo dnf install -y git jq
git clone https://github.com/YOUR-USERNAME/server-config-drift-detector.git
cd server-config-drift-detector
```

**Verification:**
```bash
test -f linux/scripts/take-snapshot.sh && echo "Found"
```
Expected output: `Found`

### Step 3.2 - Make Scripts Executable

```bash
chmod +x linux/scripts/*.sh
```

**Verification:**
```bash
ls -l linux/scripts/*.sh
```
Expected output: each file's permission string begins with `-rwxr-xr-x` or similar, showing the execute bit set.

### Step 3.3 - Review the Configuration File

```bash
vi linux/config/snapshot.conf
```

Review the `SNAPSHOT_DIR`, `MAX_COMPARISON_SNAPSHOTS`, and `CAPTURE_*` settings. The defaults are suitable for most environments and require no changes for a first run.

### Step 3.4 - Confirm Dependencies

```bash
python3 --version
jq --version
```
Expected output: both commands return a version number with no error. If `python3` is not found, install it with `sudo dnf install python3`. If `jq` is not found, install it with `sudo dnf install jq`.

### Step 3.5 - Proceed to Section 4 (Establishing a Baseline)

---

## 4. Establishing a Baseline

A baseline snapshot is the foundational reference point for all future drift detection. It should be taken only after the server has been provisioned, configured, patched, and reviewed as a known-good state.

**Before taking a baseline, complete `checklists/baseline-snapshot-checklist.md`.**

### Windows

From an elevated PowerShell session:

```powershell
.\windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath .\windows\config\snapshot-config.json -Label "baseline"
```

**Expected output:**
```
[2025-10-01 02:00:05] [INFO] New-ConfigSnapshot.ps1 v1.0.0 started. Label: 'baseline'
[2025-10-01 02:00:06] [INFO] Capturing installed software...
[2025-10-01 02:00:08] [INFO] Captured 142 installed software entries.
[2025-10-01 02:00:08] [INFO] Capturing services...
...
[2025-10-01 02:00:15] [INFO] Snapshot written successfully to: snapshots\SERVER01_2025-10-01_0200_baseline.json
[2025-10-01 02:00:15] [INFO] Snapshot complete. Duration: 9.42s. Errors: 0.
```

**Verification:**
```powershell
Test-Path .\snapshots\*_baseline.json
```
Expected output: `True`

### RHEL 9

```bash
sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label baseline
```

**Expected output:**
```
[2025-10-01 02:00:05] [INFO] take-snapshot.sh v1.0.0 started. Label: 'baseline'
[2025-10-01 02:00:06] [INFO] Capturing installed packages...
[2025-10-01 02:00:08] [INFO] Captured 387 installed packages.
[2025-10-01 02:00:08] [INFO] Capturing services...
...
[2025-10-01 02:00:18] [INFO] Snapshot written successfully to: snapshots/server01_2025-10-01_0200_baseline.json
[2025-10-01 02:00:18] [INFO] Snapshot complete. Duration: 12s. Errors: 0.
```

**Verification:**
```bash
ls snapshots/*_baseline.json
```
Expected output: the path to the newly created snapshot file.

### After Baseline Capture

1. Confirm `capture_errors` in the output snapshot is empty before relying on this snapshot:
   - Windows: `(Get-Content .\snapshots\*_baseline.json -Raw | ConvertFrom-Json).capture_errors`
   - Linux: `jq '.capture_errors' snapshots/*_baseline.json`
   Expected output: `[]` (empty array)
2. Complete `templates/baseline-approval-template.md` to formally record this baseline as approved.
3. Store a copy of the baseline file in a separate, read-only location, per `docs/security-considerations.md`.

---

## 5. Running a Comparison and Generating a Report

This workflow is run manually - on demand after a change, or as part of the weekly review process described in Section 7.

### Windows

```powershell
# Step 1: Take a new snapshot to compare against the baseline
.\windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath .\windows\config\snapshot-config.json -Label "weekly-review"

# Step 2: Compare it against the baseline
.\windows\scripts\Compare-ConfigSnapshots.ps1 `
  -BaselineSnapshot ".\snapshots\SERVER01_2025-10-01_0200_baseline.json" `
  -CompareSnapshot ".\snapshots\SERVER01_2025-10-08_0200_weekly-review.json" `
  -OutputPath ".\diff\SERVER01_diff_2025-10-01_vs_2025-10-08.json"

# Step 3: Generate the drift report
.\windows\scripts\Invoke-DriftReport.ps1 `
  -DiffFile ".\diff\SERVER01_diff_2025-10-01_vs_2025-10-08.json" `
  -ConfigPath ".\windows\config\snapshot-config.json" `
  -OutputDir ".\reports"
```

### RHEL 9

```bash
# Step 1: Take a new snapshot to compare against the baseline
sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label weekly-review

# Step 2: Compare it against the baseline
bash linux/scripts/compare-snapshots.sh \
  --baseline snapshots/server01_2025-10-01_0200_baseline.json \
  --compare snapshots/server01_2025-10-08_0200_weekly-review.json \
  --output diff/server01_diff_2025-10-01_vs_2025-10-08.json

# Step 3: Generate the drift report
bash linux/scripts/drift-report.sh \
  --diff diff/server01_diff_2025-10-01_vs_2025-10-08.json \
  --config linux/config/snapshot.conf \
  --output-dir reports
```

### Reviewing the Report

Open the generated `.md` file in `reports/`. Start with the Summary table - it shows every category, how many changes occurred, and the highest severity within that category. Use `docs/drift-interpretation-guide.md` to determine next steps for each finding.

---

## 6. Enabling Scheduled Snapshots

### Windows

From an elevated PowerShell session, using absolute paths to your cloned repository:

```powershell
.\windows\scheduled-task\Register-SnapshotTask.ps1 `
  -ConfigPath "C:\Tools\server-config-drift-detector\windows\config\snapshot-config.json" `
  -ScriptPath "C:\Tools\server-config-drift-detector\windows\scripts\New-ConfigSnapshot.ps1"
```

**Verification:**
```powershell
Get-ScheduledTask -TaskName "ConfigDriftDetector-Snapshot" | Get-ScheduledTaskInfo
```
Expected output: shows `NextRunTime` populated with tomorrow's date at 02:00.

### RHEL 9

```bash
# Edit linux/systemd/snapshot.service and replace the placeholder paths
# (/opt/server-config-drift-detector) with your actual repository location
sudo cp linux/systemd/snapshot.service /etc/systemd/system/snapshot.service
sudo cp linux/systemd/snapshot.timer /etc/systemd/system/snapshot.timer
sudo systemctl daemon-reload
sudo systemctl enable --now snapshot.timer
```

**Verification:**
```bash
systemctl list-timers snapshot.timer
```
Expected output: a table showing the next scheduled run time.

From this point forward, snapshots labelled `scheduled` will accumulate daily in the snapshot directory without manual intervention.

---

## 7. The Weekly Review Workflow

This is the recommended operational cadence for using this toolkit on an ongoing basis. Follow `checklists/weekly-review-checklist.md` for the complete step-by-step process. In summary:

1. Identify the most recent `scheduled` snapshot from the past week.
2. Run the comparison script against the current approved baseline.
3. Generate the drift report.
4. Review findings using `docs/drift-interpretation-guide.md`.
5. For each CRITICAL or NOTABLE finding: investigate, document, and either remediate or approve.
6. File the drift report and findings using `templates/drift-ticket-template.md` if any finding requires tracked follow-up.
7. If all findings are approved as expected, no baseline change is needed. If the team agrees the new state should become the reference point, proceed to Section 8.

---

## 8. Promoting a New Baseline

When a drift report shows changes that have all been reviewed and approved as legitimate (e.g. an approved patch cycle, an approved new service), the comparison snapshot can be promoted to become the new baseline.

### Step 8.1 - Confirm All Findings Are Approved

Do not promote a baseline if any CRITICAL or NOTABLE finding remains uninvestigated.

### Step 8.2 - Complete the Baseline Approval Record

Fill out `templates/baseline-approval-template.md`, documenting which snapshot is being promoted, who approved it, and why.

### Step 8.3 - Rename or Re-Label the Snapshot

The simplest promotion method is to re-take a fresh snapshot labelled `baseline`, since the prior `baseline`-labelled file is retained permanently and not overwritten:

**Windows:**
```powershell
.\windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath .\windows\config\snapshot-config.json -Label "baseline"
```

**RHEL 9:**
```bash
sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label baseline
```

This produces a new, distinctly timestamped baseline file. The previous baseline file remains in the snapshot directory as a historical record - it is never deleted automatically, per the retention policy described in `docs/architecture-overview.md`.

### Step 8.4 - Update Future Comparisons

All subsequent comparison commands should reference the new baseline file's timestamp going forward.

---

## 9. Interpreting Exit Codes

Every script in this toolkit returns a structured exit code so it can be used reliably in automation, scripting, or scheduled execution contexts.

| Exit Code | Meaning | Applies To |
|---|---|---|
| 0 | Success - no errors, no CRITICAL findings | All scripts |
| 1 | Fatal error - script could not complete its core task | All scripts |
| 2 | Completed with partial errors - some categories failed to capture, but a snapshot was still produced | `New-ConfigSnapshot.ps1`, `take-snapshot.sh` |
| 3 | Completed successfully, but CRITICAL severity findings are present | `Invoke-DriftReport.ps1`, `drift-report.sh` |

Operators integrating this toolkit into broader automation (e.g. a wrapper script that emails the team) should branch on exit code 3 to trigger immediate notification.

---

## 10. Where Everything Lives

| What | Windows Path | Linux Path |
|---|---|---|
| Configuration | `windows\config\snapshot-config.json` | `linux/config/snapshot.conf` |
| Snapshot script | `windows\scripts\New-ConfigSnapshot.ps1` | `linux/scripts/take-snapshot.sh` |
| Comparison script | `windows\scripts\Compare-ConfigSnapshots.ps1` | `linux/scripts/compare-snapshots.sh` |
| Report script | `windows\scripts\Invoke-DriftReport.ps1` | `linux/scripts/drift-report.sh` |
| Scheduling | `windows\scheduled-task\` | `linux/systemd/` |
| Snapshot output | `snapshots\` (configurable) | `snapshots/` (configurable) |
| Diff output | `diff\` (configurable) | `diff/` (configurable) |
| Report output | `reports\` (configurable) | `reports/` (configurable) |
| Execution logs | `logs\` (configurable) | `logs/` (configurable) |

All output directories are excluded from version control by `.gitignore`. See `docs/security-considerations.md` for guidance on securing these directories in production.

---