# Restic `copy` idempotency (0.16.4)

Assessment for Sprint F01.3c-3b (read-only documentation review).

## Native skip behavior

Per upstream Restic docs (`045_working_with_repos.html`), `restic copy` from a source to a
destination repository:

- With **no snapshot IDs** on the command line, copies **all** snapshots in the source repo
  (subject to `--host` / `--path` / `--tag` filters).
- Snapshots **already transferred** between the same source and destination pair are **skipped**
  on later runs, e.g. `skipping snapshot 4e5d5487, was already copied to snapshot 50eb62b7`.
- Interrupted copies **resume** on the next run (index flush may lose up to ~10 minutes of progress).

There is **no** separate application-level metadata match on `(time, hostname, tags)`; Restic
tracks copy relationships internally.

## Destination snapshot IDs

Destination snapshots receive **new** snapshot and tree IDs (different repository keys). Copied
snapshots expose the source snapshot ID in JSON as the **`original`** field (full hash).

Example (production Hetzner repo): `original` points at the local source snapshot `id`.

## Duplicates

Re-running `restic copy` for snapshots **already linked** does **not** create duplicates.
Re-copying after manual destination snapshot removal, or copying the same logical data via a
**new** source snapshot ID, **does** create additional destination snapshots.

## Safe synchronization strategy (implemented)

1. Run `restic copy --from-repo <local> … --host <backup-host>` with **no** explicit snapshot IDs.
2. Rely on Restic skip logic for idempotent re-runs.
3. **Verify** read-only: every source snapshot `id` for the backup host must appear as some
   destination snapshot’s `original` field. Fail closed if any are missing.

Do **not** use `restic snapshots --last` for “newest” selection.
