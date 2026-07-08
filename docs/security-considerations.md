# Security Considerations

## Purpose of This Document

This document provides concrete, actionable guidance for securing the toolkit's own operation - file permissions, storage location, access control, and execution context. Where `docs/threat-model.md` explains *what could go wrong and why it matters*, this document explains *exactly what to configure to prevent it*.

This is the document an operator should follow during deployment, not just read once.

---

## File Permissions

### Windows Server 2022

| Path | Recommended Permissions | Rationale |
|---|---|---|
| `windows\scripts\` | Administrators: Full Control. Authenticated Users: Read & Execute. | Scripts must not be writable by non-administrative accounts - see `docs/threat-model.md` Threat 3 (Script Modification). |
| `windows\config\` | Administrators: Full Control. Authenticated Users: Read. | Configuration changes (severity thresholds, capture categories) should require administrative privilege. |
| Snapshot output directory | Administrators: Full Control. SYSTEM: Full Control. No other access. | Snapshots contain high-sensitivity data - see `docs/threat-model.md` Data Sensitivity Classification. |
| Diff and report output directories | Administrators: Full Control. SYSTEM: Full Control. No other access. | Same rationale as snapshot output - diff and report files inherit the sensitivity of the data they describe. |
| Log directory | Administrators: Full Control. SYSTEM: Full Control. Authenticated Users: Read (optional). | Logs do not contain captured data (see `docs/architecture-overview.md`), so read access is lower risk, but write access should remain restricted to prevent log tampering. |

**Applying these permissions:**

```powershell
# Restrict snapshot output directory to Administrators and SYSTEM only
$path = "C:\Tools\server-config-drift-detector\snapshots"
$acl = Get-Acl $path
$acl.SetAccessRuleProtection($true, $false)  # disable inheritance, remove inherited rules
$adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule("BUILTIN\Administrators", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule("NT AUTHORITY\SYSTEM", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
$acl.AddAccessRule($adminRule)
$acl.AddAccessRule($systemRule)
Set-Acl -Path $path -AclObject $acl
```

**Verification:**
```powershell
Get-Acl "C:\Tools\server-config-drift-detector\snapshots" | Format-List
```
Expected: only Administrators and SYSTEM listed with access; no inherited entries for broader groups such as Users or Authenticated Users.

### RHEL 9

| Path | Recommended Permissions | Rationale |
|---|---|---|
| `linux/scripts/` | `root:root`, mode `750` | Scripts must not be writable or readable by non-root accounts - see `docs/threat-model.md` Threat 3. |
| `linux/config/` | `root:root`, mode `640` | Configuration changes should require root privilege to make; read access can remain slightly broader for operators who need to review settings. |
| Snapshot output directory | `root:root`, mode `700` | Highest sensitivity data on the system - no group or world access. |
| Diff and report output directories | `root:root`, mode `700` | Same rationale as snapshot output. |
| Log directory | `root:root`, mode `750` | Logs do not contain captured data, but write access must remain root-only to prevent tampering. |

**Applying these permissions:**

```bash
sudo chown -R root:root /opt/server-config-drift-detector/linux/scripts
sudo chmod 750 /opt/server-config-drift-detector/linux/scripts
sudo chmod 750 /opt/server-config-drift-detector/linux/scripts/*.sh

sudo chown -R root:root /opt/server-config-drift-detector/linux/config
sudo chmod 640 /opt/server-config-drift-detector/linux/config/snapshot.conf

sudo mkdir -p /opt/server-config-drift-detector/{snapshots,diff,reports,logs}
sudo chown -R root:root /opt/server-config-drift-detector/{snapshots,diff,reports,logs}
sudo chmod 700 /opt/server-config-drift-detector/snapshots
sudo chmod 700 /opt/server-config-drift-detector/diff
sudo chmod 700 /opt/server-config-drift-detector/reports
sudo chmod 750 /opt/server-config-drift-detector/logs
```

**Verification:**
```bash
stat -c "%a %U:%G %n" /opt/server-config-drift-detector/snapshots
```
Expected output: `700 root:root /opt/server-config-drift-detector/snapshots`

---

## Storage Location Guidance

### Do Not

- Store snapshot, diff, or report output on a network share accessible to non-administrative accounts
- Store output in any directory included in a standard user's home directory backup or sync (e.g. OneDrive, Dropbox sync folders)
- Email snapshot or diff JSON files as attachments to distribution lists or shared mailboxes
- Commit any live snapshot, diff, or report file to version control - `.gitignore` prevents accidental commits, but operators should not override this exclusion

### Do

- Store output on local disk, on a volume accessible only to the administrative accounts and the SYSTEM/root execution context
- If centralising reports across multiple servers for audit purposes, transfer only the Markdown report files (not raw snapshots or diffs) over an encrypted channel (SCP, SFTP, or an internal encrypted file share), and store them in a location with equivalent access restrictions to the source server
- Encrypt the storage volume if the server is in a shared physical environment where disk-level access by unauthorised parties is a credible risk
- Retain promoted baseline files in a separate, read-only backup location after each `baseline-approval-template.md` sign-off, per the Threat 2 (Baseline Tampering) mitigation in `docs/threat-model.md`

---

## Who Should Have Access

| Role | Run Scripts Manually | Modify Configuration | Read Snapshot/Diff/Report Output | Modify Scripts |
|---|---|---|---|---|
| System Administrator (primary operator) | Yes | Yes | Yes | Yes, with change control |
| Junior Administrator (under supervision) | Yes, with guidance | No | Yes | No |
| Security / Audit Team | No (read-only review) | No | Yes | No |
| Scheduled Task / systemd Timer (automated execution) | N/A - runs as SYSTEM/root | N/A | N/A - writes only | N/A |
| General IT Staff (helpdesk, non-admin) | No | No | No | No |

This table reflects a least-privilege default. Smaller teams may need to collapse these roles, but the underlying principle - script modification rights are more restricted than script execution rights, which are more restricted than report read access - should be preserved regardless of team size.

---

## Hardening the Toolkit's Own Execution

### Windows

- The Scheduled Task created by `Register-SnapshotTask.ps1` runs as SYSTEM, not a named user account, eliminating the risk of credential exposure or account lockout affecting the schedule.
- Review the Scheduled Task definition periodically against `windows\scheduled-task\snapshot-task-definition.xml` to confirm no unauthorised modification has occurred, per `docs/threat-model.md` Threat 4 (Scheduler Compromise).
- Do not disable Windows Defender or any endpoint protection scanning of the scripts directory. These scripts perform read-only system enumeration and should not trigger false positives from standard antivirus behaviour; if they do, investigate the cause rather than excluding the directory from scanning.

### RHEL 9

- The systemd service runs as root with `NoNewPrivileges=true`, `PrivateTmp=true`, and `ProtectSystem=true` applied, per the hardening rationale documented directly in `linux/systemd/snapshot.service`.
- Periodically run `systemd-analyze security snapshot.service` to review the unit's security exposure score and confirm hardening directives remain in effect after any unit file edits:
  ```bash
  systemd-analyze security snapshot.service
  ```
- Do not add the scripts directory to any `auditd` or SELinux exclusion list. If SELinux denials occur during script execution, investigate the specific denial using `audit2why` rather than disabling enforcement.

---

## Credential and Secrets Handling

This toolkit does not require, store, or transmit any credentials. It does not connect to any remote service, API, or database. All data collection occurs through local OS commands executed in the security context of the account running the script (SYSTEM on Windows, root on Linux).

If an operator extends this toolkit to add new capture categories that do require credentials (for example, querying a database server's configuration), credentials must never be stored in plaintext within `snapshot-config.json` or `snapshot.conf`. Use the platform's credential management facilities instead:

- **Windows:** Windows Credential Manager, accessed via PowerShell's `Get-StoredCredential` (requires the CredentialManager module) or native `Get-Credential` prompts for interactive use cases.
- **Linux:** A dedicated secrets file with mode `600`, owned by root, referenced by path in configuration rather than embedding the secret directly - or integration with `systemd-creds` for systemd-managed secret injection.

---

## Snapshot Data Exposure Risk Summary

This section consolidates the data sensitivity classification from `docs/threat-model.md` into a direct operational reminder.

If a snapshot, diff, or report file is exposed to an unauthorised party, they gain:

- A complete inventory of local user accounts and their privilege levels
- A complete map of the server's network-facing attack surface (firewall rules and listening ports)
- A list of installed software and versions, useful for identifying known vulnerabilities
- Visibility into automated processes (scheduled tasks, cron jobs) and the accounts they run as
- On Linux: visibility into exactly which sudo rules and wheel group memberships exist, and which configuration files have been recently modified

This is the same category of information an attacker would otherwise need active reconnaissance to obtain. Treat every snapshot, diff, and report file with the same handling discipline you would apply to a penetration test finding report.

---

## Periodic Security Review Checklist

Perform the following review at least quarterly, or after any significant infrastructure change:

- [ ] Confirm snapshot, diff, and report output directories still have the permissions documented in this file
- [ ] Confirm no snapshot, diff, or report file has been accidentally committed to version control: `git log --all --full-history -- "*snapshot*.json" "*diff*.json" "*report*.json"`
- [ ] Confirm the scheduled task (Windows) or systemd timer (Linux) configuration matches the documented reference definition
- [ ] Confirm script file checksums or modification timestamps have not changed outside of an intentional, documented update
- [ ] Confirm the list of accounts with read access to output directories still matches the "Who Should Have Access" table above
- [ ] Run `systemd-analyze security snapshot.service` (Linux) and review for any unexpected change in the exposure score

---

