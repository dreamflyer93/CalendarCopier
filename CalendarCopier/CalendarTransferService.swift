import Foundation
import Combine
import CryptoKit
import EventKit

/// Copies events only between calendars whose EventKit source is local to this device.
/// No networking, analytics, remote logging, or third-party SDKs are used by this target.
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
    private let historyFileName = "completed-occurrences.plist"

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
        guard validateLocalDestinationAndAllowedSource(source: source, destination: destination) else {
            previewCount = 0
            return
        }
        guard let source else {
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
            statusMessage = "Choose two different local calendars."
            return
        }

        guard destination.allowsContentModifications else {
            statusMessage = "The destination calendar is read-only. Choose a writable local calendar."
            return
        }

        isBusy = true
        lastReport = nil
        defer { isBusy = false }

        let (start, end) = transferDateBounds()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [source])
        let events = store.events(matching: predicate).sorted { $0.startDate < $1.startDate }
        previewCount = events.count

        var completed: Set<String>
        do {
            completed = try loadCompletedKeys()
        } catch {
            statusMessage = "The local duplicate-prevention history could not be read. No events were copied. Reinstalling or clearing app data may reset this history."
            return
        }

        var copied = 0
        var skipped = 0
        var failed = 0
        var details: [String] = []
        var stoppedBecauseHistoryCouldNotBeSaved = false

        for (index, sourceEvent) in events.enumerated() {
            let key = occurrenceKey(event: sourceEvent, sourceCalendarID: source.calendarIdentifier)
            if completed.contains(key) {
                skipped += 1
                continue
            }

            let destinationEvent = makeCopy(of: sourceEvent, in: destination)

            do {
                // Saving to a local source avoids writing event content to an iCloud,
                // Exchange, CalDAV, or other provider-managed calendar.
                try store.save(destinationEvent, span: .thisEvent, commit: true)
                copied += 1
            } catch {
                failed += 1
                if details.count < 10 {
                    details.append("An event could not be copied: \(error.localizedDescription)")
                }
                continue
            }

            completed.insert(key)
            do {
                // Persist after each event so an app interruption is less likely to
                // cause already-saved events to be copied again on the next run.
                try saveCompletedKeys(completed)
            } catch {
                stoppedBecauseHistoryCouldNotBeSaved = true
                details.append("Stopped early: the local duplicate-prevention history could not be saved. Check the destination before retrying.")
                break
            }

            if index % 25 == 0 {
                statusMessage = "Copying local events… \(copied + skipped + failed) of \(events.count) processed."
                await Task.yield()
            }
        }

        let report = TransferReport(
            copied: copied,
            skipped: skipped,
            failed: failed,
            details: details
        )
        lastReport = report

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
    private func validateLocalDestinationAndAllowedSource(source: EKCalendar?, destination: EKCalendar?) -> Bool {
        guard let source, let destination else {
            statusMessage = "Choose both calendars."
            return false
        }
        guard isAllowedSource(source) else {
            statusMessage = "Privacy protection: only local or Exchange calendars can be used as sources."
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

    /// Hashes identifiers before writing them to local app storage; no event text is stored here.
    private func occurrenceKey(event: EKEvent, sourceCalendarID: String) -> String {
        let itemID = event.calendarItemIdentifier
        let start = String(Int64(event.startDate.timeIntervalSince1970))
        let identity = "\(sourceCalendarID)|\(itemID)|\(start)"
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The Caches directory is used intentionally: this small, disposable ledger is not
    /// essential user data and should not be included in device backups. iOS may purge it,
    /// in which case duplicate suppression may reset.
    private func historyFileURL() throws -> URL {
        let fileManager = FileManager.default
        guard let cachesDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw HistoryError.storageUnavailable
        }

        let appCacheDirectory = cachesDirectory.appendingPathComponent(
            "CalendarCopier",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: appCacheDirectory,
            withIntermediateDirectories: true
        )

        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var mutableDirectoryURL = appCacheDirectory
        try mutableDirectoryURL.setResourceValues(directoryValues)

        return appCacheDirectory.appendingPathComponent(historyFileName)
    }

    private func loadCompletedKeys() throws -> Set<String> {
        let url = try historyFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return []
        }
        let data = try Data(contentsOf: url)
        let values = try PropertyListDecoder().decode([String].self, from: data)
        return Set(values)
    }

    private func saveCompletedKeys(_ keys: Set<String>) throws {
        let url = try historyFileURL()
        let data = try PropertyListEncoder().encode(keys.sorted())

        // Complete file protection makes the ledger inaccessible while the iPhone is locked.
        try data.write(to: url, options: [.atomic, .completeFileProtection])

        // Reapply after every write because atomic replacement may reset resource values.
        var fileValues = URLResourceValues()
        fileValues.isExcludedFromBackup = true
        var mutableFileURL = url
        try mutableFileURL.setResourceValues(fileValues)
    }

    private enum HistoryError: Error {
        case storageUnavailable
    }
}
