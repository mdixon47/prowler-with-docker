# Mutelist: recording accepted findings

[`config/mutelist.yaml`](../config/mutelist.yaml) is the list of findings this account has looked at and deliberately accepted, each with the reason and the condition that should make someone revisit it.

```bash
make mutelist        # upload it to the running Prowler server
```

---

## Muting is not ignoring

A scan of any real account produces findings that are correct but not actionable *here* — a check measuring a capability you don't need yet, a bucket that is public on purpose, a control that costs more than the risk it removes. Left unmuted they crowd out the findings that do matter, and the dashboard slowly becomes something people stop reading.

The difference between muting and ignoring is the written reason. Every entry in `config/mutelist.yaml` carries:

- **What was accepted** and when
- **The evidence at acceptance time** — the state of the account that made it a reasonable call
- **REVISIT WHEN** — the specific change that invalidates the reasoning

That last line is what stops a mutelist from quietly becoming a list of things nobody has thought about in two years. An accepted finding is a decision with an expiry condition, not a deletion.

## How the server stores it

Prowler Local Server models a mutelist as a **processor**, at `POST /api/v1/processors` with `processor_type: mutelist`. There is **one per tenant**, so applying a mutelist replaces the previous one rather than adding to it — `config/mutelist.yaml` is the single source of truth, and edits should go there rather than into the UI.

The schema, per check:

| Field | Meaning |
| --- | --- |
| `Regions` | Regex patterns; `"*"` matches all |
| `Resources` | Regex patterns against the resource identifier |
| `Tags` | Optional tag filters |
| `Exceptions` | Accounts/Regions/Resources/Tags that should *not* be muted |
| `Description` | Free text — where the reasoning goes |

Accounts are keyed by 12-digit account ID, or `"*"` for all. Narrow `"*"` to a specific account once more than one provider is connected, so an acceptance made for one account doesn't silently apply to another.

## Applying it

```bash
make mutelist
```

The script authenticates against the local API with your Prowler login — the account you created at <http://localhost:3000>, unrelated to AWS. The password is read with `read -s`, so it is never echoed, never stored, and never lands in your shell history or the process list.

It then creates the processor, or PATCHes the existing one if a mutelist is already registered.

> **Mutelists apply as findings are produced.** Existing findings keep whatever status they already have — run a new scan to see the effect.

### A note on YAML parsing

The file is YAML so it can carry comments, but macOS's system `python3` has no PyYAML. The script tries the host first and falls back to the API container's virtualenv, which does have it. That costs nothing, since the stack has to be running for the API call anyway. If neither is available it says so rather than failing obscurely.

## Current entries

### `securityhub_enabled` — accepted 2026-08-09

Prowler rates this **high**, and the finding is correct: AWS Security Hub is not enabled in any region.

It is accepted because severity describes the check, not the situation. At acceptance time the account held **0 Config recorders, 0 EC2 instances, 0 S3 buckets and 2 IAM users**. Security Hub measures a continuous-monitoring capability, and there is nothing here to monitor.

There is also a cost argument that Prowler's remediation text omits. Security Hub's controls depend on **AWS Config**, which bills per configuration item recorded and per rule evaluation, and Security Hub itself bills per check and per finding ingested — in every region where it is enabled. Turning both on account-wide would mean paying in every region to watch an empty account.

Prowler already provides the assessment coverage. What Security Hub adds is aggregation across sources and continuous evaluation between scans, which starts mattering when there is something to aggregate.

**Revisit when** any real workload is deployed, a second AWS account is added, or GuardDuty/Inspector/Macie are enabled and their findings need aggregating. At that point enable AWS Config and Security Hub in the primary region first, with the AWS FSBP standard, rather than everywhere at once.

Worth knowing: the check also passes on a **connected integration**, and `prowler-scan-additions` already grants `securityhub:BatchImportFindings` — so Prowler can push its own findings into Security Hub once it is enabled, making the two complementary rather than redundant.

## Adding an entry

1. Add the check to `config/mutelist.yaml` with `Regions`, `Resources` and a `Description` that answers *what*, *evidence*, and *revisit when*.
2. Add a short section to **Current entries** above explaining the decision in prose.
3. `make mutelist`
4. Re-scan.

If you cannot write a convincing **REVISIT WHEN**, that is a signal the finding should be fixed rather than muted.
