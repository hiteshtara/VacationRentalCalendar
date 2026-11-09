import Foundation
import VRCCore
import VRCSync

public enum SyncTests {
    static func classification(
        _ kind: BlockKind, source: ClassificationSource, at: Date,
        approved: Bool = false, suppressed: Bool = false, needsReview: Bool = false,
        key: String = "event-1"
    ) -> EventClassification {
        EventClassification(
            eventKey: key, kind: kind, confidence: .high, source: source,
            needsReview: needsReview, exportApproved: approved,
            exportSuppressed: suppressed, decidedAt: at
        )
    }

    static let early = Date(timeIntervalSince1970: 1_700_000_000)
    static let late = Date(timeIntervalSince1970: 1_800_000_000)

    public static var cases: [TestCase] { [

        // --- Merge rules -------------------------------------------------

        TestCase(group: "Sync", name: "a manual decision beats an automatic one, even if older") { expect in
            let outcome = SyncMergePolicy().merge(
                local: classification(.ownerBlock, source: .manual, at: early),
                remote: classification(.unknownUnavailable, source: .automatic, at: late),
                localDeviceID: "mac", remoteDeviceID: "phone"
            )
            expect.equal(outcome.resolution, .localWins)
            expect.equal(outcome.value.kind, .ownerBlock)
            expect.equal(outcome.value.source, .manual)
        },

        TestCase(group: "Sync", name: "a remote manual decision beats a local automatic one") { expect in
            let outcome = SyncMergePolicy().merge(
                local: classification(.unknownUnavailable, source: .automatic, at: late),
                remote: classification(.cancellationBlock, source: .manual, at: early),
                localDeviceID: "mac", remoteDeviceID: "phone"
            )
            expect.equal(outcome.resolution, .remoteWins)
            expect.equal(outcome.value.kind, .cancellationBlock)
        },

        TestCase(group: "Sync",
                 name: "two devices disagreeing sends the item back for review") { expect in
            let outcome = SyncMergePolicy().merge(
                local: classification(.ownerBlock, source: .manual, at: early, approved: true),
                remote: classification(.confirmedReservation, source: .manual, at: late,
                                       approved: true),
                localDeviceID: "mac", remoteDeviceID: "phone"
            )
            expect.equal(outcome.resolution, .escalatedToReview)
            expect.ok(outcome.value.needsReview, "a disagreement must go back to the owner")
            expect.ok(!outcome.value.exportApproved,
                      "approval must be withdrawn when devices disagree")
            expect.contains(outcome.value.rationale, "devices")
        },

        TestCase(group: "Sync", name: "export approval never merges upward") { expect in
            let outcome = SyncMergePolicy().merge(
                local: classification(.ownerBlock, source: .manual, at: late, approved: false),
                remote: classification(.ownerBlock, source: .manual, at: early, approved: true),
                localDeviceID: "mac", remoteDeviceID: "phone"
            )
            expect.ok(!outcome.value.exportApproved,
                      "one device withholding approval is enough to withhold it")
        },

        TestCase(group: "Sync", name: "suppression merges downward and sticks") { expect in
            let outcome = SyncMergePolicy().merge(
                local: classification(.confirmedReservation, source: .manual, at: late),
                remote: classification(.confirmedReservation, source: .manual, at: early,
                                       suppressed: true),
                localDeviceID: "mac", remoteDeviceID: "phone"
            )
            expect.ok(outcome.value.exportSuppressed,
                      "if either device said do not share, do not share")
        },

        TestCase(group: "Sync", name: "a tie is broken deterministically, both ways round") { expect in
            let policy = SyncMergePolicy()
            let a = classification(.ownerBlock, source: .manual, at: early)
            let b = classification(.ownerBlock, source: .manual, at: early)
            let fromMac = policy.merge(local: a, remote: b,
                                       localDeviceID: "aaa", remoteDeviceID: "zzz")
            let fromPhone = policy.merge(local: b, remote: a,
                                         localDeviceID: "zzz", remoteDeviceID: "aaa")
            expect.equal(fromMac.value.kind, fromPhone.value.kind,
                         "both devices must reach the same answer independently")
        },

        TestCase(group: "Sync",
                 name: "a merged cancellation block is still never exportable") { expect in
            // The worst case: another device insists it is an owner block and
            // approved for export, arriving after a local cancellation decision.
            let outcome = SyncMergePolicy().merge(
                local: classification(.cancellationBlock, source: .manual, at: late),
                remote: classification(.ownerBlock, source: .manual, at: early, approved: true),
                localDeviceID: "mac", remoteDeviceID: "phone"
            )
            let event = CalendarEvent(
                listingID: 1, eventKey: "event-1", uid: "u", platform: .airbnb,
                summary: "Airbnb (Not available)",
                checkIn: DayMath.day(2027, 4, 17), checkOut: DayMath.day(2027, 4, 20)
            )
            let decision = ExportPolicy().decide(
                event: event, classification: outcome.value, destination: .vrbo
            )
            expect.ok(!decision.isIncluded,
                      "no combination of synced state may make these dates exportable")
        },

        // --- What may leave the device -----------------------------------

        TestCase(group: "Sync", name: "no cloud record carries a feed URL or guest data") { expect in
            let listing = PlatformListing(
                id: 1, propertyID: 1, platform: .vrbo, label: "Vrbo — Test",
                icalURL: "https://www.vrbo.com/icalendar/SECRETTOKEN.ics?nonTentative",
                urlStorage: .keychain, credentialRef: "vrbo-secret-ref"
            )
            let event = CalendarEvent(
                listingID: 1, eventKey: "k", uid: "u", platform: .airbnb,
                summary: "Reserved",
                details: "Reservation URL: https://airbnb.com/x\nPhone Number (Last 4 Digits): 8891",
                checkIn: DayMath.day(2027, 3, 10), checkOut: DayMath.day(2027, 3, 15)
            )
            var records: [CloudRecord] = [
                CloudRecordMapper.record(for: event, listingID: 1),
                CloudRecordMapper.record(
                    for: EventClassification(
                        eventKey: "k", kind: .confirmedReservation, confidence: .high,
                        source: .manual, needsReview: false
                    ), deviceID: "mac"
                ),
            ]
            if let listingRecord = CloudRecordMapper.record(for: listing, modifiedAt: Date()) {
                records.append(listingRecord)
            }

            for record in records {
                for name in record.fields.keys {
                    expect.ok(
                        !CloudRecordMapper.forbiddenFieldNames.contains(name),
                        "record \(record.id) must not carry field \"\(name)\""
                    )
                }
                let serialised = record.fields.values.compactMap(\.stringValue).joined(separator: " ")
                expect.notContains(serialised, "SECRETTOKEN", "a feed URL must never be uploaded")
                expect.notContains(serialised, "vrbo-secret-ref",
                                   "even the Keychain reference stays local")
                expect.notContains(serialised, "8891", "guest phone digits must never be uploaded")
            }
        },

        TestCase(group: "Sync", name: "a listing arriving from the cloud brings no URL") { expect in
            let original = PlatformListing(
                id: 7, propertyID: 1, platform: .airbnb, label: "Airbnb — Test",
                icalURL: "https://www.airbnb.com/calendar/ical/1.ics?t=SECRET",
                urlStorage: .keychain, credentialRef: "airbnb-1"
            )
            guard let record = CloudRecordMapper.record(for: original, modifiedAt: Date()),
                  let (restored, _) = CloudRecordMapper.listing(from: record) else {
                return expect.fail("round trip failed")
            }
            expect.equal(restored.icalURL, "", "the URL must not survive the round trip")
            expect.equal(restored.credentialRef, "")
            expect.equal(restored.label, "Airbnb — Test", "but the label should")
        },

        TestCase(group: "Sync", name: "records round-trip faithfully") { expect in
            let classification = EventClassification(
                eventKey: "abc", kind: .cancellationBlock, confidence: .high,
                source: .manual, needsReview: false, note: "Host cancellation",
                exportApproved: false, decidedAt: early
            )
            let record = CloudRecordMapper.record(for: classification, deviceID: "mac")
            guard let (restored, device) = CloudRecordMapper.classification(from: record) else {
                return expect.fail("round trip failed")
            }
            expect.equal(restored.kind, .cancellationBlock)
            expect.equal(restored.source, .manual)
            expect.equal(restored.note, "Host cancellation")
            expect.equal(restored.decidedAt.timeIntervalSince1970,
                         early.timeIntervalSince1970)
            expect.equal(device, "mac")
        },

        // --- Engine ------------------------------------------------------

        TestCase(group: "Sync", name: "the engine pushes local state and reports it") { expect in
            let setup = try Fixtures.makeStore(feeds: [.airbnb: Fixtures.airbnbOpaqueBlocks])
            let listing = try setup.store.listings.find(id: setup.listingIDs[.airbnb]!)!
            _ = await setup.store.makeImportService(fetcher: setup.fetcher).importFeed(for: listing)

            let cloud = InMemoryCloudDatabase()
            let engine = CloudSyncEngine(store: setup.store, cloud: cloud, deviceID: "mac")
            let summary = await engine.synchronise()

            expect.ok(summary.succeeded, summary.error ?? "")
            expect.ok(summary.pushed > 0, "something should have been uploaded")
            let uploaded = await cloud.allRecords
            expect.ok(uploaded.contains { $0.type == .classification },
                      "classifications must reach the cloud")
            expect.ok(uploaded.contains { $0.type == .event })
        },

        TestCase(group: "Sync", name: "no iCloud account means no sync and no damage") { expect in
            let setup = try Fixtures.makeStore(feeds: [.vrbo: Fixtures.vrboBlocks])
            let listing = try setup.store.listings.find(id: setup.listingIDs[.vrbo]!)!
            _ = await setup.store.makeImportService(fetcher: setup.fetcher).importFeed(for: listing)
            let before = try setup.store.events.count()

            let cloud = InMemoryCloudDatabase()
            await cloud.setAccountStatus(.noAccount)
            let summary = await CloudSyncEngine(
                store: setup.store, cloud: cloud, deviceID: "mac"
            ).synchronise()

            expect.ok(!summary.accountStatus.canSync)
            expect.equal(summary.pushed, 0)
            expect.equal(try setup.store.events.count(), before, "local data untouched")
            expect.contains(summary.line, "iCloud")
        },

        TestCase(group: "Sync", name: "a sync failure leaves local data intact") { expect in
            let setup = try Fixtures.makeStore(feeds: [.vrbo: Fixtures.vrboBlocks])
            let listing = try setup.store.listings.find(id: setup.listingIDs[.vrbo]!)!
            _ = await setup.store.makeImportService(fetcher: setup.fetcher).importFeed(for: listing)

            let cloud = InMemoryCloudDatabase()
            await cloud.setFailNextSave(.networkUnavailable)
            let summary = await CloudSyncEngine(
                store: setup.store, cloud: cloud, deviceID: "mac"
            ).synchronise()

            expect.ok(!summary.succeeded)
            expect.equal(try setup.store.events.count(), 2, "nothing lost")
        },

        TestCase(group: "Sync",
                 name: "a decision made on the phone reaches the Mac and sticks") { expect in
            // Mac imports and uploads.
            let mac = try Fixtures.makeStore(feeds: [.airbnb: Fixtures.airbnbCancellationBlock])
            let listing = try mac.store.listings.find(id: mac.listingIDs[.airbnb]!)!
            _ = await mac.store.makeImportService(fetcher: mac.fetcher).importFeed(for: listing)
            let cloud = InMemoryCloudDatabase()
            _ = await CloudSyncEngine(store: mac.store, cloud: cloud, deviceID: "mac").synchronise()

            guard let item = try mac.store.classifiedEvents().first else {
                return expect.fail("nothing imported")
            }
            expect.ok(item.classification.needsReview)

            // The phone decides it is a cancellation block.
            let decided = EventClassification(
                eventKey: item.event.eventKey, kind: .cancellationBlock, confidence: .high,
                source: .manual, needsReview: false,
                note: "Decided on the phone", decidedAt: Date()
            )
            await cloud.seed([CloudRecordMapper.record(for: decided, deviceID: "phone")])

            // The Mac syncs again and adopts it.
            let summary = await CloudSyncEngine(
                store: mac.store, cloud: cloud, deviceID: "mac"
            ).synchronise()
            expect.ok(summary.succeeded, summary.error ?? "")

            let after = try mac.store.classifications.find(eventKey: item.event.eventKey)
            expect.equal(after?.kind, .cancellationBlock)
            expect.equal(after?.source, .manual)
            expect.contains(after?.note ?? "", "phone")

            // And it is still not exportable.
            let plan = try mac.store.exportPlan(propertyID: item.propertyID, destination: .vrbo)
            expect.equal(plan.included.count, 0)
        },
    ] }
}
