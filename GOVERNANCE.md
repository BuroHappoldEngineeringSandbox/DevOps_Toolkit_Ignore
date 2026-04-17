# Governance

> These principles describe how the platform team operates and makes decisions.  
> They are not aspirational — they are the standard we hold ourselves to.

---

## Platform Principles

### 1. The pipeline is the gatekeeper, not the person.

Automated checks exist to catch what humans miss under pressure. We do not bypass CI, compliance, or branch protection rules to meet a deadline – even if the fault appears trivial and the fix appears obvious. A check that can be bypassed on request is a check that offers no guarantee.

---

### 2. Convenience for one is risk for all.

Every exception we grant sets a precedent. Before making an exception to a rule or process, we ask: would we be comfortable granting this exception to every team, every time? If not, we fix the rule rather than bypass it.

---

### 3. Fix the signal, not the alarm.

When a check fails on code that is believed to be correct, the correct response is to fix the check or the code – not to disable or skip the check. A misconfigured check is a platform problem to be resolved, not a justification for bypassing it. We hold the check in place while we resolve the underlying cause.

---

### 4. Access is granted by the minimum needed.

We grant the lowest permission level that allows the work to be done. Elevated access is time-bound, documented, and reverted when the need has passed. We do not leave doors open for convenience.

---

### 5. Nothing in production that hasn't been reviewed.

All changes to shared infrastructure, CI configuration, and governance workflows go through the same review process we ask of contributors. The platform team does not hold itself to a lower standard than the repos it governs.

---

### 6. Transparency is the default.

Decisions, exceptions, and changes made by the platform team are documented and visible. If a decision would be uncomfortable to explain to the teams we support, it warrants more scrutiny – not less visibility.

---

### 7. Automate the burden, not the judgement.

We automate repetitive operational work so that humans spend their time on decisions that require context. We do not automate decisions that carry risk or require accountability – those remain with a person.
