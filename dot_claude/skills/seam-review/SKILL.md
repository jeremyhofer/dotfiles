---
name: seam-review
description: Use when writing, reviewing or amending an architecture or security review, a decision record that designs or changes a system (a host, a service, a network, a VM layout, a backup scheme), or a per-machine posture crosswalk, and when asked "what are we missing?", "is this reviewed against the seams?", "threat model this", "is this secure?", or to apply NIST CSF, CIS Controls, AWS Well-Architected or STRIDE. Covers the 21-seam checklist drawn from those frameworks, the rule that every seam gets a row (answered, not applicable with a reason, or open) and a missing row is a finding, STRIDE for each data flow across a trust boundary, which evidence may answer a cell, how a machine crosswalk differs from a design review, and what the reviewer may not decide.
---

# Reviewing a system against the seams

**A review can miss only what its author did not think of, and nothing shows the miss.** A review
that picks its own areas looks complete because every area it chose is covered; the gap is the area
it never listed. Measured on one estate: a security review that chose its own twelve areas covered 9
of the 21 seams below, and a design that reasoned from one threat had assumed a hardware chip that
did not exist, left a certificate authority's key readable by every process of the user, and moved
data before any restore was rehearsed. The fix is a fixed list drawn from outside frameworks, walked
every time, so an omission becomes a row marked open instead of an absence.

A *seam* is one area of concern a review answers for. The frameworks call it a Category (NIST CSF),
a Control (CIS) or a best-practice area (AWS).

## 1. The three frameworks, and what each contributes

- **NIST Cybersecurity Framework (CSF) 2.0** (2024-02-26, free): an outcome taxonomy, results to
  reach rather than how. 6 Functions, 22 Categories (identifiers like `PR.AA`, `GV.SC`). The broadest
  security list; it supplies the security seams.
- **CIS Critical Security Controls v8.1** (June 2024, CC BY-NC-ND 4.0): prescriptive actions, 18
  Controls, 153 Safeguards. Implementation Group 1 (IG1, 56 Safeguards) is CIS's "essential cyber
  hygiene" for a small organization with limited security expertise; it is each security seam's
  **floor**. Take the floor from CIS's own published mapping of v8.1 to CSF 2.0, not a home-made
  crosswalk. CIS also publishes **Benchmarks**, hardening guides per product (macOS, Ubuntu, Debian
  and others), with a low-impact Level 1 and a deeper Level 2; read a host against Level 1 as a
  reference. **Do not copy CIS text into a committed file**: its license forbids redistributing a
  modified copy. Cite by number.
- **AWS Well-Architected** (free): design-review questions in six pillars. Its Reliability,
  Operational Excellence, Performance Efficiency, Cost Optimization and Sustainability questions are
  portable to any system and are the best published list of the seams outside security.

No framework names two seams a small self-hosted estate meets repeatedly: moving to the next home
(SEAM-20) and physical presence (SEAM-21). They are added. Cite every framework by version and every
Category, Control and question by identifier. A new major version of any of the three is a reason to
revisit the list.

## 2. The 21 seams

| Seam | A review answers | CSF 2.0 | CIS v8.1 | AWS |
| --- | --- | --- | --- | --- |
| SEAM-01 Governance and decisions | who decides, which records own the subject, what the review may not decide alone, what the people and agents acting on it are taught | GV.OC, GV.RM, GV.RR, GV.PO, GV.OV, PR.AT | 14 | SEC01 |
| SEAM-02 Assets and data flows | what runs, what data it holds, where data moves | ID.AM | 1, 2, 3 | SEC07 |
| SEAM-03 Threats and risk | who could attack what, how likely, what is accepted | ID.RA, GV.RM | 7 | none |
| SEAM-04 Identity and access | every human, service and agent identity, what each may reach, second factors | PR.AA | 5, 6 | SEC02, SEC03 |
| SEAM-05 Secrets and keys | each secret class: where it lives, who can read it, how it is delivered, escrowed and rotated | PR.DS, PR.AA | 3, 6 | SEC08, SEC09 |
| SEAM-06 Data protection | data at rest and in transit, retention, disposal | PR.DS | 3 | SEC07 to SEC09 |
| SEAM-07 Secure configuration | the hardening baseline per host class, service sandboxing, defaults narrowed | PR.PS | 4 | SEC06 |
| SEAM-08 Patching and updates | how each component is updated, by whom, how fast after an advisory | PR.PS, ID.RA | 2, 7 | SEC06 |
| SEAM-09 Supply chain | where software, images and build tools come from; their licenses and owners; what CI builds | GV.SC | 2, 15, 16 | SEC11 |
| SEAM-10 Network exposure | ingress, segmentation, egress, DNS and time | PR.IR, PR.PS | 4, 12, 13 | SEC05, REL02 |
| SEAM-11 End-user devices and browsing | browsers, mail and malware defenses on machines a person uses | PR.PS | 9, 10 | none |
| SEAM-12 Logging and detection | what is logged, what alerts, how a silenced alarm is noticed | DE.CM, DE.AE | 8, 13 | SEC04, OPS01 |
| SEAM-13 Incident response | when a key leaks or a host is suspect: who is told, what is revoked, contained, rebuilt | RS.MA, RS.AN, RS.CO, RS.MI, RC.CO | 17 | SEC10, OPS06 |
| SEAM-14 Backup and restore | per data store: what is copied, where, how often, and a restore rehearsed | PR.DS, RC.RP | 11 | REL09, REL13 |
| SEAM-15 Durability and integrity | silent corruption, integrity checks, how a loss is noticed | PR.DS | 3, 11 | REL09 |
| SEAM-16 Availability and failure modes | what stops on a reboot, a logout or a dependency's loss; single points of failure | PR.IR | none | REL10 to REL12 |
| SEAM-17 Capacity and performance | memory, disk, CPU and network headroom; limits | PR.IR | none | REL01, REL07, Performance Efficiency |
| SEAM-18 Operability | deploy, change, observe; runbooks; tested tools for repeated procedures | ID.IM | none | Operational Excellence, REL08 |
| SEAM-19 Cost, power and the operator's time | money, power, and the hours of review and upkeep the owner spends | none | none | Cost Optimization, Sustainability |
| SEAM-20 Migration, as an extension of backup and restore | how each service and data store moves to its next home (an interim design's end state, a replacement machine): the export, import and rehearsed restore SEAM-14 uses, and what the move rebuilds | none | none | none |
| SEAM-21 Hands at the machine | physical presence as a security property: laptop or desktop, regularly attended or not, which actions the machine permits only to a person at it and which remotely, and each step needing a keyboard, a GUI prompt or a hardware key | none | none | none |

**SEAM-20** treats a move as a restore: an unrehearsed restore is also an unrehearsed migration, so a
design that moves data names the export, the import and the rehearsal before the move. **SEAM-21**
separates a laptop that leaves the house from a desktop at home and a server nobody visits: what an
SSH session may do, what needs a person at the keyboard, and what a stolen or unattended device
exposes differ among them, and a review states the division rather than assuming one.

## 3. The method

1. **Carry a row for every seam** in each of: a decision record that designs or changes a system, a
   design review of a system, and a crosswalk of a machine (section 4). A record about standards or
   process designs no system and carries none.
2. **Each cell is answered, n/a with the reason, or open** (say what is missing). "Partly answered"
   names the open part. **A seam absent from the table is a finding against the review.** "n/a"
   means the seam cannot apply ("no browser runs here"), never "nothing is recorded", which is open.
3. **For each data flow that crosses a trust boundary** (a network edge, an account, a VM), find its
   threats with **STRIDE**, Microsoft's enumeration: Spoofing, Tampering, Repudiation, Information
   disclosure, Denial of service, Elevation of privilege. One row per flow: the flow, the boundary,
   the letters that apply, and the control or the accepted risk for each.
4. **Keep the table in the record or in a research note the record cites.**
5. **Apply it to every new system record**, and to an older one when it is next amended; older
   records are otherwise reached through the crosswalks.

## 4. A crosswalk: one machine as it stands

A design review asks the seams of one design. A **crosswalk** asks them of one machine as it is
today, and maps every decision record and tracked work item onto the seams it covers. In CSF's terms
it is a *Current Profile*, from which a target can later be set. Crosswalk every machine once, and
update a machine's table when a record that changes one of its seams is accepted. The seams that come
up open on every machine (rotation, a hardening baseline, detection, incident response are the usual
ones) are fleet-wide: one standard closes them everywhere, so collect them in their own section
rather than repeating six times.

## 5. What may answer a cell

These rules come from crosswalks that were wrong in review, each time in the confident direction:

- **Only an accepted decision, a done work item, a measurement, or built code answers a cell.** A
  proposed record is cited as "proposed", and a superseded one answers nothing. Citing a proposal as
  the answer hid an open seam once.
- **Read the decision text and its amendment log, never a summary, title or index line.** An
  amendment overrides the original; a summary drops exactly what a reviewer would look for. Twice in
  one review a summary had named the wrong key and the wrong mechanism.
- **Say whether a cell is recorded or measured, and list the commands a measurement ran.** A probe
  that cannot see a layer (a root-only firewall ruleset from an unprivileged shell) proves nothing
  about it; say so rather than reporting the layer clean.
- **Check the absences hardest.** "No restore was ever rehearsed" was written about a machine whose
  restores had been rehearsed and recorded; a claim that something does not exist needs the search
  that would have found it.
- **Designed is not built.** A cell about a control that exists only on paper says so; "designed,
  not built" is a different open from "never decided".
- **A count of open cells is not a measure of severity.** A missing power figure and a missing
  firewall each count one.

## 6. What the reviewer does not decide

The reviewer finds and records; the system's owner decides what each open cell becomes: a task, a
work item of its own, a part of existing work, or an accepted risk with its reason. Lay out those
choices and recommend where to start; do not file work or close a cell by deciding it. A finding
that disputes a design's decision goes to the owner with the review, not resolved before it.

## 7. Review the review

A seam table is written by the person least able to see its gaps. Before it reaches the owner, have
it read in fresh contexts on at least three lenses: **citation accuracy** (open each cited line;
check each record's status), **correlation and judgment** (missed records, contradictions with other
records, cells that overreach or understate, counts that do not match the tables), and
**self-containment** (every reference resolves; the method is taught before the tables). Fix what
they find and record the review with the table.

---

If `~/.dotlocal/skills/seam-review.md` exists, read it: it is this domain's half (which decision
record owns the list, where the crosswalks live, and its first applications). If it does not, the
generic content above is the whole picture.
