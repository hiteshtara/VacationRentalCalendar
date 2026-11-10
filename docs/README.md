# Project documentation

**Work in progress.** The application and these documents are evolving together. Status statements describe the last reviewed source, not continuous monitoring or a production-readiness guarantee.

Start with [How Vacation Rental Calendar works](PROJECT-GUIDE.md) for the local workflow, Mermaid application diagrams, planned AWS flow and current implementation gaps.

## Keeping documentation current

During project work, review documentation alongside changes to application behavior, schemas, handlers, configuration and deployment status. Update the affected guide and diagrams in the same change whenever practical.

- Check implementation claims against current source and relevant verification results.
- Keep implemented, planned, blocked and deployed states distinct. Record deployment only with deployment evidence.
- Recheck the project guide’s open gaps when the corresponding code changes; remove resolved gaps only after verification.
- Update commands and component references when entry points or prerequisites change.
- Validate local links and diagram syntax after edits. Mark diagrams as unrendered when rendering has not been verified.
- Preserve historical design documents as snapshots; link to the current guide when a decision is superseded.

Last documentation review: November 9, 2026. Owner-selected maintenance scope: update documentation during project work in this chat. No scheduled background monitoring is configured.

| Need | Read |
|---|---|
| Understand the application | [Project guide and diagrams](PROJECT-GUIDE.md) |
| Start using it | [How to review your calendars safely](GETTING-STARTED.md) |
| Find code, storage and commands | [Component reference](COMPONENTS.md) |
| Resume engineering work | [Operational handoff](../HANDOFF.md) |
| Understand project constraints | [Repository guidance](../CLAUDE.md) |

## Detailed plans and historical research

These documents preserve design reasoning and earlier status snapshots. Where they disagree, use current source for implementation facts, the handoff for recorded operational state, and the new project guide for an explicit distinction between current and intended behavior. Resource counts, test totals and cost estimates in older documents are not live measurements.

| Document | Scope |
|---|---|
| [Minimal sync service](MINIMAL-SYNC-SERVICE.md) | Current direction: Mac UI plus minimal AWS service; replaces the earlier dashboard proposal |
| [Backend implementation](BACKEND-IMPLEMENTATION.md) | Persistence, handlers and security design |
| [PR10 completion](PR10-COMPLETION.md) | Transaction and cloud-client work |
| [Migration plan](MIGRATION-PLAN.md) | Reconciliation and migration planning |
| [Central architecture](CENTRAL-ARCHITECTURE.md) | Earlier central-system design; dashboard scope superseded |
| [Website booking integration](WEBSITE-BOOKING-INTEGRATION.md) | Proposed read-only website source; older local-storage architecture |
| [Platform sync research](PLATFORM-SYNC-RESEARCH.md) | Platform access and iCal constraints |
| [Original design](superpowers/specs/2026-11-08-vacation-rental-calendar-design.md) | Initial application specification |
