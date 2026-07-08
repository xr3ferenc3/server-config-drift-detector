# Threat Model

## Purpose of This Document

This document defines what the server-config-drift-detector toolkit protects against, what it explicitly does not protect against, what data it touches and how sensitive that data is, where that data is stored, and what an attacker or negligent insider could do with access to toolkit components or output files.

Every operator who deploys this toolkit should read this document before the first snapshot is taken.

---

## What Problem This Toolkit Addresses

Configuration drift is a security and operational risk. When servers change without documentation or detection, the following conditions become possible:

- Unauthorised user accounts persist undetected
- Firewall rules are weakened or bypassed without a change record
- Malicious or unauthorised scheduled tasks execute on a schedule
- Services are disabled, degraded, or replaced
- Software is installed outside of an approved process
- Configuration files controlling authentication and access are modified

None of these events are necessarily visible in normal operations. They may not cause immediate symptoms. They may not generate alerts. Without a baselining and comparison process, they may remain undetected indefinitely.

This toolkit provides detection capability for this category of change. It does not prevent changes. It does not respond to changes. It surfaces changes so that a human operator can decide what to do.

---

## Scope Boundaries

### In Scope

The following are within the detection scope of this toolkit:

- Changes to local user accounts (additions, removals, attribute modifications)
- Changes to service states and start types
- Changes to firewall rules
- Changes to scheduled tasks (Windows) and cron jobs (Linux)
- Changes to installed software and packages
- Changes to listening ports and their associated processes
- Changes to sudo access rules (Linux)
- Changes to SELinux enforcement mode (Linux)
- Changes to the content of key system configuration files, detected via checksum comparison
- Changes to Windows Update pending state

### Out of Scope

The following are explicitly outside the detection scope of this toolkit:

- Real-time monitoring of any kind
- Network traffic analysis
- Active Directory or LDAP changes
- Application-level configuration changes beyond key system files
- Database configuration or content changes
- Container or virtualisation layer changes
- Hardware configuration changes
- Firmware changes
- User activity or behaviour (what accounts do, not that they exist)
- File system changes outside of explicitly checksummed files
- Registry changes (Windows) beyond what is reflected in the captured categories

These exclusions are design decisions, not gaps. Covering them would require either enterprise tooling or a scope that cannot be supported on a low-end laptop with no external dependencies.

---

## Data Sensitivity Classification

Snapshot files contain sensitive operational data. The sensitivity of each captured category is classified below.

| Category | Sensitivity | Reason |
|---|---|---|
| Local user accounts | High | Reveals account names, enabled states, group memberships, last logon times. Useful to an attacker performing reconnaissance. |
| Sudo access rules | High | Reveals which accounts have elevated privileges and under what conditions. Directly useful for privilege escalation planning. |
| Firewall rules | High | Reveals which ports and protocols are permitted or blocked. Useful for identifying attack surface. |
| Listening ports and processes | High | Reveals which services are externally reachable and which processes own those connections. Useful for targeting attacks. |
| Installed software | Medium | Reveals software versions, which may expose known vulnerabilities. |
| Services | Medium | Reveals running and stopped services, which may indicate defensive tools that are disabled or missing. |
| Scheduled tasks and cron jobs | Medium | Reveals automated processes, run-as accounts, and execution schedules. |
| Config file checksums | Medium | Reveals that specific files were changed, but not their content. |
| SELinux status | Low-Medium | Reveals whether mandatory access controls are enforced. A disabled or permissive SELinux mode is operationally significant. |
| System metadata | Low | Hostname, OS version, uptime. Useful for correlation but not independently sensitive. |

**Conclusion:** Snapshot files must be treated as sensitive operational documents. They must not be stored in publicly accessible locations, committed to version control, or transmitted over unencrypted channels.

---

## Threat Scenarios

### Threat 1 - Snapshot File Exfiltration

**Scenario:** An attacker gains read access to the snapshot output directory, either through a compromised account, a misconfigured file permission, or physical access to the storage medium.

**Impact:** The attacker obtains a detailed inventory of the server's user accounts, open ports, services, firewall rules, and installed software without running a single reconnaissance command against the live system. The snapshot provides a quieter alternative to active scanning.

**Mitigations provided by this toolkit:**
- `.gitignore` prevents snapshot files from being committed to version control
- `docs/security-considerations.md` defines required file permissions for snapshot directories
- `snapshot.service` (Linux) restricts write paths to the defined output directory

**Mitigations the operator must implement:**
- Restrict the snapshot output directory to root or Administrator access only
- Do not store snapshots on shared network drives accessible to non-administrative accounts
- Do not email snapshot files to distribution lists or shared mailboxes
- Encrypt snapshot storage if the server is in a shared physical environment

---

### Threat 2 - Baseline Tampering

**Scenario:** An attacker with write access to the snapshot directory replaces or modifies the baseline snapshot file. A subsequent comparison against the tampered baseline shows no drift, concealing unauthorised changes made to the live server.

**Impact:** The drift detection capability is silently defeated. Changes that should trigger investigation are suppressed.

**Mitigations provided by this toolkit:**
- Baseline snapshots are named with a `baseline` label and a timestamp, making replacement detectable if the file modification date is monitored
- The `templates/baseline-approval-template.md` records the expected baseline filename and timestamp at approval time, providing a reference for verification

**Mitigations the operator must implement:**
- Restrict write access to the snapshot directory to the account that runs the snapshot script only
- Store a copy of the approved baseline in a separate, read-only location after the baseline approval process
- Record the baseline file's SHA-256 checksum in the `baseline-approval-template.md` document at approval time
- Periodically verify the baseline file's checksum against the recorded value

---

### Threat 3 - Script Modification

**Scenario:** An attacker with write access to the toolkit's script directory modifies a snapshot or comparison script to suppress specific categories, exclude specific accounts, or alter severity thresholds - causing the toolkit to produce reports that omit attacker-controlled changes.

**Impact:** The toolkit continues to run on schedule and produce reports, but those reports are selectively incomplete. The attacker's presence is not reported.

**Mitigations provided by this toolkit:**
- Scripts are stored in a separate directory from snapshot output, allowing different permission sets
- Script files are tracked in version control, making modifications detectable via `git diff` or `git status`

**Mitigations the operator must implement:**
- Restrict write access to the scripts directory to administrators only
- Periodically run `git diff` against the repository to verify no script files have been modified
- Store a known-good copy of all scripts in a read-only location separate from the server being monitored
- Consider monitoring the scripts directory for file modification events using the OS audit subsystem

---

### Threat 4 - Scheduler Compromise

**Scenario:** An attacker modifies the Windows Scheduled Task or Linux systemd timer to prevent snapshot execution, change the execution account, or redirect output to a location the attacker controls.

**Impact:** Snapshots stop being taken, or are taken and stored in a location the attacker can manipulate, without the operator noticing until the next manual review.

**Mitigations provided by this toolkit:**
- `snapshot-task-definition.xml` provides a reference definition of the correct task configuration for comparison
- `snapshot.service` and `snapshot.timer` are tracked in version control for the same purpose

**Mitigations the operator must implement:**
- Verify the scheduled task or systemd timer configuration during the weekly review using the reference definition
- Monitor for the absence of expected snapshot files - a missing snapshot is itself a drift event
- Include scheduled task and timer configuration in the scope of access control reviews

---

### Threat 5 - Report Injection

**Scenario:** An attacker with write access to the diff output directory modifies a diff JSON file before the report script processes it, injecting false drift findings or removing real ones.

**Impact:** The generated report is inaccurate. False positives waste operator time on investigation. False negatives conceal real changes.

**Mitigations provided by this toolkit:**
- The report script validates the diff file schema before processing
- Diff files include a generation timestamp and script version in their metadata block

**Mitigations the operator must implement:**
- Run the comparison and report scripts in sequence in a single session where operationally possible, minimising the window during which a diff file sits unprocessed
- Restrict write access to the diff output directory to the same account that runs the scripts

---

### Threat 6 - Privileged Execution Abuse

**Scenario:** The snapshot scripts run as SYSTEM (Windows) or root (Linux). If the scripts are replaced with malicious versions, the attacker gains code execution at the highest privilege level on the system.

**Impact:** Full system compromise from the scheduler's execution context.

**Mitigations provided by this toolkit:**
- `snapshot.service` applies `NoNewPrivileges=true` and `PrivateTmp=true` to limit the blast radius of script-level compromise
- Scripts are stored with restrictive permissions as defined in `docs/security-considerations.md`

**Mitigations the operator must implement:**
- Restrict write access to all script files to administrators only
- Do not allow non-administrative accounts to modify the snapshot output directory, as this is the path written by the privileged process
- Review script content after any git pull or manual update before running

---

## What This Toolkit Does Not Protect Against

The following threats are outside the scope of this toolkit. Operators should be aware of them and address them through other means.

| Threat | Reason It Is Out of Scope |
|---|---|
| Attacks that occur and are fully reversed before the next snapshot | The toolkit only detects persistent state changes. Transient changes leave no trace in a periodic snapshot. |
| Attacks on the system running the toolkit itself | A compromised host cannot reliably audit itself. The toolkit assumes the host is not actively compromised at snapshot time. |
| Attacks against the accounts authorised to run the toolkit | Privileged account security is an access control and authentication problem, not a drift detection problem. |
| Insider threats with administrative access | An administrator with write access to both the live system and the snapshot directory can defeat this toolkit. Detection requires a control plane the insider cannot reach. |
| Zero-day exploitation with no persistent configuration change | If an attacker operates entirely in memory and makes no configuration changes, no snapshot-based tool will detect them. |

These are honest limitations. No single tool addresses all threats. This toolkit addresses one specific and operationally valuable threat: silent, persistent configuration change.

---

## Risk Acceptance Statement

Deploying this toolkit does not constitute a complete security posture. It provides one layer of detective control in the category of configuration integrity monitoring. It should be used alongside:

- Access control reviews
- Authentication logging
- Network monitoring
- Patch management
- Security awareness

Operators who treat drift detection as their only security control have misunderstood both the toolkit and the threat landscape.

---

## Revision History

| Version | Date | Change |
|---|---|---|
| 1.0 | 2025-10-01 | Initial release |

---