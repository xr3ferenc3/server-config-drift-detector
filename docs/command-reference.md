# Command Reference

## Purpose of This Document

Quick reference for every script parameter, option, and common invocation pattern across all six scripts in this toolkit. Formatted for operational use - the document an operator opens when they need a parameter and do not want to read the full operational guide.

---

## Windows Scripts

---

### New-ConfigSnapshot.ps1

Captures the current configuration state of a Windows Server 2022 host and writes it to a timestamped JSON file.

**Requires:** PowerShell 5.1+, Administrator privileges

**Syntax:**
```powershell
New-ConfigSnapshot.ps1
  -ConfigPath  <string>   (required)
  -Label       <string>   (required)
  [-OutputOverridePath <string>]
```

**Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-ConfigPath` | String | Yes | Absolute or relative path to `snapshot-config.json` |
| `-Label` | String | Yes | Short label for this snapshot. Must match `^[a-zA-Z0-9\-]+$`. Examples: `baseline`, `weekly-review`, `post-patch` |
| `-OutputOverridePath` | String | No | Overrides the snapshot output directory from config. Useful for ad-hoc runs without modifying configuration |

**Exit Codes:**

| Code | Meaning |
|---|---|
| 0 | Success - snapshot written, no errors |
| 1 | Fatal error - snapshot was not written |
| 2 | Completed with partial errors - snapshot was written but one or more capture categories failed |

**Common Invocations:**
```powershell
# Establish a baseline
.\windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath .\windows\config\snapshot-config.json -Label "baseline"

# Weekly comparison snapshot
.\windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath .\windows\config\snapshot-config.json -Label "weekly-review"

# Post-patch verification snapshot
.\windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath .\windows\config\snapshot-config.json -Label "post-patch"

# Ad-hoc snapshot to a custom output directory
.\windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath .\windows\config\snapshot-config.json -Label "pre-maintenance" -OutputOverridePath "D:\Snapshots"
```

**Output:**
```
snapshots\{HOSTNAME}_{YYYY-MM-DD}_{HHMM}_{label}.json
logs\snapshot_{YYYY-MM-DD}.log
```

---

### Compare-ConfigSnapshots.ps1

Compares two Windows snapshot files and produces a structured diff JSON file identifying additions, removals, and modifications per category.

**Requires:** PowerShell 5.1+

**Syntax:**
```powershell
Compare-ConfigSnapshots.ps1
  -BaselineSnapshot  <string>   (required)
  -CompareSnapshot   <string>   (required)
  -OutputPath        <string>   (required)
```

**Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-BaselineSnapshot` | String | Yes | Path to the baseline (reference) snapshot JSON file |
| `-CompareSnapshot` | String | Yes | Path to the comparison snapshot JSON file |
| `-OutputPath` | String | Yes | Full file path where the diff JSON will be written, including filename |

**Exit Codes:**

| Code | Meaning |
|---|---|
| 0 | Success - diff written |
| 1 | Fatal error - diff was not written |

**Common Invocations:**
```powershell
# Standard weekly comparison
.\windows\scripts\Compare-ConfigSnapshots.ps1 `
  -BaselineSnapshot ".\snapshots\SERVER01_2025-10-01_0200_baseline.json" `
  -CompareSnapshot  ".\snapshots\SERVER01_2025-10-08_0200_weekly-review.json" `
  -OutputPath       ".\diff\SERVER01_diff_2025-10-01_vs_2025-10-08.json"

# Post-patch verification comparison
.\windows\scripts\Compare-ConfigSnapshots.ps1 `
  -BaselineSnapshot ".\snapshots\SERVER01_2025-10-01_0200_baseline.json" `
  -CompareSnapshot  ".\snapshots\SERVER01_2025-10-15_0200_post-patch.json" `
  -OutputPath       ".\diff\SERVER01_diff_2025-10-01_vs_2025-10-15.json"
```

**Output:**
```
{OutputPath}   (diff JSON file)
```

---

### Invoke-DriftReport.ps1

Generates a Markdown and JSON drift report from the diff output of `Compare-ConfigSnapshots.ps1`, applying severity classification per category.

**Requires:** PowerShell 5.1+

**Syntax:**
```powershell
Invoke-DriftReport.ps1
  -DiffFile    <string>   (required)
  -ConfigPath  <string>   (required)
  -OutputDir   <string>   (required)
```

**Parameters:**

| Parameter | Type | Required | Description |
|---|---|---|---|
| `-DiffFile` | String | Yes | Path to the diff JSON file produced by `Compare-ConfigSnapshots.ps1` |
| `-ConfigPath` | String | Yes | Path to `snapshot-config.json`, used to read severity thresholds |
| `-OutputDir` | String | Yes | Directory where the Markdown and JSON report files will be written |

**Exit Codes:**

| Code | Meaning |
|---|---|
| 0 | Success - reports written, no CRITICAL findings |
| 1 | Fatal error - reports were not written |
| 3 | Success - reports written, CRITICAL severity findings present |

**Common Invocations:**
```powershell
# Generate report from a weekly comparison diff
.\windows\scripts\Invoke-DriftReport.ps1 `
  -DiffFile   ".\diff\SERVER01_diff_2025-10-01_vs_2025-10-08.json" `
  -ConfigPath ".\windows\config\snapshot-config.json" `
  -OutputDir  ".\reports"

# Generate report and check for critical findings in a wrapper script
.\windows\scripts\Invoke-DriftReport.ps1 `
  -DiffFile ".\diff\SERVER01_diff.json" -ConfigPath ".\windows\config\snapshot-config.json" -OutputDir ".\reports"
if ($LASTEXITCODE -eq 3) {
    Write-Host "CRITICAL findings detected. Team notification required."
}
```

**Output:**
```
reports\{HOSTNAME}_drift-report_{YYYY-MM-DD}.md
reports\{HOSTNAME}_drift-report_{YYYY-MM-DD}.json
```

---

### Register-SnapshotTask.ps1

Registers (or updates) the Windows Scheduled Task for automated daily snapshot capture.

**Requires:** PowerShell 5.1+, Administrator privileges

**Syntax:**
```powershell
Register-SnapshotTask.ps1
  -ConfigPath   <string>   (required)
  -ScriptPath   <string>   (required)
  [-TriggerTime <string>]
  [-TaskName    <string>]
```

**Parameters:**

| Parameter | Type | Required | Default | Description |
|---|---|---|---|---|
| `-ConfigPath` | String | Yes | - | Absolute path to `snapshot-config.json`. Must be absolute - relative paths do not resolve correctly in scheduled task context |
| `-ScriptPath` | String | Yes | - | Absolute path to `New-ConfigSnapshot.ps1`. Same absolute path requirement |
| `-TriggerTime` | String | No | `02:00` | Daily trigger time in 24-hour HH:mm format. Validated against pattern `^([01]\d\|2[0-3]):[0-5]\d$` |
| `-TaskName` | String | No | `ConfigDriftDetector-Snapshot` | Name of the scheduled task in Task Scheduler |

**Exit Codes:**

| Code | Meaning |
|---|---|
| 0 | Task registered or updated successfully |
| 1 | Registration failed |

**Common Invocations:**
```powershell
# Register with default trigger time (02:00)
.\windows\scheduled-task\Register-SnapshotTask.ps1 `
  -ConfigPath "C:\Tools\server-config-drift-detector\windows\config\snapshot-config.json" `
  -ScriptPath "C:\Tools\server-config-drift-detector\windows\scripts\New-ConfigSnapshot.ps1"

# Register with a custom trigger time
.\windows\scheduled-task\Register-SnapshotTask.ps1 `
  -ConfigPath "C:\Tools\server-config-drift-detector\windows\config\snapshot-config.json" `
  -ScriptPath "C:\Tools\server-config-drift-detector\windows\scripts\New-ConfigSnapshot.ps1" `
  -TriggerTime "03:30"
```

---

## Linux Scripts

---

### take-snapshot.sh

Captures the current configuration state of a RHEL 9 host and writes it to a timestamped JSON file.

**Requires:** Bash 4.0+, root privileges, jq

**Syntax:**
```bash
take-snapshot.sh --config <path> --label <label> [--output-dir <path>]
```

**Options:**

| Option | Required | Description |
|---|---|---|
| `--config <path>` | Yes | Path to `snapshot.conf` |
| `--label <label>` | Yes | Short label for this snapshot. Must match `^[a-zA-Z0-9-]+$`. Examples: `baseline`, `weekly-review`, `post-patch` |
| `--output-dir <path>` | No | Overrides the configured `SNAPSHOT_DIR`. Useful for ad-hoc runs |
| `--help` | No | Prints usage information and exits |

**Exit Codes:**

| Code | Meaning |
|---|---|
| 0 | Success - snapshot written, no errors |
| 1 | Fatal error - snapshot was not written |
| 2 | Completed with partial errors - snapshot was written but one or more capture categories failed |

**Common Invocations:**
```bash
# Establish a baseline
sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label baseline

# Weekly comparison snapshot
sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label weekly-review

# Post-patch verification snapshot
sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label post-patch

# Ad-hoc snapshot to a custom output directory
sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label pre-maintenance --output-dir /mnt/snapshots
```

**Output:**
```
snapshots/{hostname}_{YYYY-MM-DD}_{HHMM}_{label}.json
logs/snapshot_{YYYY-MM-DD}.log
```

---

### compare-snapshots.sh

Compares two Linux snapshot files and produces a structured diff JSON file identifying additions, removals, and modifications per category.

**Requires:** Bash 4.0+, Python 3, jq

**Syntax:**
```bash
compare-snapshots.sh --baseline <path> --compare <path> --output <path> [--config <path>]
```

**Options:**

| Option | Required | Description |
|---|---|---|
| `--baseline <path>` | Yes | Path to the baseline (reference) snapshot JSON file |
| `--compare <path>` | Yes | Path to the comparison snapshot JSON file |
| `--output <path>` | Yes | Full file path where the diff JSON will be written, including filename |
| `--config <path>` | No | Path to `snapshot.conf`. Optional - only used to resolve a non-default `PYTHON3_BINARY` |
| `--help` | No | Prints usage information and exits |

**Exit Codes:**

| Code | Meaning |
|---|---|
| 0 | Success - diff written |
| 1 | Fatal error - diff was not written |

**Common Invocations:**
```bash
# Standard weekly comparison
bash linux/scripts/compare-snapshots.sh \
  --baseline snapshots/server01_2025-10-01_0200_baseline.json \
  --compare  snapshots/server01_2025-10-08_0200_weekly-review.json \
  --output   diff/server01_diff_2025-10-01_vs_2025-10-08.json

# Post-patch verification comparison
bash linux/scripts/compare-snapshots.sh \
  --baseline snapshots/server01_2025-10-01_0200_baseline.json \
  --compare  snapshots/server01_2025-10-15_0200_post-patch.json \
  --output   diff/server01_diff_2025-10-01_vs_2025-10-15.json
```

**Output:**
```
{--output path}   (diff JSON file)
```

---

### drift-report.sh

Generates a Markdown and JSON drift report from the diff output of `compare-snapshots.sh`, applying severity classification per category.

**Requires:** Bash 4.0+, jq

**Syntax:**
```bash
drift-report.sh --diff <path> --config <path> --output-dir <path>
```

**Options:**

| Option | Required | Description |
|---|---|---|
| `--diff <path>` | Yes | Path to the diff JSON file produced by `compare-snapshots.sh` |
| `--config <path>` | Yes | Path to `snapshot.conf`, used to read severity thresholds |
| `--output-dir <path>` | Yes | Directory where the Markdown and JSON report files will be written |
| `--help` | No | Prints usage information and exits |

**Exit Codes:**

| Code | Meaning |
|---|---|
| 0 | Success - reports written, no CRITICAL findings |
| 1 | Fatal error - reports were not written |
| 3 | Success - reports written, CRITICAL severity findings present |

**Common Invocations:**
```bash
# Generate report from a weekly comparison diff
bash linux/scripts/drift-report.sh \
  --diff       diff/server01_diff_2025-10-01_vs_2025-10-08.json \
  --config     linux/config/snapshot.conf \
  --output-dir reports

# Generate report and branch on CRITICAL findings in a wrapper script
bash linux/scripts/drift-report.sh \
  --diff diff/server01_diff.json \
  --config linux/config/snapshot.conf \
  --output-dir reports
if [[ $? -eq 3 ]]; then
    echo "CRITICAL findings detected. Team notification required."
fi
```

**Output:**
```
reports/{hostname}_drift-report_{YYYY-MM-DD}.md
reports/{hostname}_drift-report_{YYYY-MM-DD}.json
```

---

## systemd Management Commands

Quick reference for managing the Linux scheduling components post-deployment.

```bash
# Enable and start the timer (initial setup)
sudo systemctl enable --now snapshot.timer

# Check timer status and next scheduled run
systemctl list-timers snapshot.timer

# Run a snapshot immediately (without waiting for the timer)
sudo systemctl start snapshot.service

# View the most recent snapshot execution log
sudo journalctl -u snapshot.service -n 50 --no-pager

# View logs for a specific date
sudo journalctl -u snapshot.service --since "2025-10-08 00:00:00" --until "2025-10-08 23:59:59"

# Disable automated snapshots temporarily
sudo systemctl stop snapshot.timer

# Re-enable automated snapshots
sudo systemctl start snapshot.timer

# Reload unit files after editing snapshot.service or snapshot.timer
sudo systemctl daemon-reload
```

---

## Windows Scheduled Task Management Commands

Quick reference for managing the Windows scheduling components post-deployment.

```powershell
# Check task status and next run time
Get-ScheduledTask -TaskName "ConfigDriftDetector-Snapshot" | Get-ScheduledTaskInfo

# Run a snapshot immediately (without waiting for the schedule)
Start-ScheduledTask -TaskName "ConfigDriftDetector-Snapshot"

# Check the result of the last scheduled run
(Get-ScheduledTaskInfo -TaskName "ConfigDriftDetector-Snapshot").LastTaskResult

# Disable automated snapshots temporarily
Disable-ScheduledTask -TaskName "ConfigDriftDetector-Snapshot"

# Re-enable automated snapshots
Enable-ScheduledTask -TaskName "ConfigDriftDetector-Snapshot"

# View the full task definition
(Get-ScheduledTask -TaskName "ConfigDriftDetector-Snapshot").Actions
(Get-ScheduledTask -TaskName "ConfigDriftDetector-Snapshot").Triggers

# Export the live task XML for audit comparison
schtasks /query /tn "ConfigDriftDetector-Snapshot" /xml
```

---

## File Naming Reference

Quick reference for all file naming conventions used across the toolkit.

| File Type | Pattern | Example |
|---|---|---|
| Windows Snapshot | `{HOSTNAME}_{YYYY-MM-DD}_{HHMM}_{label}.json` | `SERVER01_2025-10-01_0200_baseline.json` |
| Linux Snapshot | `{hostname}_{YYYY-MM-DD}_{HHMM}_{label}.json` | `server01_2025-10-01_0200_baseline.json` |
| Diff File | `{hostname}_diff_{YYYY-MM-DD}_vs_{YYYY-MM-DD}.json` | `server01_diff_2025-10-01_vs_2025-10-08.json` |
| Markdown Report | `{hostname}_drift-report_{YYYY-MM-DD}.md` | `server01_drift-report_2025-10-08.md` |
| JSON Report | `{hostname}_drift-report_{YYYY-MM-DD}.json` | `server01_drift-report_2025-10-08.json` |
| Execution Log | `snapshot_{YYYY-MM-DD}.log` | `snapshot_2025-10-08.log` |

---

