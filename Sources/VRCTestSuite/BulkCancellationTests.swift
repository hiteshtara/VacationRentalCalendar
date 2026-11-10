import Foundation
import VRCCore

/// "Cancel all" must not discard work the owner already approved.
///
/// The bug it replaces: `cancelPending` selected rows with
/// `AvailabilityStatus.isPending`, which includes `.approved`. That predicate
/// is correct where it was written — for CONFLICT CHECKS, because an approved
/// but unpublished decision still occupies those nights and must block an
/// overlapping one. Reusing it as a DELETION SCOPE answers a different
/// question, and the editor's "Cancel all" button therefore swept up approved
/// decisions alongside drafts. It cost the owner two approved Vrbo decisions.
///
/// The distinction is the whole fix: `isPending` means "still occupies these
/// nights", `isDiscardableInBulk` means "safe to throw away without asking
/// again". Approval is the owner saying yes, and a bulk sweep must not undo it.
public enum BulkCancellationTests {

    static func makeStore() throws -> (store: RentalStore, propertyID: Int64) {
        let store = try RentalStore.makeInMemory()
        let property = try store.properties.insert(Property(name: "39 G Street"))
        return (store, property.id!)
    }

    static func plan(_ propertyID: Int64, _ day: Int) -> AvailabilityPlan {
        AvailabilityPlan(
            propertyID: propertyID,
            startDay: DayMath.day(2027, 6, day),
            endDay: DayMath.day(2027, 6, day + 2),
            reason: "Test",
            actions: [.vrbo: .block])
    }

    /// A decision in each state the editor can show, for one property.
    static func submitAndApprove(_ s: (store: RentalStore, propertyID: Int64), day: Int) throws -> Int64 {
        let submitted = try s.store.availabilityManager.submit(plan(s.propertyID, day))
        let id = submitted[0].id!
        _ = try s.store.availabilityManager.approve(decisionID: id)
        return id
    }

    public static var cases: [TestCase] { [

        // --- The regression itself -------------------------------------------

        TestCase(group: "Bulk cancellation",
                 name: "cancel all leaves an approved decision alone") { expect in
            // Fails against the old implementation, which cancelled it.
            let setup = try makeStore()
            let approvedID = try submitAndApprove(setup, day: 1)
            expect.equal(try setup.store.availability.find(id: approvedID)?.status, .approved,
                         "precondition")

            _ = try setup.store.availabilityManager.cancelPending(propertyID: setup.propertyID)

            expect.equal(try setup.store.availability.find(id: approvedID)?.status, .approved,
                         "an approval is the owner's decision; a sweep must not undo it")
        },

        TestCase(group: "Bulk cancellation",
                 name: "cancel all still clears drafts and work awaiting approval") { expect in
            // The other half: narrowing the scope must not make the button
            // useless. Everything the owner has NOT yet approved still goes.
            let setup = try makeStore()
            _ = try setup.store.availabilityManager.submit(plan(setup.propertyID, 5))
            _ = try setup.store.availabilityManager.submit(plan(setup.propertyID, 9))

            let result = try setup.store.availabilityManager.cancelPending(
                propertyID: setup.propertyID)

            expect.equal(result.cancelled, 2)
            expect.equal(result.keptApproved, 0)
            expect.ok(try setup.store.availability.forProperty(setup.propertyID)
                .allSatisfy { $0.status == .cancelled })
        },

        TestCase(group: "Bulk cancellation",
                 name: "a mixed queue reports exactly what was kept") { expect in
            // The owner has to be told, or a silently smaller sweep is its own
            // surprise. This count is what the editor puts on screen.
            let setup = try makeStore()
            let approvedID = try submitAndApprove(setup, day: 1)
            _ = try setup.store.availabilityManager.submit(plan(setup.propertyID, 5))

            let result = try setup.store.availabilityManager.cancelPending(
                propertyID: setup.propertyID)

            expect.equal(result.cancelled, 1, "the un-approved one")
            expect.equal(result.keptApproved, 1, "and the approved one was kept, and said so")
            expect.equal(try setup.store.availability.find(id: approvedID)?.status, .approved)
        },

        TestCase(group: "Bulk cancellation",
                 name: "isDiscardableInBulk is not isPending") { expect in
            // Stated directly, because the bug was these two being treated as
            // the same question.
            expect.ok(AvailabilityStatus.approved.isPending,
                      "approved still occupies the nights, for conflict checks")
            expect.ok(!AvailabilityStatus.approved.isDiscardableInBulk,
                      "but it is not safe to throw away in bulk")
            for status in [AvailabilityStatus.draft, .validated, .awaitingApproval] {
                expect.ok(status.isDiscardableInBulk, "\(status.rawValue) may be swept")
            }
            for status in [AvailabilityStatus.published, .awaitingPlatformRefresh,
                           .verified, .failed, .cancelled, .unknown] {
                expect.ok(!status.isDiscardableInBulk,
                          "\(status.rawValue) must never be swept")
            }
        },

        // --- Withdrawing an approval, deliberately ----------------------------

        TestCase(group: "Bulk cancellation",
                 name: "plain cancel refuses an approved decision and says why") { expect in
            // Closing the back door. Narrowing only the bulk path would leave
            // every other caller able to cancel an approval silently.
            let setup = try makeStore()
            let approvedID = try submitAndApprove(setup, day: 1)
            do {
                _ = try setup.store.availabilityManager.cancel(decisionID: approvedID)
                expect.fail("cancelling an approved decision must be refused")
            } catch let error as AvailabilityError {
                guard case .approvedRequiresWithdrawal = error else {
                    return expect.fail("wrong error: \(error)")
                }
                expect.contains(error.errorDescription ?? "", "withdraw")
            }
            expect.equal(try setup.store.availability.find(id: approvedID)?.status, .approved)
        },

        TestCase(group: "Bulk cancellation",
                 name: "an approval can be withdrawn through the explicit route") { expect in
            // It must remain possible — an owner who changes their mind should
            // not have to edit the database. It just cannot happen by accident.
            let setup = try makeStore()
            let approvedID = try submitAndApprove(setup, day: 1)

            let withdrawn = try setup.store.availabilityManager.withdrawApproved(
                decisionID: approvedID, confirmation: .ownerConfirmedWithdrawal,
                reason: "Changed my mind")

            expect.equal(withdrawn.status, .cancelled)
            expect.ok(withdrawn.cancelledAt != nil)
        },

        TestCase(group: "Bulk cancellation",
                 name: "withdrawal preserves the publication UID and the audit trail") { expect in
            // A changed UID makes a platform see a delete plus a create rather
            // than an update, and the history is how any of this is explicable
            // later. Neither may be lost when a decision is withdrawn.
            let setup = try makeStore()
            let approvedID = try submitAndApprove(setup, day: 1)
            let before = try setup.store.availability.find(id: approvedID)!

            let withdrawn = try setup.store.availabilityManager.withdrawApproved(
                decisionID: approvedID, confirmation: .ownerConfirmedWithdrawal)

            expect.equal(withdrawn.publicationUID, before.publicationUID,
                         "the UID is migrated verbatim, never regenerated")
            let history = try setup.store.auditLog.entries(forDecision: approvedID)
            expect.ok(history.contains { $0.event == "created" }, "the start survives")
            expect.ok(history.contains { $0.toStatus == .approved }, "the approval survives")
            expect.ok(history.contains { $0.toStatus == .cancelled }, "and the withdrawal is recorded")
        },

        TestCase(group: "Bulk cancellation",
                 name: "withdrawal refuses anything that was never approved") { expect in
            // The explicit route is for approvals only; a draft goes through
            // ordinary cancellation, and conflating them would let this bypass
            // the normal transition rules.
            let setup = try makeStore()
            let submitted = try setup.store.availabilityManager.submit(plan(setup.propertyID, 5))
            do {
                _ = try setup.store.availabilityManager.withdrawApproved(
                    decisionID: submitted[0].id!, confirmation: .ownerConfirmedWithdrawal)
                expect.fail("only an approved decision can be withdrawn")
            } catch let error as AvailabilityError {
                guard case .notApproved = error else {
                    return expect.fail("wrong error: \(error)")
                }
            }
        },

        // --- What must never happen -------------------------------------------

        TestCase(group: "Bulk cancellation",
                 name: "a cancelled decision is never revived by any of this") { expect in
            // The owner's two cancelled Vrbo decisions are historical fact.
            // Narrowing the cancel scope must not resurrect anything.
            let setup = try makeStore()
            let submitted = try setup.store.availabilityManager.submit(plan(setup.propertyID, 5))
            let id = submitted[0].id!
            _ = try setup.store.availabilityManager.cancel(decisionID: id)
            expect.equal(try setup.store.availability.find(id: id)?.status, .cancelled)

            _ = try setup.store.availabilityManager.cancelPending(propertyID: setup.propertyID)

            expect.equal(try setup.store.availability.find(id: id)?.status, .cancelled,
                         "still cancelled, not reopened")
        },

        TestCase(group: "Bulk cancellation",
                 name: "a kept approval still contributes to a feed") { expect in
            // The point of keeping it. If a sweep left the row alone but the
            // decision stopped counting, the nights would quietly go back on
            // sale — the exact failure this project exists to prevent.
            let setup = try makeStore()
            let approvedID = try submitAndApprove(setup, day: 1)
            _ = try setup.store.availabilityManager.cancelPending(propertyID: setup.propertyID)

            let decision = try setup.store.availability.find(id: approvedID)!
            expect.ok(decision.status.contributesToFeed,
                      "an approved decision kept by the sweep must still block its nights")
        },
    ] }
}
