# Troubleshooting

## Purpose of This Document

This document catalogues every known failure mode of the toolkit itself - across configuration, snapshot capture, comparison, reporting, and scheduling - with diagnosis steps and resolution procedures for both platforms. A tool that detects operational problems must be able to support itself when something goes wrong with the tool itself.

Each entry follows the same format: symptom, likely cause, diagnosis, resolution.

---

## How to Use This Document

1. Identify the symptom you are experiencing in the relevant section below.
2. Follow the diagnosis steps to confirm the cause.
3. Apply the resolution.
4. If the issue persists after the documented resolution, check the script's own log file (`logs/` directory) for the exact error message before escalating, as the log will often contain detail not visible in the console output alone.

---

## Configuration Issues

### Symptom: Script exits immediately with "Configuration file not found"

**Likely cause:** The `-ConfigPath` (Windows) or `--config` (Linux) argument points to a path that does not exist, or a relative path was supplied from an unexpected working directory.

**Diagnosis:**
```powershell
# Windows
Test-Path $ConfigPath
```
```bash
# Linux
test -f "$CONFIG_PATH" && echo "exists" || echo "not found"
```

**Resolution:** Use an absolute path, or confirm your current working directory before running the script with a relative path. From the repository root:
```powershell
.\windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath ".\windows\config\snapshot-config.json" -Label "test"
```
```bash
bash linux/scripts/take-snapshot.sh --config "linux/config/snapshot.conf" --label "test"
```

---

### Symptom: Script exits with "Failed to parse configuration file as JSON" (Windows) or "did not load expected variables" (Linux)

**Likely cause:** The configuration file has been manually edited and a syntax error was introduced - a missing comma, an unclosed quote, or a stray character.

**Diagnosis:**
```powershell
# Windows
Get-Content .\windows\config\snapshot-config.json -Raw | ConvertFrom-Json
```
The error message returned by `ConvertFrom-Json` will indicate the approximate line and character where parsing failed.

```bash
# Linux
bash -n linux/config/snapshot.conf
```
This checks shell syntax without executing. For a more thorough check, attempt to source it directly and observe the error:
```bash
bash -c 'source linux/config/snapshot.conf'
```

**Resolution:** Correct the syntax error indicated by the diagnostic command. If the error is not obvious, restore the configuration file from version control and re-apply your intended changes one at a time:
```bash
git checkout -- linux/config/snapshot.conf
```

---

## Windows Snapshot Capture Issues

### Symptom: "This script must be run as Administrator"

**Likely cause:** PowerShell session is not elevated.

**Diagnosis:** Check the PowerShell window title bar - an elevated session typically shows "Administrator: Windows PowerShell".

**Resolution:** Close the current session. Right-click PowerShell (or Windows Terminal) and select "Run as Administrator", then re-run the script.

---

### Symptom: Installed software list appears incomplete or differs significantly between runs

**Likely cause:** `useWmiQuery` is set to `false` (the safe default) and some software does not register correctly in the registry uninstall keys, or a third-party installer uses a non-standard registration method.

**Diagnosis:**
```powershell
Get-Content .\windows\config\snapshot-config.json -Raw | ConvertFrom-Json | Select-Object -ExpandProperty installedSoftwareOptions
```

**Resolution:** This is a known limitation, not a defect - see `docs/snapshot-methodology.md` Category 1. If complete software inventory accuracy is critical for your use case, temporarily set `useWmiQuery` to `true` for a single comparison run, understanding this may trigger Windows Installer self-repair behaviour on some systems (see the same methodology section for the documented Microsoft-acknowledged side effect).

---

### Symptom: Windows Update capture step logs a warning and `pending_updates` is empty

**Likely cause:** The Windows Update service is stopped, the Windows Update Agent COM interface is unreachable, or the server has no network path to a WSUS server or Windows Update endpoint.

**Diagnosis:**
```powershell
Get-Service -Name wuauserv
```
Expected: `Status` should be `Running`. If `Stopped`, this explains the warning.

**Resolution:** If Windows Update is intentionally disabled in your environment (e.g. updates are managed entirely through a separate patch management process), this warning is expected and can be disregarded - set `pendingUpdates` to `false` in `captureCategories` to suppress the warning on future runs. If Windows Update should be active, investigate why the service is stopped as a separate operational issue outside the scope of this toolkit.

---

### Symptom: Local user group membership appears empty for all users

**Likely cause:** `Get-LocalGroupMember` can fail silently for certain group types (notably groups containing orphaned SIDs from deleted domain accounts, if this server was ever domain-joined).

**Diagnosis:** Check the snapshot's `capture_errors` array and the log file for `WARN` entries containing "Could not enumerate group membership".

**Resolution:** Identify the specific group causing the failure by running `Get-LocalGroupMember` manually for each local group and observing which one throws an error. Remove the orphaned SID using `lusrmgr.msc` or `Remove-LocalGroupMember` if appropriate, or accept the limitation for that specific group and document it.

---

## Linux Snapshot Capture Issues

### Symptom: "This script must be run as root (or via sudo)"

**Likely cause:** Script was invoked without `sudo` or not as the root user.

**Diagnosis:**
```bash
id -u
```
Expected: `0` for root. Any other number means non-root.

**Resolution:**
```bash
sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label baseline
```

---

### Symptom: "Required command 'jq' not found on PATH"

**Likely cause:** `jq` is not installed. This is common on minimal RHEL 9 installations.

**Diagnosis:**
```bash
command -v jq
```

**Resolution:**
```bash
sudo dnf install -y jq
```

---

### Symptom: firewall section shows `"firewalld_active": false` unexpectedly

**Likely cause:** firewalld is genuinely stopped, or it is masked/disabled.

**Diagnosis:**
```bash
systemctl status firewalld
```

**Resolution:** If firewalld should be running in your environment, this is itself a significant drift finding worth investigating (a stopped firewall service is a CRITICAL-severity concern in most environments) - do not simply "fix" the toolkit's output by re-enabling firewalld without first determining why it was stopped. If firewalld is intentionally not used in your environment (uncommon on RHEL 9, but possible if an alternative firewall management approach is in place), set `CAPTURE_FIREWALL_RULES=false` in `snapshot.conf` to suppress this section.

---

### Symptom: Sudoers parsing produces unexpected or missing entries

**Likely cause:** A custom `Cmnd_Alias`, `User_Alias`, or complex multi-line sudoers syntax is not fully captured by the line-based parser used in `take-snapshot.sh`.

**Diagnosis:** Check the snapshot's `platform_specific.sudo_access.sudoers_valid` field:
```bash
jq '.platform_specific.sudo_access.sudoers_valid' snapshots/*_baseline.json
```
If `false`, the underlying sudoers file has a syntax problem independent of this toolkit. If `true` but entries still look wrong, the parser's line-based approach has a known limitation with complex alias-based sudoers configurations.

**Resolution:** This toolkit's sudoers parsing is intentionally simple (see `docs/snapshot-methodology.md` Category 4) and captures direct principal-to-rule grants reliably, but may not fully resolve sudoers `_Alias` indirection. For environments with complex alias-based sudoers configurations, treat the `wheel_group_members` field as the more reliable signal for privilege escalation drift, and periodically perform a manual sudoers review as a supplement.

---

### Symptom: Listening ports capture returns very few or zero entries despite known running services

**Likely cause:** The `ss` command's output format can vary slightly between util-linux versions, and the script's `grep -oP` extraction for process name and PID may not match on all formats.

**Diagnosis:**
```bash
ss -tlnup | head -5
```
Compare the raw output format against what the script expects (the `users:(("processname",pid=NNNN,...))` format). If your `ss` version produces a different format, the regex extraction will fail to populate `owning_process` and `owning_pid`, though the protocol/address/port fields should still populate correctly.

**Resolution:** Confirm at minimum that protocol, address, and port fields are populated even if process attribution is incomplete:
```bash
jq '.listening_ports[] | {protocol, local_address, local_port}' snapshots/*_baseline.json
```
If these core fields are also empty, check that `ss` is actually installed (`command -v ss`) and that the script is being run with sufficient privileges to see all socket owners (root, already required).

---

## Comparison Script Issues

### Symptom: "Schema version mismatch" warning appears on every comparison

**Likely cause:** One snapshot was taken with an older version of the toolkit before a schema-affecting update (see `CHANGELOG.md` for any MAJOR version changes).

**Diagnosis:**
```powershell
# Windows
(Get-Content .\snapshots\old-snapshot.json -Raw | ConvertFrom-Json).metadata.schema_version
(Get-Content .\snapshots\new-snapshot.json -Raw | ConvertFrom-Json).metadata.schema_version
```
```bash
# Linux
jq '.metadata.schema_version' snapshots/old-snapshot.json snapshots/new-snapshot.json
```

**Resolution:** This is a warning, not an error - the comparison will still run. If results look incomplete or incorrect, take a fresh baseline snapshot using the current script version and use that as your new reference point going forward, rather than comparing across a schema boundary.

---

### Symptom (Linux): "Python comparison logic failed" with a Python traceback in the output

**Likely cause:** One of the input snapshot files has a structurally unexpected JSON shape - for example, a category that is `null` instead of an empty array, or a hand-edited snapshot file with a typo in a field name.

**Diagnosis:** Read the Python traceback printed to the console - it will indicate the specific line and operation that failed, typically a `KeyError` or `AttributeError` pointing to the malformed field.

**Resolution:** Validate both input files independently before re-running:
```bash
jq empty snapshots/baseline.json && echo "valid JSON"
jq '.software, .services, .local_users' snapshots/baseline.json
```
If a snapshot file was manually edited, restore it from its original generated state rather than continuing to hand-edit JSON. Snapshot files should never require manual editing in normal operation.

---

### Symptom: Comparison reports a large number of unexpected "modified" entries with no apparent real-world change

**Likely cause (both platforms):** Field ordering or formatting differences in array-type fields (e.g. group memberships) where the same logical value is represented in a different order between the two snapshots.

**Diagnosis:**
```bash
# Linux example
jq '.categories.local_users.modified[0]' diff/test.json
```
Examine the `changed_fields` array - if `from` and `to` contain the same elements in a different order, this confirms the cause.

**Resolution:** This is a known limitation of the current string-based field comparison for array values. Treat such findings as false positives during review, but report this pattern if it recurs frequently, as it indicates the comparison logic may benefit from order-independent array comparison for that specific field in a future toolkit update - see `docs/architecture-overview.md` "Extending This Toolkit" for the process to propose and implement such a change.

---

## Report Generation Issues

### Symptom: Markdown report renders with broken or missing tables

**Likely cause:** A captured field contains a pipe character (`|`) or other Markdown-significant character (e.g. a firewall rule name or scheduled task argument containing a literal `|`), which breaks the Markdown table syntax.

**Diagnosis:** Open the raw Markdown file in a plain text editor (not a renderer) and locate the malformed table row - it will typically have more or fewer columns than the header row.

**Resolution:** This is a known limitation of the current Markdown rendering, which does not escape Markdown-significant characters in captured field values. Use the accompanying JSON report for any finding where the Markdown rendering appears broken - the JSON report is unaffected by this issue and always contains the complete, accurate data:
```bash
jq '.findings.scheduled_jobs' reports/*_drift-report_*.json
```

---

### Symptom: Report shows `NOTABLE` severity for a category you expected to be `CRITICAL` (or vice versa)

**Likely cause:** The severity threshold for that category/change-type combination in the configuration file does not match your expectation, or it has been customised by a previous operator.

**Diagnosis:**
```powershell
# Windows
(Get-Content .\windows\config\snapshot-config.json -Raw | ConvertFrom-Json).severityThresholds
```
```bash
# Linux
grep "^SEVERITY_" linux/config/snapshot.conf
```

**Resolution:** Adjust the relevant threshold value in the configuration file to match your organisation's risk tolerance. Severity thresholds are intentionally operator-configurable - see `windows/config/snapshot-config.json` and `linux/config/snapshot.conf` inline comments for the full list of adjustable values. Document any deviation from the toolkit's documented defaults so future operators understand why your environment's thresholds differ.

---

## Scheduling Issues

### Symptom (Windows): Scheduled Task shows `LastTaskResult` of a non-zero value

**Likely cause:** The snapshot script encountered an error during its scheduled run. A `LastTaskResult` of `2` corresponds to the script's own exit code 2 (completed with partial errors); other non-zero values typically indicate the script failed to start or crashed unexpectedly.

**Diagnosis:**
```powershell
Get-ScheduledTaskInfo -TaskName "ConfigDriftDetector-Snapshot"
```
Then check the log file in the configured `logDirectory` for the date of the failed run.

**Resolution:** If `LastTaskResult` is `2`, review the `capture_errors` array in that day's snapshot file - this is an expected, handled condition, not a scheduling failure. If `LastTaskResult` indicates the script never started (commonly `1` or a large hexadecimal value), confirm the absolute paths in the task's action match an existing, accessible script and config file location, and re-run `Register-SnapshotTask.ps1` to refresh the task definition.

---

### Symptom (Windows): Scheduled Task never runs, `NextRunTime` is blank or in the past

**Likely cause:** The task is disabled, or the Task Scheduler service itself is not running.

**Diagnosis:**
```powershell
Get-ScheduledTask -TaskName "ConfigDriftDetector-Snapshot" | Select-Object State
Get-Service -Name Schedule
```

**Resolution:** If `State` shows `Disabled`:
```powershell
Enable-ScheduledTask -TaskName "ConfigDriftDetector-Snapshot"
```
If the Task Scheduler service itself is stopped (unusual, as it is a core Windows service), investigate why as a separate system-level issue, then restart it:
```powershell
Start-Service -Name Schedule
```

---

### Symptom (Linux): Timer shows as active but the service never produces output

**Likely cause:** The `ExecStart` path in `snapshot.service` still contains the placeholder path (`/opt/server-config-drift-detector`) and does not match the actual deployed repository location.

**Diagnosis:**
```bash
sudo systemctl cat snapshot.service
```
Compare the `ExecStart` line against your actual repository path.

**Resolution:** Edit `/etc/systemd/system/snapshot.service`, correct the `ExecStart` and `ReadWritePaths` lines to your actual absolute paths, then:
```bash
sudo systemctl daemon-reload
sudo systemctl restart snapshot.timer
sudo systemctl start snapshot.service
sudo journalctl -u snapshot.service --since "5 minutes ago"
```

---

### Symptom (Linux): `journalctl -u snapshot.service` shows a permission denied error

**Likely cause:** `ReadWritePaths` in `snapshot.service` does not include the actual configured `SNAPSHOT_DIR` or `LOG_DIR` from `snapshot.conf`, so the `ProtectSystem=true` hardening directive is blocking the write.

**Diagnosis:**
```bash
sudo systemctl cat snapshot.service | grep ReadWritePaths
grep -E "SNAPSHOT_DIR|LOG_DIR" linux/config/snapshot.conf
```
Confirm the resolved absolute paths match between the two.

**Resolution:** Update `ReadWritePaths` in `/etc/systemd/system/snapshot.service` to include every directory the script needs to write to, then:
```bash
sudo systemctl daemon-reload
sudo systemctl restart snapshot.timer
```

---

## Escalation

If an issue is not covered in this document, gather the following before seeking further assistance:

1. The exact command run, including all arguments
2. The full console output
3. The relevant log file from the `logs/` directory, for the date in question
4. The output of `git log -1` to confirm the exact toolkit version in use
5. Platform and OS version (`Get-ComputerInfo | Select WindowsProductName, OsVersion` on Windows; `cat /etc/os-release` on Linux)

This information allows any reviewer - a colleague, or a future contributor extending the toolkit - to reproduce and diagnose the issue without a lengthy back-and-forth.

---