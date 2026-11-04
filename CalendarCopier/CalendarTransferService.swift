import Foundation
import Combine
import EventKit

@MainActor
final class CalendarTransferService: ObservableObject {
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var permissionGranted = false
    @Published var statusMessage = "Grant calendar access to begin."
    @Published var isBusy = false
    @Published private(set) var previewCount = 0
    @Published private(set) var lastReport: TransferReport?

    private let store = EKEventStore()
    private let defaultsKey = "CalendarCopier.completedSourceOccurrences.v1"

    struct TransferReport {
        let copied: Int
        let skipped: Int
        let failed: Int
        let details: [String]
    }

    func requestAccessAndLoadCalendars() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            permissionGranted = granted
            guard granted else {
                statusMessage = "Calendar access was not granted. Enable it in Settings to use Calendar Copier."
                return
            }
            reloadCalendars()
            statusMessage = calendars.isEmpty
                ? "No calendars were found. Add an account in iPhone Settings > Calendar > Accounts."
                : "Choose a source and destination calendar."
        } catch {
            statusMessage = "Could not request calendar access: \(error.localizedDescription)"
        }
    }

    func reloadCalendars() {
        calendars = store.calendars(for: .event).sorted {
            if $0.source.title == $1.source.title {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return $0.source.title.localizedCaseInsensitiveCompare($1.source.title) == .orderedAscending
        }
    }

    func preview(source: EKCalendar?, destination: EKCalendar?) {
        guard let source, let destination, source.calendarIdentifier != destination.calendarIdentifier else {
            previewCount = 0
            return
        }
        let (start, end) = transferDateBounds()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [source])
        previewCount = store.events(matching: predicate).count
    }

    func copyAllEvents(source: EKCalendar?, destination: EKCalendar?) async {
        guard let source, let destination else {
            statusMessage = "Choose both calendars."
            return
        }
        guard source.calendarIdentifier != destination.calendarIdentifier else {
            statusMessage = "Choose two different calendars."
            return
        }
        guard destination.allowsContentModifications else {
            statusMessage = "The destination calendar is read-only. Choose a writable calendar."
            return
        }

        isBusy = true
        lastReport = nil
        defer { isBusy = false }

        let (start, end) = transferDateBounds()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [source])
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }

        var completed = loadCompletedKeys()
        var copied = 0
        var skipped = 0
        var failed = 0
        var details: [String] = []

        for (index, sourceEvent) in events.enumerated() {
            let key = occurrenceKey(event: sourceEvent, sourceCalendarID: source.calendarIdentifier)
            if completed.contains(key) {
                skipped += 1
                continue
            }

            let destinationEvent = EKEvent(eventStore: store)
            destinationEvent.calendar = destination
            destinationEvent.title = sourceEvent.title
            destinationEvent.startDate = sourceEvent.startDate
            destinationEvent.endDate = sourceEvent.endDate
            destinationEvent.isAllDay = sourceEvent.isAllDay
            destinationEvent.timeZone = sourceEvent.timeZone
            destinationEvent.location = sourceEvent.location
            destinationEvent.notes = sourceEvent.notes
            destinationEvent.url = sourceEvent.url
            destinationEvent.availability = sourceEvent.availability
            destinationEvent.alarms = sourceEvent.alarms?.map { alarm in
                if let absoluteDate = alarm.absoluteDate {
                    return EKAlarm(absoluteDate: absoluteDate)
                }
                return EKAlarm(relativeOffset: alarm.relativeOffset)
            }

            // Recurring events are flattened to individual occurrences for this MVP.
            destinationEvent.recurrenceRules = nil

            do {
                try store.save(destinationEvent, span: .thisEvent, commit: true)
                completed.insert(key)
                copied += 1
            } catch {
                failed += 1
                if details.count < 20 {
                    details.append("\(sourceEvent.title ?? "Untitled"): \(error.localizedDescription)")
                }
            }

            if index % 50 == 0 {
                statusMessage = "Copying \(index + 1) of \(events.count)…"
                await Task.yield()
            }
        }

        saveCompletedKeys(completed)
        let report = TransferReport(copied: copied, skipped: skipped, failed: failed, details: details)
        lastReport = report
        statusMessage = "Finished. \(copied) copied, \(skipped) already copied, \(failed) failed."
    }

    private func transferDateBounds() -> (Date, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let start = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1)) ?? .distantPast
        let end = calendar.date(from: DateComponents(year: 2101, month: 1, day: 1)) ?? .distantFuture
        return (start, end)
    }

    private func occurrenceKey(event: EKEvent, sourceCalendarID: String) -> String {
        let itemID = event.calendarItemIdentifier
        let start = Int(event.startDate.timeIntervalSince1970)
        return "\(sourceCalendarID)|\(itemID)|\(start)"
    }

    private func loadCompletedKeys() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
    }

    private func saveCompletedKeys(_ keys: Set<String>) {
        UserDefaults.standard.set(Array(keys), forKey: defaultsKey)
    }
}
