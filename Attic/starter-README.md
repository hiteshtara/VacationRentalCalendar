# Vacation Rental Calendar for macOS

Native SwiftUI macOS starter project. It imports iCal feeds for Airbnb, Vrbo, and Booking.com, shows events, and lets you classify blocks locally.

## Run

1. Install Xcode 15 or newer.
2. Open Terminal in this folder and run `swift run` (requires macOS 13+).
3. Enter your own calendar export URLs and click Import.

The app stores imported data in memory for this initial prototype. It does not publish feeds or write availability to booking platforms. Do not treat it as double-booking protection yet.

## Critical safety rule

Airbnb exported iCal events may not identify cancellation penalty blocks. Never infer that an unavailable date is a confirmed booking solely from its iCal event. Classify uncertain blocks manually. Do not automatically forward Airbnb events to other platforms.

## Planned next phase

SQLite persistence, review queue, conflict alerts, and optional hosted filtered iCal feeds after confirming platform support.
