# Snapshot Methodology

## Purpose of This Document

This document explains precisely what data each snapshot captures, why each category was chosen, how each data point is collected, and what has been deliberately excluded and why.

A snapshot is only useful if the operator understands what it contains and what it does not contain. This document provides that understanding. It also serves as the authoritative reference when extending the toolkit with new capture categories.

---

## Design Principles

Every capture category in this toolkit was evaluated against four questions before inclusion:

**1. Does it change in ways that matter operationally?**
A data point that never changes, or that changes in ways that have no operational significance, adds noise to drift reports without adding value. It was excluded.

**2. Can it be collected reliably using only built-in OS tools?**
Any category requiring an external tool, a licensed product, or a dependency not present on a standard OS installation was excluded. The toolkit must work on a minimal installation.

**3. Is the output structured enough to support automated comparison?**
Categories whose output is inherently unstructured or variable in format - producing false positives in comparison - were either excluded or scoped to the subset of their output that is stable and comparable.

**4. Does a change in this category represent a real operational concern?**
If a change in this category would not cause an operator to investigate, the category was excluded. Every item in a drift report must be worth reading.

---

## Windows Server 2022 - Capture Categories

---

### Category 1 - Installed Software

**What is captured:**
- Display name
- Version number
- Publisher
- Install date

**Collection method:**
Win32_Product WMI class queried via PowerShell (`Get-WmiObject -Class Win32_Product`). Supplemented with registry enumeration from `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall` and the 32-bit equivalent path to capture software not registered with WMI.

**Why this matters operationally:**
Unauthorised software installation is a common vector for policy violation, shadow IT, and malware persistence. Software removals may indicate failed updates, tampering, or deliberate removal of security tools. Version changes confirm whether a patch was successfully applied.

**Why version is captured but not install path:**
Install paths are frequently environment-specific and change legitimately across reinstallations of the same software version. Including paths would generate false positives without adding detection value.

**Known limitations:**
Win32_Product is known to trigger Windows Installer repair processes on some systems when queried. This behaviour is documented in Microsoft knowledge base articles and is a known side effect of this query method. The registry enumeration path is used as the primary source for this reason, with WMI as supplementary. Operators on systems where this behaviour is observed should disable the WMI query path in the configuration file.

*This limitation is acknowledged in Microsoft documentation and in Mastering Windows Server 2022 Chapter discussions of WMI querying behaviour. The registry path approach is the modern recommended alternative.*

---

### Category 2 - Services

**What is captured:**
- Service name (short name)
- Display name
- Current status (Running, Stopped, Paused)
- Start type (Automatic, Manual, Disabled, Automatic (Delayed Start))

**Collection method:**
`Get-Service` cmdlet combined with `Get-WmiObject Win32_Service` for start type, which `Get-Service` alone does not expose in PowerShell 5.1.

**Why this matters operationally:**
Service state changes are among the most operationally significant drift events. A security tool being stopped, a critical service being disabled, or an unexpected service appearing are all high-value findings. Start type changes reveal whether a service has been reconfigured to not start after reboot - a common persistence or sabotage technique.

**Why process ID and memory usage are excluded:**
Process IDs change every time a service restarts. Memory usage fluctuates continuously. Including either would generate false positives on every comparison run with no detection value.

**Why service account (Log On As) is excluded:**
Service account changes are operationally significant, but the Log On As field is not consistently accessible via `Get-Service` in PowerShell 5.1 without WMI queries that significantly increase script runtime on systems with many services. This is a noted limitation. Operators who require service account monitoring should add this via the WMI path and document the performance impact.

---

### Category 3 - Local User Accounts

**What is captured:**
- Username
- Enabled status (true/false)
- Last logon date
- Password last set date
- Group memberships (local groups only)
- Account description

**Collection method:**
`Get-LocalUser` and `Get-LocalGroupMember` cmdlets. Available in PowerShell 5.1 and later on Windows Server 2022.

**Why this matters operationally:**
Unauthorised local user accounts are a critical finding. An account appearing with no corresponding change ticket is a security event until proven otherwise. Account enablement changes (a disabled account becoming enabled) are equally significant. Group membership changes - particularly addition to the Administrators group - represent a privilege escalation event.

**Why password hash is excluded:**
Password hashes are not accessible to PowerShell without invoking the SAM database directly, which requires techniques that are themselves security-concerning and outside the scope of a legitimate monitoring tool. The password last set date provides change detection without requiring hash access.

**Why last logon date is captured but not compared for drift:**
Last logon dates change every time an account authenticates. Comparing them would generate a change event for every account that has logged in since the baseline. Last logon is captured for informational context in the report but is excluded from drift comparison logic.

---

### Category 4 - Firewall Rules

**What is captured:**
- Rule name
- Enabled status (true/false)
- Direction (Inbound/Outbound)
- Action (Allow/Block)
- Profile (Domain/Private/Public/Any)
- Protocol
- Local port
- Remote address

**Collection method:**
`Get-NetFirewallRule` combined with `Get-NetFirewallPortFilter` and `Get-NetFirewallAddressFilter` to resolve port and address details, which are stored as separate objects in the Windows Firewall object model.

**Why this matters operationally:**
Firewall rule changes directly affect the server's attack surface. A rule being disabled, an allow rule being added for a previously blocked port, or a rule scope being widened (from specific remote addresses to Any) are all significant findings. These changes may indicate misconfiguration, deliberate bypass, or compromise.

**Why all rules are captured rather than only enabled rules:**
A rule being disabled is itself a drift event. Capturing only enabled rules would miss the case where a blocking rule is disabled to permit previously blocked traffic.

**Why built-in default rules are included:**
Default rules can be modified or disabled. Excluding them from capture would miss modifications to the baseline Windows Firewall posture.

---

### Category 5 - Scheduled Tasks

**What is captured:**
- Task name
- Task path (folder)
- State (Ready, Running, Disabled)
- Last run time
- Next run time
- Run-as account (Principal)
- Action (executable and arguments)
- Trigger summary

**Collection method:**
`Get-ScheduledTask` cmdlet with `Get-ScheduledTaskInfo` for runtime details.

**Why this matters operationally:**
Scheduled tasks are a primary persistence mechanism for malware and unauthorised automation. A new task appearing, a task's run-as account changing, or a task's action (the executable it runs) being modified are all critical findings. Legitimate scheduled tasks should be documented and expected. Unexpected tasks should always be investigated.

**Why task history (individual run records) is excluded:**
Task execution history changes continuously and would generate excessive false positives. The last run time and next run time provide sufficient context without producing noise.

**Why trigger details are summarised rather than fully serialised:**
Trigger objects in PowerShell are complex nested structures with many fields that change legitimately (next activation time, etc.). A summary of trigger type and schedule provides change detection without false positives from time-based field updates.

---

### Category 6 - Listening Ports

**What is captured:**
- Protocol (TCP/UDP)
- Local address
- Local port
- State (for TCP: Listen, Established, etc.)
- Owning process ID
- Owning process name

**Collection method:**
`Get-NetTCPConnection` and `Get-NetUDPEndpoint` with process resolution via `Get-Process`.

**Why this matters operationally:**
A new listening port represents a new network-accessible service. This may be legitimate (a newly installed application) or concerning (a backdoor, a misconfigured service, or an attacker's listener). Correlating the port with the owning process name adds immediate context to the finding.

**Why established connections are excluded:**
Established connections are transient and change continuously. Only listening state entries represent persistent configuration.

**Why remote address is excluded for listening ports:**
A listening port has no remote address by definition. Remote address is relevant only to established connections, which are excluded.

---

### Category 7 - Pending Windows Updates

**What is captured:**
- Update title
- KB article number
- Severity classification (Critical, Important, Moderate, Low)
- Update category (Security, Definition, Feature, etc.)

**Collection method:**
Windows Update Agent COM interface via PowerShell (`New-Object -ComObject Microsoft.Update.Session`). This approach uses only built-in Windows components without requiring the PSWindowsUpdate module or any external dependency.

**Why this matters operationally:**
A server that accumulates pending critical security updates without applying them represents a growing vulnerability exposure. Tracking pending updates in the snapshot captures the patch posture at each point in time, allowing drift reports to show whether the patch backlog is growing or shrinking and whether critical updates are being applied promptly.

**Why update history is excluded:**
Applied update history is accessible but voluminous and changes in one direction only (entries are added, never removed). Capturing it would bloat snapshot files significantly. The currently pending update list is the operationally relevant data point.

---

### Category 8 - System Metadata

**What is captured:**
- Hostname
- OS version and build number
- OS install date
- Last boot time
- PowerShell version
- Script version that generated the snapshot
- Snapshot label
- Snapshot timestamp (UTC)
- Capturing account

**Why this matters operationally:**
Metadata ties the snapshot to a specific system state in time. The last boot time confirms whether the server has been rebooted since the baseline (expected after patching, unexpected otherwise). OS build number changes confirm whether a feature update has been applied. The capturing account provides an audit trail for who or what ran the snapshot.

---

## RHEL 9 - Capture Categories

---

### Category 1 - Installed Packages

**What is captured:**
- Package name
- Version
- Release
- Architecture
- Install date

**Collection method:**
`rpm -qa --queryformat` with explicit format string to produce consistent, parseable output. This is the canonical package query tool on RHEL 9 and is available on all installations.

**Why this matters operationally:**
Unauthorised package installation may indicate software installed outside of change management, a compromised package manager, or dependency changes from a legitimate install that brought in unexpected packages. Package removals may indicate tampering with security tools or system utilities. Version changes confirm patch application.

**Why dnf history is excluded:**
dnf transaction history provides a chronological record of package operations, which is useful for understanding how a package state was reached. However, it is voluminous, time-indexed rather than state-indexed, and does not represent current state. The rpm query represents current installed state, which is what snapshot comparison requires.

*RHCSA Red Hat Enterprise Linux 9 Certification Study Guide Chapter 3 covers rpm and dnf package management in detail. The rpm -qa approach is the standard method for producing an auditable package inventory.*

---

### Category 2 - Services

**What is captured:**
- Unit name
- Load state (loaded, not-found, masked)
- Active state (active, inactive, failed, activating, deactivating)
- Sub-state (running, exited, dead, waiting, etc.)
- Unit file state (enabled, disabled, static, masked)

**Collection method:**
`systemctl list-units --type=service --all --no-pager --no-legend` for runtime state, combined with `systemctl list-unit-files --type=service --no-pager --no-legend` for unit file (boot) state.

**Why both runtime state and unit file state are captured:**
A service can be running now but set to not start at boot (unit file disabled). A service can be stopped now but set to start at boot (unit file enabled). Both dimensions of state are operationally relevant. Runtime state alone misses boot configuration changes. Unit file state alone misses current operational state.

**Why systemd is used exclusively rather than checking /etc/init.d/:**
RHEL 9 uses systemd as the exclusive init system. SysV init scripts in /etc/init.d/ are a compatibility layer only. Monitoring systemd units covers all services on a standard RHEL 9 installation.

*RHCSA Red Hat Enterprise Linux 9 Certification Study Guide Chapter 12 covers systemd service management in detail.*

---

### Category 3 - Local User Accounts

**What is captured:**
- Username
- UID
- GID
- Home directory
- Login shell
- GECOS field (description)
- Account lock status (from /etc/shadow)
- Password expiry information

**Collection method:**
Parsed from `/etc/passwd` for account details, `/etc/shadow` for lock status and expiry (requires root access). `getent passwd` is used as the primary source to ensure consistent output format regardless of nsswitch configuration.

**Why shadow file parsing requires root:**
The `/etc/shadow` file is readable only by root. Running the snapshot script without root privileges would exclude lock status and expiry data, reducing detection value. The operational guide requires root execution for this reason.

**Why /etc/group membership is captured separately:**
Primary group is captured from `/etc/passwd` (GID field). Supplementary group memberships - particularly membership in the wheel group - are captured from `/etc/group` parsing as part of the sudo access category, where the operational significance is highest.

*RHCSA Red Hat Enterprise Linux 9 Certification Study Guide Chapter 4 covers local user and group management including /etc/passwd and /etc/shadow structure.*

---

### Category 4 - Sudo Access

**What is captured:**
- User-level sudo rules from `/etc/sudoers`
- Group-level sudo rules from `/etc/sudoers`
- All rule files under `/etc/sudoers.d/`
- Wheel group membership (which grants sudo by default on RHEL 9)

**Collection method:**
`/etc/sudoers` is parsed directly. `/etc/sudoers.d/` contents are enumerated and parsed. `/etc/group` is parsed for wheel group members. The `visudo -c -f` check is run to confirm sudoers file validity before parsing.

**Why this is a separate category rather than part of user accounts:**
Sudo access is the primary privilege escalation mechanism on Linux systems. A user account addition is notable. A sudo rule granting that account unrestricted root access is critical. Separating the two categories allows different severity thresholds to be applied and ensures sudo changes are always visible in the report summary regardless of the number of other changes.

**Why sudoers content is captured as structured rules rather than raw file content:**
Raw file capture would trigger a change event for any comment or whitespace modification, producing false positives. Structured rule extraction captures only the operative access grants.

*RHCSA Red Hat Enterprise Linux 9 Certification Study Guide Chapter 5 covers sudo configuration in detail.*

---

### Category 5 - Firewall Rules

**What is captured:**
- Active zone names
- Default zone
- Per-zone: services permitted
- Per-zone: ports permitted
- Per-zone: rich rules
- Per-zone: interfaces assigned
- Per-zone: sources assigned

**Collection method:**
`firewall-cmd --list-all-zones` with structured parsing. Requires firewalld to be running. If firewalld is not running, the snapshot records this state explicitly rather than producing an empty firewall section.

**Why iptables rules are not captured:**
RHEL 9 uses firewalld as its default firewall management layer. firewalld manages the underlying nftables (RHEL 9) rules. Direct nftables or iptables rule enumeration would duplicate what firewalld exposes and would be fragile against firewalld zone changes. firewalld is the correct interface for RHEL 9 firewall state.

*RHCSA Red Hat Enterprise Linux 9 Certification Study Guide Chapter 19 covers firewalld configuration.*

*Note: RHEL 8 used iptables as the backend for firewalld. RHEL 9 transitioned to nftables as the backend. This is transparent to firewall-cmd commands used in this toolkit, making the approach forward-compatible.*

---

### Category 6 - Listening Ports

**What is captured:**
- Protocol (TCP/UDP)
- Local address
- Local port
- Process name
- Process ID

**Collection method:**
`ss -tlnup` (TCP listening) and `ss -ulnup` (UDP listening) with process information. `ss` is the modern replacement for `netstat` on RHEL 9. `netstat` is provided by the net-tools package, which is not installed by default on RHEL 9 minimal installations.

*Note: Mastering Windows Server 2022 and the RHCSA study guide both reference netstat in their diagnostic sections. On RHEL 9, netstat is deprecated and may not be present. ss is the correct tool and provides equivalent information with a different syntax. This toolkit uses ss exclusively.*

**Why this matters operationally:**
Identical reasoning to the Windows category. New listening ports represent new network-accessible services that require explanation.

---

### Category 7 - Cron Jobs

**What is captured:**
- System crontab entries (`/etc/crontab`)
- Entries in `/etc/cron.d/`
- Entries in `/etc/cron.hourly/`, `/etc/cron.daily/`, `/etc/cron.weekly/`, `/etc/cron.monthly/`
- Per-user crontabs from `/var/spool/cron/` (root crontab and any user crontabs)

**Collection method:**
Direct file reading with structured parsing. Root access required for `/var/spool/cron/`.

**Why systemd timers are not captured in this category:**
Systemd timers are captured as part of the Services category (they are systemd units and appear in `systemctl list-unit-files`). Cron jobs and systemd timers represent two parallel scheduling mechanisms on RHEL 9. Both are captured, in their respective categories.

**Why this matters operationally:**
Cron jobs are a persistence mechanism used by both legitimate automation and malware. An unexpected cron entry executing an unknown script as root is a critical finding.

---

### Category 8 - SELinux Status

**What is captured:**
- Current enforcement mode (Enforcing/Permissive/Disabled)
- Policy name (targeted/mls/minimum)
- Policy version

**Collection method:**
`getenforce` for current mode. `sestatus` for full status including policy details.

**Why this matters operationally:**
SELinux in Enforcing mode provides mandatory access controls that significantly restrict what compromised processes can do. A change from Enforcing to Permissive mode represents a deliberate weakening of the server's security posture. This is a critical drift event.

**Why SELinux boolean states are excluded:**
There are typically over 300 SELinux booleans on a standard RHEL 9 installation. Capturing all of them would produce large snapshots with high false positive rates from legitimate application configuration changes. Operators who require boolean monitoring should add specific boolean names to the configuration file for targeted capture.

*RHCSA Red Hat Enterprise Linux 9 Certification Study Guide Chapter 20 covers SELinux configuration and enforcement modes in detail.*

---

### Category 9 - Configuration File Checksums

**What is captured:**
SHA-256 checksums of the following files:

| File | Reason |
|---|---|
| `/etc/ssh/sshd_config` | Controls SSH daemon behaviour, authentication methods, and access restrictions |
| `/etc/sudoers` | Primary sudo access control file |
| `/etc/passwd` | Local user account definitions |
| `/etc/shadow` | Password hashes and account expiry (metadata only - not the file contents) |
| `/etc/group` | Local group definitions and memberships |
| `/etc/hosts` | Local DNS resolution overrides |
| `/etc/resolv.conf` | DNS resolver configuration |
| `/etc/chrony.conf` | NTP time synchronisation configuration |
| `/etc/login.defs` | System-wide login and password policy defaults |
| `/etc/pam.d/sshd` | PAM configuration for SSH authentication |
| `/etc/pam.d/sudo` | PAM configuration for sudo authentication |

**Collection method:**
`sha256sum` for each file. If a file does not exist, this is recorded explicitly in the snapshot rather than silently skipping it.

**Why checksums rather than file content:**
Capturing file content in the snapshot would produce large files and expose sensitive data (particularly from `/etc/shadow` and `/etc/sudoers`). A checksum change confirms that the file was modified without revealing what changed. When a checksum change is detected, the operator investigates the file directly on the live system.

**Why these specific files:**
These files collectively control authentication, authorisation, name resolution, time synchronisation, and password policy - the core security-relevant configuration of a RHEL 9 server. Changes to any of them are operationally significant.

---

### Category 10 - System Metadata

**What is captured:**
- Hostname (`hostname -f`)
- Kernel version (`uname -r`)
- OS release (`/etc/os-release`)
- System uptime
- Shell version (Bash)
- Script version that generated the snapshot
- Snapshot label
- Snapshot timestamp (UTC, via `date -u`)
- Capturing account (`whoami`)
- Python 3 version (dependency confirmation)

**Why Python version is captured:**
The comparison script depends on Python 3. Capturing its version in the snapshot confirms the dependency was present at snapshot time and provides a reference if comparison failures occur due to Python version differences.

---

## Explicitly Excluded Categories

The following categories were evaluated and deliberately excluded.

| Category | Reason for Exclusion |
|---|---|
| Windows Registry | Too voluminous for full capture; high false positive rate from legitimate application updates; no reliable scoping without enterprise knowledge of the environment |
| Active Directory / LDAP | Out of scope - this toolkit targets standalone and workgroup servers |
| Application configuration files (beyond key system files) | Environment-specific; no universal path set; operators should add application-specific checksums to the configuration file for their environment |
| Database content or configuration | Requires database credentials and client tools; out of scope |
| File system inventory (beyond checksummed files) | A full file system inventory is a forensic capability, not a drift detection capability; the scope and runtime would be unacceptable |
| Network interface configuration | Changes at this level require OS-level intervention and are already visible through listening port changes; the additional capture category adds little detection value |
| DNS zone data | Requires DNS server role; out of scope for a general-purpose server toolkit |
| Event logs / journal entries | Forensic and diagnostic tool, not configuration state; covered by the existing it-support-ops-centre repository |

---

## Adding New Capture Categories

Operators who wish to extend the snapshot scope should follow this process:

1. Evaluate the candidate category against the four design principle questions at the top of this document
2. Confirm the data can be collected using only tools present on a standard OS installation
3. Define the structured output format - what fields will be captured and in what data types
4. Implement the capture in the snapshot script
5. Implement comparison logic in the comparison script, handling added, removed, and modified cases
6. Implement report rendering in the report script
7. Assign a default severity threshold in the configuration file
8. Document the new category in this file following the same format
9. Update the snapshot JSON schema version in metadata if new top-level fields are added
10. Test comparison across a pre-extension baseline and a post-extension snapshot to confirm graceful handling of missing categories

---