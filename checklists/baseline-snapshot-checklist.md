
# Baseline Snapshot Checklist

## Purpose

This checklist is completed before every baseline snapshot is taken. A baseline represents the known-good, approved state of a server. A baseline taken on a server that is not in a clean, verified state will corrupt all future drift comparisons against it - reporting expected drift as clean and hiding real drift as expected.

**Do not take a baseline snapshot until every item below is confirmed.**

Print this checklist or copy it into your change record before beginning.

---

## Identification

| Field | Value |
|---|---|
| Server hostname | |
| Platform | Windows Server 2022 / RHEL 9 (circle one) |
| Date of baseline capture | |
| Operator completing this checklist | |
| Reason for new baseline | Initial deployment / Post-approved-change / Scheduled re-baseline (circle one) |

---

## Section 1 - Pre-Conditions

These conditions must be true before the baseline snapshot is taken. Mark each as confirmed or provide a note if not applicable.

### 1.1 - Server State

- [ ] The server has been fully provisioned and configured according to its build documentation or runbook.

- [ ] All intended software is installed. No temporary or test software is present that will not be part of the permanent configuration.

- [ ] All intended services are in their expected state (started or stopped as designed). No services are in a transitional state (starting, stopping, restarting) at the time of capture.

- [ ] The server has been fully patched to the current approved patch level. Pending updates that are part of the approved configuration should not appear in a clean baseline as outstanding items.
  - Windows: confirm with `Get-HotFix | Sort-Object InstalledOn -Descending | Select-Object -First 5`
  - Linux: confirm with `sudo dnf check-update --quiet; echo "Exit: $?"`

- [ ] No one is actively logged into the server performing configuration changes at the time of capture. Active interactive sessions can affect service state and port capture.

- [ ] The server has not been rebooted in the last 5 minutes. Allow sufficient time after a reboot for all services to reach their steady state before capturing.

### 1.2 - Security State

- [ ] All local user accounts on the server are known, documented, and intentional. No orphaned, test, or temporary accounts are present.
  - Windows: `Get-LocalUser | Select-Object Name, Enabled, LastLogon`
  - Linux: `awk -F: '$3 >= 1000 {print $1, $3, $7}' /etc/passwd`

- [ ] All firewall rules are in their intended configuration. No temporary rules added for troubleshooting or testing are still present.
  - Windows: `Get-NetFirewallRule | Where-Object Enabled -eq True | Select-Object DisplayName, Direction, Action | Sort-Object DisplayName`
  - Linux: `sudo firewall-cmd --list-all-zones`

- [ ] Sudo access (Linux) or local Administrators group membership (Windows) reflects only accounts that are intended to have elevated access.
  - Windows: `Get-LocalGroupMember -Group "Administrators"`
  - Linux: `sudo cat /etc/sudoers; getent group wheel`

- [ ] SELinux is in Enforcing mode (Linux only) unless a documented and approved exception exists.
  - Linux: `getenforce`
  Expected output: `Enforcing`

### 1.3 - Scheduled Jobs State

- [ ] All scheduled tasks (Windows) or cron jobs / systemd timers (Linux) present on the server are known, documented, and intentional. No test or temporary automation is still active.
  - Windows: `Get-ScheduledTask | Where-Object State -ne Disabled | Select-Object TaskName, TaskPath, State`
  - Linux: `sudo crontab -l 2>/dev/null; ls /etc/cron.d/ 2>/dev/null; systemctl list-timers --no-pager`

### 1.4 - Toolkit State

- [ ] The snapshot-config.json (Windows) or snapshot.conf (Linux) has been reviewed and reflects the intended capture categories, retention policy, and severity thresholds for this server.

- [ ] The snapshot output directory exists and is writable by the account that will run the snapshot.
  - Windows: `Test-Path .\snapshots`
  - Linux: `test -d snapshots && test -w snapshots && echo "writable" || echo "not writable"`

- [ ] The snapshot output directory permissions have been configured per `docs/security-considerations.md`. Sensitive snapshot data must not be accessible to non-administrative accounts.

---

## Section 2 - Baseline Capture

Complete these steps in order after all Section 1 items are confirmed.

### Step 2.1 - Record the Pre-Capture State

Record the following values immediately before running the snapshot script. These values serve as a manual cross-reference to verify the snapshot captured the expected server state.

| Item | Value at Time of Capture |
|---|---|
| Current time (UTC) | |
| Uptime (Windows: `(Get-Date) - (gcim Win32_OperatingSystem).LastBootUpTime`; Linux: `uptime`) | |
| Number of local users (Windows: `(Get-LocalUser).Count`; Linux: `getent passwd | wc -l`) | |
| Number of running services (Windows: `(Get-Service | Where Status -eq Running).Count`; Linux: `systemctl list-units --type=service --state=running --no-pager --no-legend | wc -l`) | |
| SELinux mode (Linux only, `getenforce`) | |

### Step 2.2 - Run the Snapshot Script

**Windows (run from an elevated PowerShell session):**
```powershell
.\windows\scripts\New-ConfigSnapshot.ps1 -ConfigPath .\windows\config\snapshot-config.json -Label "baseline"
```

**Linux (run as root or with sudo):**
```bash
sudo bash linux/scripts/take-snapshot.sh --config linux/config/snapshot.conf --label baseline
```

### Step 2.3 - Confirm Successful Capture

- [ ] The script exited with code 0.
  - Windows: `$LASTEXITCODE` immediately after the script returns
  - Linux: `echo $?` immediately after the script returns

- [ ] A snapshot file labelled `baseline` was created in the snapshot output directory.
  - Windows: `Get-ChildItem .\snapshots\*_baseline.json`
  - Linux: `ls snapshots/*_baseline.json`

- [ ] The snapshot file's `capture_errors` array is empty.
  - Windows: `(Get-Content .\snapshots\*_baseline.json -Raw | ConvertFrom-Json).capture_errors`
  - Linux: `jq '.capture_errors' snapshots/*_baseline.json`
  Expected output: `[]`

- [ ] The snapshot file's `metadata.hostname` matches the expected server hostname.
  - Windows: `(Get-Content .\snapshots\*_baseline.json -Raw | ConvertFrom-Json).metadata.hostname`
  - Linux: `jq -r '.metadata.hostname' snapshots/*_baseline.json`

- [ ] The snapshot file's `metadata.snapshot_timestamp` is within 2 minutes of the time recorded in Step 2.1.

- [ ] The user counts, service counts, and other values in the snapshot broadly match those recorded in Step 2.1. Significant discrepancies warrant investigation before this snapshot is used as a baseline.
  - Windows: `(Get-Content .\snapshots\*_baseline.json -Raw | ConvertFrom-Json).local_users.Count`
  - Linux: `jq '.local_users | length' snapshots/*_baseline.json`

---

## Section 3 - Post-Capture Actions

- [ ] Complete `templates/baseline-approval-template.md` to formally record this baseline as reviewed and approved. File the completed template with the server's build documentation or change record.

- [ ] Record the snapshot filename and SHA-256 checksum in the baseline approval template:
  - Windows: `Get-FileHash .\snapshots\*_baseline.json -Algorithm SHA256`
  - Linux: `sha256sum snapshots/*_baseline.json`

- [ ] Store a read-only copy of the baseline snapshot file in a separate location from the live snapshot directory (e.g. a separate folder, a backup share, or an archived ticket attachment). This provides a tamper-evident reference per `docs/threat-model.md` Threat 2.

- [ ] If automated scheduled snapshots are not yet configured, proceed to `docs/operational-guide.md` Section 6 to set up the Windows Scheduled Task or Linux systemd timer now.

- [ ] File any relevant notes about the server's state at baseline time (known non-standard configurations, approved deviations from standard build, deliberate service states) in the baseline approval template's notes field. These notes will be referenced during future drift reviews when findings appear unexpected.

---

## Sign-Off

| Field | Value |
|---|---|
| Baseline snapshot filename | |
| Baseline snapshot SHA-256 | |
| Checklist completed by | |
| Date completed | |
| Reviewed by (if applicable) | |

---

