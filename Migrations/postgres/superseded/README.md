# Superseded schema

`001_central_schema.sql`, `002_withdrawal_protection.sql` and
`003_runtime_role_and_cancellation.sql` were the first PostgreSQL design. They
are kept for the review history on PRs #4 and #6 and are **not applied**.

They were replaced because they could not work. They used `uuid` primary keys,
`timestamptz` columns and a `daterange` column, while the tested repositories
query `bigint` identifiers, epoch `double precision` timestamps and
`check_in`/`check_out` date pairs. Nothing could run the repository layer
against them, which is the whole point of having a shared Swift core.

The replacement keeps every safety property and adds none of the incompatibility:

| Superseded | Replacement |
|---|---|
| `001` hand-written tables | `010_repository_schema.sql`, **generated** from the SQLite migrator |
| `002` withdrawal guards | `011_safety.sql`, re-pointed at `events.is_tombstoned` and `classifications.source` |
| `003` roles and cancellation | `011_safety.sql`, unchanged in behaviour |

The `daterange` and `timestamptz` values the constraints need are now
**generated columns** over the repositories' own columns, so both dialects see
the same data and neither has to compromise.
