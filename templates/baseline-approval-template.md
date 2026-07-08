# Baseline Approval Record

## Purpose

This document is the formal approval record for a configuration baseline snapshot. It is completed every time a new baseline is established - at initial server deployment, after an approved change cycle, or after a scheduled re-baseline - and filed with the server's build documentation or change record.

A completed baseline approval record serves three operational purposes:

1. **Authorisation trail:** It documents that a named, accountable person reviewed and approved the server state captured in the baseline, rather than the baseline being taken opportunistically or without oversight.
2. **Integrity reference:** It records the SHA-256 checksum of the baseline snapshot file at the time of approval. Future weekly reviews compare the live baseline file's checksum against this value to detect Threat 2 (Baseline Tampering) per `docs/threat-model.md`.
3. **Context preservation:** It records known deviations from standard configuration, approved exceptions, and environmental notes that will explain otherwise unexpected findings in future drift reports.

**One completed baseline approval record must exist for every server using this toolkit.**

---

## Record Identification

| Field | Value |
|---|---|
| Record ID | BL-[HOSTNAME]-[YYYY-MM-DD] (e.g. BL-SERVER01-2025-10-01) |
| Server hostname | |
| Server FQDN (if different) | |
| Platform | Windows Server 2022 / RHEL 9 (circle one) |
| Server purpose / role | (e.g. file server, web server, database server, general purpose) |
| Environment | Production / Pre-Production / Development / Lab (circle one) |
| Date of baseline capture | |
| Date of this approval | |

---

## Section 1 - Baseline Snapshot Identification

| Field | Value |
|---|---|
| Baseline snapshot filename | |
| Baseline snapshot full path | |
| Baseline snapshot timestamp (from metadata) | |
| Snapshot script version (from metadata) | |
| Captured by (account name, from metadata) | |

**Integrity Record:**

| Field | Value |
|---|---|
| SHA-256 of baseline snapshot file | |
| SHA-256 verified by | |
| SHA-256 verification date | |

*To generate the SHA-256 at approval time:*
- Windows: `Get-FileHash .\snapshots\<filename> -Algorithm SHA256 | Select-Object Hash`
- Linux: `sha256sum snapshots/<filename>`

*Record the complete hash string (64 hexadecimal characters). This value is the reference against which future weekly reviews verify baseline integrity.*

---

## Section 2 - Pre-Approval Verification

The approver confirms each of the following was verified before approving this baseline.

### 2.1 - Baseline Snapshot Quality

- [ ] The snapshot script exited with code 0 (no errors).
- [ ] The snapshot's `capture_errors` array is empty.
  - Windows: `(Get-Content .\snapshots\<filename> -Raw | ConvertFrom-Json).capture_errors`
  - Linux: `jq '.capture_errors' snapshots/<filename>`
  Expected output: `[]`
- [ ] The snapshot `metadata.hostname` matches the expected server hostname.
- [ ] The snapshot timestamp is consistent with the intended capture time (within a 5-minute tolerance).
- [ ] `checklists/baseline-snapshot-checklist.md` was completed and signed off before this snapshot was taken.
  - Completed by: ________________
  - Date: ________________

### 2.2 - Server State at Baseline

The approver confirms the server was in the following state when the baseline was captured.

| Item | Confirmed | Notes |
|---|---|---|
| Fully provisioned and configured per build documentation | | |
| Patched to current approved patch level | | |
| All intended software present, no test/temporary software | | |
| All services in intended state (started or stopped as designed) | | |
| All local user accounts known, documented, and intentional | | |
| Firewall configuration reflects approved network policy | | |
| No temporary firewall rules present | | |
| Scheduled tasks / cron jobs are all known and intentional | | |
| Sudo access / Administrator group membership reflects approved access | | |
| SELinux in Enforcing mode (Linux only, or documented exception exists) | | |

### 2.3 - Known Deviations and Approved Exceptions

*Record here any aspects of the server's configuration at baseline time that deviate from the standard build, are unusual, or would otherwise appear as unexpected findings in a future drift report. Future operators reviewing drift against this baseline need this context to correctly classify those findings.*

*If there are no known deviations, record "None." Do not leave this field blank - a blank field is ambiguous.*

**Known deviations:**

| Item | Description | Approved by | Approval Reference |
|---|---|---|---|
| | | | |
| | | | |
| | | | |

*Example entries:*
- *Port 8080 is listening - approved for temporary developer access until 2025-11-01, per ticket DEV-2241*
- *Print Spooler service is disabled - approved per security hardening standard SEC-012*
- *User account `svc_vendor` is present - approved vendor service account, ticket VND-0091*

---

## Section 3 - Baseline Snapshot Contents Summary

*This section provides a human-readable summary of the key counts captured in the baseline, cross-referencing the values recorded during `checklists/baseline-snapshot-checklist.md` Step 2.1. Significant discrepancies between the checklist values and the snapshot contents should be investigated before approval.*

| Category | Count in Snapshot | Notes |
|---|---|---|
| Installed software / packages | | |
| Total services captured | | |
| Running / active services | | |
| Local user accounts | | |
| Enabled local user accounts | | |
| Firewall rules (Windows) / Active zones (Linux) | | |
| Scheduled tasks / Cron jobs | | |
| Listening ports | | |
| Sudo rules (Linux) | | |
| Wheel group members (Linux) | | |
| SELinux mode (Linux) | | |
| Config file checksums captured (Linux) | | |
| Pending updates (Windows) | | |
| Capture errors | Must be 0 | |

*To populate these values:*
- Windows: `Get-Content .\snapshots\<filename> -Raw | ConvertFrom-Json | Select-Object -Property @{n='Software';e={$_.software.Count}}, @{n='Services';e={$_.services.Count}}, @{n='Users';e={$_.local_users.Count}}, @{n='FirewallRules';e={$_.firewall.Count}}, @{n='ScheduledTasks';e={$_.scheduled_jobs.Count}}, @{n='Ports';e={$_.listening_ports.Count}}`
- Linux: `jq '{software: (.software|length), services: (.services|length), users: (.local_users|length), firewall_zones: (.firewall.zones|length), cron_jobs: (.scheduled_jobs|length), ports: (.listening_ports|length), sudo_rules: (.platform_specific.sudo_access.rules|length), wheel_members: (.platform_specific.sudo_access.wheel_group_members|length), selinux: .platform_specific.selinux.enforcement_mode, checksums: (.config_checksums|length), errors: (.capture_errors|length)}' snapshots/<filename>`

---

## Section 4 - Storage and Retention

### 4.1 - Primary Storage

| Field | Value |
|---|---|
| Baseline file stored at (primary location) | |
| Directory permissions verified per `docs/security-considerations.md` | Yes / No |
| Access restricted to administrative accounts only | Yes / No |

### 4.2 - Secondary (Read-Only) Copy

Per `docs/threat-model.md` Threat 2 (Baseline Tampering) mitigation, a read-only copy of the baseline is stored in a separate location from the primary snapshot directory.

| Field | Value |
|---|---|
| Secondary copy location | |
| Secondary copy stored by | |
| Secondary copy date | |
| Secondary copy SHA-256 verified | Yes / No |
| Secondary copy access restricted | Yes / No |

### 4.3 - Retention Policy

| Field | Value |
|---|---|
| This baseline supersedes previous baseline dated | (or "N/A - first baseline for this server") |
| Previous baseline retained at | (location, or "N/A") |
| Previous baseline approval record retained at | (location, or "N/A") |

*Baseline snapshot files are never automatically deleted by the toolkit's retention policy. They are retained indefinitely unless manually removed. Previous baselines should be retained for the duration of your organisation's change record retention policy, even after they are superseded - they provide a historical record of approved server states over time.*

---

## Section 5 - Scheduling Confirmation

- [ ] Automated snapshot scheduling is configured and active for this server.
  - Windows: `Get-ScheduledTask -TaskName "ConfigDriftDetector-Snapshot" | Select-Object State`
    Expected: `Ready`
  - Linux: `systemctl is-active snapshot.timer`
    Expected: `active`

- [ ] The scheduling mechanism has been tested by triggering a manual run and confirming a `scheduled`-labelled snapshot was produced:
  - Windows: `Start-ScheduledTask -TaskName "ConfigDriftDetector-Snapshot"`
  - Linux: `sudo systemctl start snapshot.service`
  - Test run snapshot filename: ________________

- [ ] Snapshot output directory is writable by the scheduling account (SYSTEM on Windows, root on Linux).

---

## Section 6 - Approval

### Primary Approver

The primary approver confirms they have reviewed this record, verified the snapshot quality items in Section 2.1, confirmed the server state items in Section 2.2, and accept this snapshot as the authorised baseline for this server.

| Field | Value |
|---|---|
| Name | |
| Role / Title | |
| Signature | |
| Date | |

### Secondary Approver (if required by your change control process)

| Field | Value |
|---|---|
| Name | |
| Role / Title | |
| Signature | |
| Date | |

---

## Section 7 - Future Review Reference

This section is completed at the time of approval and referenced during future weekly reviews and drift investigations.

### 7.1 - Next Scheduled Review

| Field | Value |
|---|---|
| Scheduled re-baseline date (if applicable) | |
| Circumstances requiring a new baseline outside schedule | Approved major change / Security incident / Annual re-baseline |

### 7.2 - Open Items at Baseline Time

*List any known issues, in-progress remediations, or planned changes that were present at baseline time but not yet complete. Future drift reviews comparing against this baseline should expect these items to appear as changes.*

| Item | Expected Change | Expected By | Ticket Reference |
|---|---|---|---|
| | | | |
| | | | |

### 7.3 - Contact Information

*Record the primary contact for questions about this baseline and the server's configuration at the time it was established.*

| Role | Name | Contact |
|---|---|---|
| Primary administrator | | |
| Secondary administrator | | |
| Team / group mailbox (if applicable) | | |

---

## Document Control

| Field | Value |
|---|---|
| Template version | 1.0 |
| Record created | |
| Record last updated | |
| Filed with | (change record reference, build documentation location, or equivalent) |

---

