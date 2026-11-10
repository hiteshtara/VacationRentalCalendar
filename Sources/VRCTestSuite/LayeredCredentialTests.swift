import Foundation
import VRCCore

/// Reading from the new store, falling back to the old one.
///
/// Migration has to be additive and reversible, which rules out a flag day.
/// `LayeredFeedCredentialStore` writes to the new store and reads from either,
/// so a credential that has not moved yet still works and a credential that
/// has moved is preferred. Nothing is ever deleted from the legacy store, so
/// rollback is a one-line change of which store is constructed.
///
/// The ordering matters in one direction only: the new store wins on read. If
/// the legacy store won, a migrated credential would keep being served from
/// the old item and the migration would never actually take effect — the kind
/// of silent no-op this project has already shipped twice.
public enum LayeredCredentialTests {

    static func layered(
        primary: FeedCredentialStore = InMemoryFeedCredentialStore(),
        fallback: FeedCredentialStore = InMemoryFeedCredentialStore()
    ) -> (store: LayeredFeedCredentialStore, primary: FeedCredentialStore,
          fallback: FeedCredentialStore) {
        (LayeredFeedCredentialStore(primary: primary, fallback: fallback), primary, fallback)
    }

    public static var cases: [TestCase] { [

        TestCase(group: "Layered credentials",
                 name: "a credential only in the legacy store is still readable") { expect in
            // The state every credential is in on the day migration begins.
            let (store, _, legacy) = layered()
            try legacy.save(url: "https://a.test/f.ics", reference: "airbnb-v6")
            expect.equal(try store.url(reference: "airbnb-v6"), "https://a.test/f.ics")
            expect.ok(store.exists(reference: "airbnb-v6"))
        },

        TestCase(group: "Layered credentials",
                 name: "the new store wins when both hold a value") { expect in
            // If the legacy value won, migrating would be a silent no-op.
            let (store, modern, legacy) = layered()
            try legacy.save(url: "https://old.test/f.ics", reference: "airbnb-v6")
            try modern.save(url: "https://new.test/f.ics", reference: "airbnb-v6")
            expect.equal(try store.url(reference: "airbnb-v6"), "https://new.test/f.ics")
        },

        TestCase(group: "Layered credentials",
                 name: "writes go to the new store and never touch the legacy one") { expect in
            // The legacy entry is the rollback. Writing over it would destroy
            // the only way back.
            let (store, modern, legacy) = layered()
            try legacy.save(url: "https://old.test/f.ics", reference: "airbnb-v6")
            try store.save(url: "https://new.test/f.ics", reference: "airbnb-v6")
            expect.equal(try modern.url(reference: "airbnb-v6"), "https://new.test/f.ics")
            expect.equal(try legacy.url(reference: "airbnb-v6"), "https://old.test/f.ics",
                         "the legacy entry is the rollback and must survive")
        },

        TestCase(group: "Layered credentials",
                 name: "a legacy read failure is not fatal when the new store has it") { expect in
            // The real post-rebuild state: the legacy item exists but its
            // access list names a build that no longer exists.
            let (store, modern, _) = layered(
                fallback: UnreadableFeedCredentialStore(presentReferences: ["airbnb-v6"]))
            try modern.save(url: "https://new.test/f.ics", reference: "airbnb-v6")
            expect.equal(try store.url(reference: "airbnb-v6"), "https://new.test/f.ics")
        },

        TestCase(group: "Layered credentials",
                 name: "a primary failure falls through rather than giving up") { expect in
            // During migration the new store may be unusable — no entitlement,
            // no profile, wrong team. The app must keep working on the legacy
            // credential rather than reporting everything broken.
            let (store, _, legacy) = layered(
                primary: UnreadableFeedCredentialStore(presentReferences: []))
            try legacy.save(url: "https://old.test/f.ics", reference: "airbnb-v6")
            expect.equal(try store.url(reference: "airbnb-v6"), "https://old.test/f.ics")
        },

        TestCase(group: "Layered credentials",
                 name: "unknown in both is nil, not an error") { expect in
            // Never configured is not broken — the distinction the diagnostics
            // depend on.
            let (store, _, _) = layered()
            expect.ok((try store.url(reference: "nothing-here")) == nil)
            expect.ok(!store.exists(reference: "nothing-here"))
        },

        TestCase(group: "Layered credentials",
                 name: "deleting removes the new copy and leaves the legacy one") { expect in
            // Deletion is how a rollback is completed, and it must not take the
            // thing being rolled back to with it.
            let (store, modern, legacy) = layered()
            try legacy.save(url: "https://old.test/f.ics", reference: "airbnb-v6")
            try store.save(url: "https://new.test/f.ics", reference: "airbnb-v6")
            try store.delete(reference: "airbnb-v6")
            expect.ok((try modern.url(reference: "airbnb-v6")) == nil)
            expect.equal(try legacy.url(reference: "airbnb-v6"), "https://old.test/f.ics")
            expect.equal(try store.url(reference: "airbnb-v6"), "https://old.test/f.ics",
                         "and the layered store falls back to it again")
        },

        TestCase(group: "Layered credentials",
                 name: "the description names both layers, so the UI cannot mislead") { expect in
            let (store, _, _) = layered()
            expect.contains(store.storageDescription, "in-memory")
        },

        // --- Which store production actually picks ----------------------------

        TestCase(group: "Layered credentials",
                 name: "an unentitled build never selects the data protection store") { expect in
            // The test runner is not team-signed. Selecting the data protection
            // store here would mean every read failing with -34018, so the
            // selection must notice and stay on the legacy store.
            expect.ok(!AppleTeam.runningCodeCanUseAccessGroup,
                      "precondition: this process is not team-signed")
            expect.ok(!CredentialStoreSelection.shouldUseDataProtection,
                      "so the data protection store must not be selected")
        },
    ] }
}
