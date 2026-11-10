# How to review your calendars safely

This walkthrough uses the local Mac app to inspect bookings and ambiguous blocks. It ends with an owner-reviewed calendar; outbound synchronization remains disabled.

## Prerequisites

- macOS 14 or newer.
- Xcode Command Line Tools and a Swift toolchain compatible with `Package.swift`; the recorded development toolchain is Swift 6.3.3.
- The repository checked out locally.
- An iCal export URL for each listing you want to connect. Treat each URL as a password.

## Build and open

From the repository root:

```bash
./Scripts/setup-signing.sh
./Scripts/build-app.sh --install
```

The signing setup is a one-time operation. The install script builds the app bundle and installs it in `/Applications`. Open VacationRentalCalendar from Finder.

## Connect and inspect

1. Select the property and open Settings to configure its platform feeds. Paste URLs only into the application’s credential entry, which stores them in Keychain.
2. Click Refresh or press Command-R. Check the status bar and feed warnings; a refresh error does not mean the property is available.
3. Open Calendar and inspect month, week or list view. Select an event to read its evidence and classification.
4. Open Needs Review. Verify ambiguous events against the source platform before confirming a real reservation or classifying a penalty block.
5. Open Reservations and examine conflict findings. Investigate overlapping confirmed bookings; checkout and check-in on the same day are valid.
6. Open Availability to select dates and destinations and preview a proposed block. Read included and excluded nights before approving a decision. Approval records intent; it does not mean anything was published.

For a readout without opening the UI:

```bash
swift run vrc status
swift run vrc review
swift run vrc conflicts
swift run vrc doctor
```

## Verify the result

Confirm that unknown events remain under review and cancellation blocks are excluded from any destination preview. Check that the interface reports outbound off. Do not interpret an approved decision or a local file as proof that Vrbo, Airbnb or Booking.com changed availability.

For development verification, run `swift run vrc-test`. This checks the project’s behavior with its test harness; it does not verify live platform refreshes.

## Troubleshooting

**Stored URL cannot be read after rebuilding:** existing Keychain items may be pinned to an older ad-hoc code signature. The recorded failure can happen without a permission dialog. Re-enter the URL using the app or run `swift run vrc set-url --listing <id>` yourself in a terminal. The CLI hides input and validates before saving. Never include the URL in the command line.

**Nothing imports while the Mac sleeps:** that is a local-mode limitation. The planned cloud service is not deployed according to the handoff.

**An unavailable event stays unclassified:** a generic platform block may contain no booking evidence. Review it manually; the application deliberately does not infer a confirmed booking from “unavailable.”

**Cloud status is unavailable:** cloud client source exists, but deployment and UI integration are not complete. Use the local workflow and consult [the project guide](PROJECT-GUIDE.md#work-still-required).
