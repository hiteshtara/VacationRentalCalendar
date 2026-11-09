import SwiftUI
import Foundation

struct Booking: Identifiable {
    let id = UUID()
    var source: String
    var summary: String
    var start: Date
    var end: Date
    var classification: Classification = .needsReview
}
enum Classification: String, CaseIterable, Identifiable {
    case needsReview = "Needs review"
    case confirmed = "Confirmed booking"
    case penalty = "Airbnb penalty block"
    case owner = "Owner/maintenance block"
    var id: String { rawValue }
}

@MainActor final class CalendarStore: ObservableObject {
    @Published var events: [Booking] = []
    @Published var urls: [String: String] = ["Airbnb":"", "Vrbo":"", "Booking.com":""]
    @Published var message = "Calendar feeds are read-only. No availability is pushed to platforms."

    func importFeed(_ source: String) async {
        guard let raw = urls[source], let url = URL(string: raw), url.scheme == "https", url.host != nil else {
            message = "Enter a valid HTTPS calendar URL for \(source)."; return
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let content = String(data: data, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
            let imported = ICSParser.parse(content, source: source)
            events.removeAll { $0.source == source }
            events.append(contentsOf: imported)
            events.sort { $0.start < $1.start }
            message = "Imported \(imported.count) events from \(source). Review blocks before any sharing."
        } catch { message = "Could not import \(source): \(error.localizedDescription)" }
    }
}

enum ICSParser {
    static func parse(_ text: String, source: String) -> [Booking] {
        let unfolded = text.replacingOccurrences(of: "\r\n ", with: "")
            .replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "")
        let blocks = unfolded.components(separatedBy: "BEGIN:VEVENT").dropFirst()
        return blocks.compactMap { block in
            let body = block.components(separatedBy: "END:VEVENT").first ?? ""
            let lines = body.components(separatedBy: .newlines)
            func field(_ name: String) -> String? {
                lines.first(where: { $0.hasPrefix(name + ":") || $0.hasPrefix(name + ";") })?
                    .components(separatedBy: ":").dropFirst().joined(separator: ":")
            }
            guard let s = field("DTSTART"), let e = field("DTEND"),
                  let start = date(s), let end = date(e) else { return nil }
            return Booking(source: source, summary: field("SUMMARY") ?? "Unavailable", start: start, end: end)
        }
    }
    static func date(_ value: String) -> Date? {
        for format in ["yyyyMMdd'T'HHmmss'Z'", "yyyyMMdd'T'HHmmss", "yyyyMMdd"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let result = formatter.date(from: value) { return result }
        }
        return nil
    }
}

struct ContentView: View {
    @StateObject private var store = CalendarStore()
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Vacation Rental Calendar").font(.largeTitle.bold())
            Text("Import only • Airbnb cancellation blocks stay isolated").foregroundStyle(.secondary)
            ForEach(["Airbnb", "Vrbo", "Booking.com"], id: \.self) { platform in
                HStack {
                    Text(platform).frame(width: 105, alignment: .leading)
                    TextField("HTTPS iCal export URL", text: Binding(
                        get: { store.urls[platform] ?? "" },
                        set: { store.urls[platform] = $0 }
                    ))
                    Button("Import") { Task { await store.importFeed(platform) } }
                }
            }
            Text(store.message).font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Imported dates — review classifications").font(.headline)
            List {
                ForEach($store.events) { $event in
                    HStack {
                        VStack(alignment: .leading) {
                            Text("\(event.source): \(event.summary)")
                            Text("\(event.start.formatted(date: .abbreviated, time: .omitted)) – \(event.end.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker("Classification", selection: $event.classification) {
                            ForEach(Classification.allCases) { kind in Text(kind.rawValue).tag(kind) }
                        }.frame(width: 220)
                    }
                }
            }
            Text("Warning: imported iCal events do not reliably identify confirmed reservations versus penalty blocks. No automatic cross-platform blocking is enabled.")
                .font(.caption).foregroundStyle(.orange)
        }.padding(20).frame(minWidth: 850, minHeight: 570)
    }
}

@main struct VacationRentalCalendarApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
