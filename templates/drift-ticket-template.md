# Drift Finding - Ticket Template

## Purpose

This template is used to open a formal follow-up ticket when a drift report produces a finding that requires tracked investigation, remediation, or retroactive documentation. Copy this template into your ticketing system (Jira, ServiceNow, Zendesk, a shared document, or any equivalent) and complete every field.

A ticket opened from this template serves three operational purposes: it ensures the finding is tracked to resolution rather than noted and forgotten, it creates an auditable record connecting a drift report finding to a specific outcome, and it provides context for future operators who encounter the same finding in a subsequent drift review.

Not every drift finding requires a ticket. Refer to the outcome codes in `checklists/drift-response-checklist.md`:
- **E (Expected):** No ticket required - the change is already documented.
- **R (Routine):** No ticket required - the change matches a pre-approved routine operation.
- **D (Retroactively Documented):** Open a ticket to create the missing change record.
- **X (Escalated):** Open a ticket immediately and initiate your organisation's incident response process.

---

## Ticket Header

| Field | Value |
|---|---|
| **Ticket Title** | Drift Finding - [HOSTNAME] - [CATEGORY] - [CHANGE TYPE] - [DATE] |
| **Priority** | Critical / High / Medium / Low (map from finding severity: CRITICAL→Critical, NOTABLE→High, INFORMATIONAL→Low) |
| **Assigned To** | |
| **Reported By** | |
| **Date Opened** | |
| **Target Resolution Date** | |
| **Related Drift Report** | [filename of the .md or .json report that surfaced this finding] |
| **Related Baseline Approval** | [filename of the baseline-approval-template.md this drift is measured against] |

---

## Section 1 - Finding Summary

### 1.1 - What Changed

*Describe the specific change detected in the drift report. Be precise - use the exact field values shown in the report rather than paraphrasing.*

| Field | Value |
|---|---|
| Server hostname | |
| Platform | Windows Server 2022 / RHEL 9 |
| Category | (e.g. Local Users, Services, Firewall Rules) |
| Change type | Added / Removed / Modified |
| Severity classification | CRITICAL / NOTABLE / INFORMATIONAL |
| Specific change detail | (copy the relevant finding line from the drift report exactly) |

### 1.2 - When It Was Detected

| Field | Value |
|---|---|
| Baseline snapshot date | |
| Comparison snapshot date | |
| Report generation date | |
| Date this ticket was opened | |
| Estimated time window of the change | (between baseline and comparison snapshot timestamps) |

### 1.3 - Context

*Provide any context available at the time of ticket opening - system purpose, recent known changes to this server, any related tickets or maintenance windows that may be connected to this finding.*

---

## Section 2 - Investigation

### 2.1 - Initial Assessment

*Completed at the time the ticket is opened.*

What was the initial assessment of this finding before investigation?

- [ ] Likely expected change - need to confirm documentation
- [ ] Likely routine operation - need to confirm pre-approval scope
- [ ] Unexplained - requires active investigation
- [ ] Suspected security event - escalated to incident response

### 2.2 - Investigation Steps Taken

*Record each investigation step and its result as the investigation progresses. This section is updated by the assigned operator throughout the ticket lifecycle.*

| Step | Action Taken | Result | Date |
|---|---|---|---|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |

### 2.3 - Root Cause

*Completed when the investigation concludes.*

What caused this change?

*Example: "Service 'Spooler' was stopped on 2025-10-06 at 14:23 by administrator jsmith as part of emergency troubleshooting for CHG-4821. The service was intentionally left stopped pending a printer configuration review. This was not documented in the change record at the time."*

### 2.4 - Was This Change Authorised?

- [ ] Yes - the change was authorised. Proceed to Section 3.
- [ ] No - the change was not authorised. Proceed to Section 4.
- [ ] Unknown - investigation did not produce a conclusive answer. Treat as not authorised. Proceed to Section 4.

---

## Section 3 - Resolution (Authorised Change)

*Complete this section if Section 2.4 confirmed the change was authorised.*

### 3.1 - Documentation Status

- [ ] The change was already documented in ticket: ________________
- [ ] The change was retroactively documented in ticket: ________________ (opened as part of this investigation)
- [ ] The change matches pre-approved routine operation and no individual ticket is required. Routine operation category: ________________

### 3.2 - Remediation Required

Is any remediation required before this ticket can be closed?

- [ ] No remediation required - the current server state is acceptable as-is.
- [ ] Remediation required - describe what needs to happen before the state is acceptable:

*Description:*

*Target completion date:*

*Assigned to:*

### 3.3 - Baseline Update

Does this finding, once resolved, require a baseline promotion?

- [ ] No - the change is a one-time event that does not reflect a new permanent server state.
- [ ] Yes - the approved change represents a new permanent configuration. Baseline promotion should be initiated following `docs/operational-guide.md` Section 8 and `checklists/baseline-snapshot-checklist.md`.
  - Baseline promotion ticket or reference: ________________

---

## Section 4 - Escalation (Unauthorised or Unknown Change)

*Complete this section if Section 2.4 determined the change was not authorised or the investigation was inconclusive.*

### 4.1 - Escalation Record

| Field | Value |
|---|---|
| Escalated to | |
| Escalation date and time | |
| Incident ticket number | |
| Incident classification | |

### 4.2 - Evidence Preservation

- [ ] The baseline snapshot file has been preserved in a read-only location and its SHA-256 confirmed.
- [ ] The comparison snapshot file has been preserved in a read-only location and its SHA-256 confirmed.
- [ ] The diff JSON file has been preserved in a read-only location.
- [ ] The drift report (Markdown and JSON) has been preserved in a read-only location.
- [ ] No baseline promotion has been initiated or will be initiated until the incident process concludes.

Record the preservation location and SHA-256 values here:

| File | Preservation Path | SHA-256 |
|---|---|---|
| Baseline snapshot | | |
| Comparison snapshot | | |
| Diff file | | |
| Drift report (.md) | | |
| Drift report (.json) | | |

### 4.3 - Immediate Containment Actions

*Record any immediate containment actions taken pending the full incident investigation.*

| Action | Taken By | Date and Time |
|---|---|---|
| | | |
| | | |
| | | |

---

## Section 5 - Resolution and Close

*Completed when the ticket is ready to close.*

### 5.1 - Final Resolution Summary

*Describe in two to four sentences what was found, what was done, and what the outcome was. This summary should be readable by a future operator with no context about this ticket.*

### 5.2 - Preventive Action

Was any preventive action taken to reduce the likelihood of similar undocumented changes recurring?

- [ ] No preventive action required or taken.
- [ ] Process change made: ________________
- [ ] Technical control added: ________________
- [ ] Training or awareness action taken: ________________

### 5.3 - Closure Checklist

- [ ] Root cause is documented in Section 2.3.
- [ ] Section 2.4 authorisation determination is confirmed.
- [ ] All investigation steps are recorded in Section 2.2.
- [ ] If authorised: Section 3 is complete and any required remediation is confirmed done.
- [ ] If not authorised: Section 4 is complete, evidence is preserved, and incident ticket is referenced.
- [ ] Final resolution summary is written in Section 5.1.
- [ ] The corresponding row in `checklists/drift-response-checklist.md` is updated with this ticket number and the final outcome code.

### 5.4 - Sign-Off

| Field | Value |
|---|---|
| Resolved by | |
| Resolution date | |
| Reviewed and closed by | |
| Closure date | |

---