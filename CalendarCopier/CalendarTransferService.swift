import Foundation
import Combine
import CryptoKit
import EventKit

/// Copies calendar events on-device. Exchange calendars are read-only sources;
/// only EventKit local calendars may receive copies.
@MainActor
final class CalendarTransferService: ObservableObject {
    @Published private(set) var sourceCalendars: [EKCalendar] = []
    @Published private(set) var destinationCalendars: [EKCalendar] = []
    @Published private(set) var permissionGranted = false
    @Published var statusMessage = "Grant calendar access to begin."
    @Published var isBusy = false
    @Published private(set) var previewCount = 0
    @Published private(set) var lastReport: TransferReport?

    private let store = EKEventStore()
    private let historyDirectoryName = "completed-occurrences"

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
            statusMessage = sourceCalendars.isEmpty
                ? "No local or Exchange source calendars were found."
                : (destinationCalendars.isEmpty
                    ? "No local destination calendar was found. Create an On My iPhone calendar in Calendar."
                    : "Choose a local or Exchange source and a local destination.")
        } catch {
            statusMessage = "Could not request calendar access: \(error.localizedDescription)"
        }
    }

    /// Exchange may be read as a source; only local calendars may receive copied data.
    func reloadCalendars() {
        let available = store.calendars(for: .event)
        sourceCalendars = available
            .filter { isAllowedSource($0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        destinationCalendars = available
            .filter { isLocalCalendar($0) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    func preview(source: EKCalendar?, destination: EKCalendar?) {
        guard validateLocalDestinationAndAllowedSource(source: source, destination: destination),
              let source else {
            previewCount = 0
            return
        }

        let (start, end) = transferDateBounds()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [source])
        previewCount = store.events(matching: predicate).count
        statusMessage = "\(previewCount) source events found in the supported date range."
    }

    func copyAllEvents(source: EKCalendar?, destination: EKCalendar?) async {
        guard validateLocalDestinationAndAllowedSource(source: source, destination: destination),
              let source, let destination else {
            return
        }

        guard source.calendarIdentifier != destination.calendarIdentifier else {
            statusMessage = "Choose two different calendars."
            return
        }

        guard destination.allowsContentModifications else {
            statusMessage = "The destination calendar is read-only. Choose a writable local calendar."
            return
        }

        // Prepare local duplicate history before creating any destination events.
        let historyDirectory: URL
        do {
            historyDirectory = try historyDirectoryURL()
        } catch {
            statusMessage = "Local duplicate-prevention storage is unavailable. No events were copied."
            return
        }

        isBusy = true
        lastReport = nil
        defer { isBusy = false }

        let (start, end) = transferDateBounds()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [source])
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        previewCount = events.count

        var copied = 0
        var skipped = 0
        var failed = 0
        var details: [String] = []
        var stoppedBecauseHistoryCouldNotBeSaved = false

        for (index, sourceEvent) in events.enumerated() {
            let key = occurrenceKey(
                event: sourceEvent,
                sourceCalendarID: source.calendarIdentifier,
                destinationCalendarID: destination.calendarIdentifier
            )
            let markerURL = historyDirectory.appendingPathComponent(key, isDirectory: false)

            if FileManager.default.fileExists(atPath: markerURL.path) {
                skipped += 1
                continue
            }

            let destinationEvent = makeCopy(of: sourceEvent, in: destination)

            do {
                // A local destination prevents this app from writing copied event
                // content to Exchange, iCloud, CalDAV, or another account provider.
                try store.save(destinationEvent, span: .thisEvent, commit: true)
                copied += 1
            } catch {
                failed += 1
                if details.count < 10 {
                    details.append("An event could not be copied: \(error.localizedDescription)")
                }
                continue
            }

            do {
                try saveCompletionMarker(at: markerURL)
            } catch {
                // The event has already been saved. Stop immediately because retrying
                // without a durable marker could create a duplicate next time.
                stoppedBecauseHistoryCouldNotBeSaved = true
                details.append("Stopped early: local duplicate-prevention history could not be saved. Check the destination before retrying.")
                break
            }

            if index % 25 == 0 {
                statusMessage = "Copying events… \(copied + skipped + failed) of \(events.count) processed."
                await Task.yield()
            }
        }

        lastReport = TransferReport(
            copied: copied,
            skipped: skipped,
            failed: failed,
            details: details
        )

        if stoppedBecauseHistoryCouldNotBeSaved {
            statusMessage = "Stopped after \(copied) copied. Check the destination before retrying; duplicate protection could not be updated."
        } else {
            statusMessage = "Finished. \(copied) copied, \(skipped) already copied, \(failed) failed."
        }
    }

    private func isLocalCalendar(_ calendar: EKCalendar) -> Bool {
        calendar.source.sourceType == .local
    }

    private func isAllowedSource(_ calendar: EKCalendar) -> Bool {
        calendar.source.sourceType == .local || calendar.source.sourceType == .exchange
    }

    @discardableResult
    private func validateLocalDestinationAndAllowedSource(
        source: EKCalendar?,
        destination: EKCalendar?
    ) -> Bool {
        guard let source, let destination else {
            statusMessage = "Choose both calendars."
            return false
        }
        guard isAllowedSource(source) else {
            statusMessage = "Only local or Exchange calendars can be used as sources."
            return false
        }
        guard isLocalCalendar(destination) else {
            statusMessage = "Privacy protection: copied events can only be saved to a calendar stored locally on this iPhone."
            return false
        }
        return true
    }

    private func makeCopy(of sourceEvent: EKEvent, in destination: EKCalendar) -> EKEvent {
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

        // Recurring source events are currently flattened to individual occurrences.
        destinationEvent.recurrenceRules = nil
        return destinationEvent
    }

    private func transferDateBounds() -> (Date, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let start = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1)) ?? .distantPast
        let end = calendar.date(from: DateComponents(year: 2101, month: 1, day: 1)) ?? .distantFuture
        return (start, end)
    }

    /// Hashes account/item identifiers plus the destination identifier. The cache
    /// contains no event titles, notes, locations, or URLs.
    private func occurrenceKey(
        event: EKEvent,
        sourceCalendarID: String,
        destinationCalendarID: String
    ) -> String {
        let itemID = event.calendarItemIdentifier
        let start = String(Int64(event.startDate.timeIntervalSince1970))
        let identity = "\(sourceCalendarID)|\(destinationCalendarID)|\(itemID)|\(start)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Caches are disposable and excluded from backup. If iOS purges this directory,
    /// duplicate prevention resets; the app will explain this limitation in its README.
    private func historyDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        guard let cachesDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw HistoryError.storageUnavailable
        }

        let directory = cachesDirectory.appendingPathComponent(
            historyDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)

        return directory
    }

    private func saveCompletionMarker(at url: URL) throws {
        // Empty hashed marker file: no event content is persisted by the app.
        try Data().write(to: url, options: [.atomic, .completeFileProtection])

        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private enum HistoryError: Error {
        case storageUnavailable
    }
}
