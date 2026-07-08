

# Drift Interpretation Guide

## Purpose of This Document

A drift report tells an operator what changed. It does not tell them what to do about it. This document provides the decision framework for converting a drift finding into an operational action: investigate, approve, remediate, or escalate.

This is the document an operator should have open while reviewing a drift report, whether during the weekly review process or in response to an incident.

---

## Reading a Drift Report

Every drift report follows the same structure, on both platforms:

1. **Metadata block** — hostname, baseline and comparison snapshot identifiers, timestamps, and overall severity
2. **Summary table** — every monitored category, its change count, and its highest severity
3. **Detail sections** — the specific findings within each category that had changes
4. **Operational notes** — a reminder of the workflow to follow

Start with the Summary table. It gives you the shape of the drift before you read a single detail line. A report with one INFORMATIONAL finding in Installed Software and nothing else requires a different response than a report with a CRITICAL finding in Local Users.

---

## The Severity Model

| Severity | What It Means | Required Response |
|---|---|---|
| **NONE** | No changes detected in this category | No action |
| **INFORMATIONAL** | A change occurred with low operational significance on its own | Note and move on; no investigation required unless part of a pattern |
| **NOTABLE** | A change occurred that warrants human review before being dismissed | Investigate before closing the report |
| **CRITICAL** | A change occurred in a security-relevant or high-impact category | Investigate immediately; do not close the report until resolved |

Severity is assigned automatically by the report script based on the thresholds in the configuration file. The classification reflects the *category and type of change*, not the specific intent behind it. A CRITICAL finding is not necessarily a security incident — it is a finding that the toolkit's design treats as significant enough that a human must look at it before dismissing it. Most CRITICAL findings will turn out to be legitimate, approved changes. The classification exists so that legitimate changes are never silently mistaken for noise.

---

## The Decision Framework

For every finding in a drift report, work through these four questions in order.

### Question 1 — Is this change documented?

Check the change against your organisation's change record (ticket system, change calendar, maintenance log). If the change corresponds to a known, approved, documented change:

→ **Mark as expected. No further investigation required.** Note it in your weekly review record for traceability, but do not treat it as an open finding.

If there is no corresponding documentation:

→ **Proceed to Question 2.**

### Question 2 — Can the change be explained by routine operation?

Some categories of change are expected to occur without an individual change ticket for every instance — for example, a minor software version update applied through an approved automatic update mechanism, or pending update counts changing as new updates are released upstream. Confirm whether this finding falls into a category your organisation has pre-approved as routine.

If yes:

→ **Mark as expected routine drift.** Document this determination in your weekly review notes.

If no:

→ **Proceed to Question 3.**

### Question 3 — Was this change made by someone with legitimate access, for a legitimate purpose, who simply did not log it?

This requires direct follow-up — typically a conversation with the team or individual most likely to have made the change. Common legitimate-but-undocumented causes include: an emergency fix made outside the normal change window, a vendor or contractor making an approved change without using your ticketing system, or a colleague testing something on a server they believed was non-production.

If confirmed as legitimate but undocumented:

→ **Retroactively document the change** (file a ticket describing what happened, even after the fact). **Then mark as resolved.** Consider whether your change management process needs reinforcement if this is a recurring pattern.

If you cannot identify a legitimate explanation, or the explanation does not hold up to scrutiny:

→ **Proceed to Question 4.**

### Question 4 — Treat this as a potential security event.

At this point, the finding has no documentation, does not match routine operation, and has no confirmed legitimate explanation.

→ **Escalate immediately following your organisation's incident response process.** Do not wait for the next scheduled review. Refer to `incident response procedures` in your organisation (this toolkit does not define incident response itself — see the Operational Boundaries section of the main README).

→ Preserve the relevant snapshot files, diff file, and drift report unmodified as part of the investigation record.

→ Do not promote this snapshot to a new baseline under any circumstances until the investigation concludes.

---

## Category-Specific Guidance

While the four-question framework applies universally, some categories carry specific patterns worth knowing in advance.

### Local Users / Wheel Group / Sudo Access

These are the highest-value findings in the entire report. A new local user account, a new sudo grant, or a wheel group addition with no corresponding documentation should be treated with urgency even before working through the full framework — verify the account is not actively being used for anything while you investigate.

Common legitimate causes: a new service account created for an application, a contractor account created for a defined engagement, an administrator adding themselves or a colleague to a group during a documented onboarding.

Common concerning causes: lateral movement following a compromised credential, a forgotten test account never cleaned up, a misconfigured automation tool creating accounts unexpectedly.

### Firewall Rules

A removed or disabled blocking rule is more concerning than an added permissive rule, because it represents an existing protection being withdrawn rather than a new exposure being deliberately opened. Pay particular attention to rules that widen scope — for example, a rule changing from a specific remote address to "Any".

Common legitimate causes: an approved network change, decommissioning of a service that no longer needs a corresponding rule, a security team tightening or adjusting policy.

Common concerning causes: an attacker opening a port for command-and-control or exfiltration, a rule disabled to facilitate unauthorised remote access, accidental misconfiguration during unrelated work.

### Services

A security-relevant service (antivirus, EDR agent, audit daemon, firewall service itself) stopping or being set to a non-automatic start type is one of the most common indicators of tampering, whether malicious or accidental. Cross-reference any stopped security service against your monitoring/EDR console if available — if that platform shows the same service offline, this drift finding corroborates an issue your monitoring may have already flagged.

Common legitimate causes: planned maintenance, a service being intentionally replaced or decommissioned, a patch requiring a service restart that is mid-cycle at snapshot time.

Common concerning causes: malware disabling defensive tooling, a failed update leaving a service in an unexpected state, unauthorised software disabling a competing service.

### Scheduled Tasks / Cron Jobs

New scheduled tasks or cron jobs running as a privileged account (SYSTEM, root) executing an unfamiliar script or binary are a classic persistence mechanism. Always resolve the full path of the executed binary or script and confirm it is something your team recognises before dismissing this finding.

Common legitimate causes: a new backup job, a new monitoring agent's scheduled check-in, an approved automation script.

Common concerning causes: malware persistence, an unauthorised automation tool installed without review, a forgotten one-off task that was never removed.

### Listening Ports

A new listening port is most useful when read together with its owning process name. If the process name is recognisable and expected (e.g. a newly installed, approved application), this is usually low-friction to resolve. If the process name is unfamiliar, unusual, or the port is a well-known port associated with remote access tools, treat with elevated caution.

Common legitimate causes: a newly installed and approved application or service, a development tool temporarily running during authorised testing.

Common concerning causes: a backdoor or remote access tool, a misconfigured service exposing an interface that should be local-only.

### Configuration File Checksums (Linux)

A checksum-only change tells you a file was modified but not what changed. The next step is always to inspect the live file directly on the server and compare it conceptually against the last known-good configuration (or, ideally, against a backed-up copy of the file from before the change).

Particular attention to `/etc/sudoers`, `/etc/pam.d/sshd`, and `/etc/pam.d/sudo` — these three files control authentication and privilege escalation directly, and an unauthorised change to any of them is high severity by definition.

### SELinux Status (Linux)

Any change away from `Enforcing` mode is a deliberate weakening of the server's security posture and should always be escalated unless there is a clear, documented, time-bound reason (e.g. active troubleshooting with a defined rollback plan).

### Installed Software / Packages

The lowest-friction category in most environments. Version bumps from approved patching processes are expected and routine. Pay closer attention to *new software appearing* (not just version changes to existing software) — particularly software your team does not recognise.

---

## Pattern Recognition Across Reports

A single report tells you what changed since the last comparison. Reviewing multiple reports over time reveals patterns that a single report cannot show:

- The same category showing repeated, undocumented drift week after week suggests a process gap, not isolated incidents — investigate the root cause of why changes are not being documented, not just each individual finding.
- A cluster of unrelated CRITICAL findings appearing in the same report is more concerning than the same findings spread across separate reports — simultaneous changes across multiple security-relevant categories is a stronger signal of compromise than isolated changes.
- A server that consistently shows zero drift over many review cycles is a useful confirmation that your change management process is being followed for that system — note this as a positive operational signal, not just an absence of findings.

---

## When to Promote a Baseline

A baseline should only be promoted (see `docs/operational-guide.md` Section 8) when:

- Every finding in the current drift report has been resolved through the four-question framework above
- No finding remains in an "investigating" or "escalated" state
- The `templates/baseline-approval-template.md` has been completed and signed off

Never promote a baseline simply to "clear" a report you have not fully investigated. Doing so silently erases the record of an unresolved finding from future comparisons.

---

## Quick Reference Summary
```text
┌───────────────────────────────────────────────┐
│            FINDING REVIEW PROCESS             │
└───────────────────────────────────────────────┘

        ┌───────────────────────────┐
        │ 1. Documented change?     │
        └──────────┬────────────────┘
                   │
         YES ──────┴──────► Expected ✓
                   │
                  NO
                   ▼
        ┌───────────────────────────┐
        │ 2. Routine operation?     │
        └──────────┬────────────────┘
                   │
         YES ──────┴──────► Routine ✓
                   │
                  NO
                   ▼
        ┌───────────────────────────┐
        │ 3. Legitimate but         │
        │    unlogged?              │
        └──────────┬────────────────┘
                   │
         YES ──────┴──────► Document & Resolve
                   │
                  NO
                   ▼
        ┌───────────────────────────┐
        │ 4. ESCALATE               │
        ├───────────────────────────┤
        │ • Preserve evidence       │
        │ • Do not promote baseline │
        └───────────────────────────┘
```
---
