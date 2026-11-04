import Foundation
import Combine
import CryptoKit
import EventKit

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

    struct TransferReport: Sendable {
        let copied: Int
        let skipped: Int
        let failed: Int
        let recurringSeriesCopied: Int
        let detachedOccurrencesUpdated: Int
        let eventsScanned: Int
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
              let source, let destination else {
            previewCount = 0
            return
        }

        guard !isBusy else { return }
        isBusy = true
        statusMessage = "Counting source events in the background…"

        let worker = CalendarTransferWorker(
            sourceCalendarID: source.calendarIdentifier,
            destinationCalendarID: destination.calendarIdentifier
        )

        Task { @MainActor in
            defer { isBusy = false }
            do {
                let count = try await Task.detached(priority: .userInitiated) {
                    try worker.countEvents()
                }.value
                previewCount = count
                statusMessage = "\(count) source events found in the supported date range."
            } catch {
                previewCount = 0
                statusMessage = "Could not count source events: \(error.localizedDescription)"
            }
        }
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

        guard !isBusy else {
            statusMessage = "Please wait for the current preview or transfer to finish."
            return
        }

        isBusy = true
        lastReport = nil
        statusMessage = "Copying in the background. Events remain on this iPhone."
        defer { isBusy = false }

        let worker = CalendarTransferWorker(
            sourceCalendarID: source.calendarIdentifier,
            destinationCalendarID: destination.calendarIdentifier
        )

        do {
            let report = try await Task.detached(priority: .userInitiated) {
                try worker.copyEvents()
            }.value

            previewCount = report.eventsScanned
            lastReport = report
            statusMessage = "Finished. \(report.copied) copied, \(report.skipped) already copied, \(report.failed) failed."
        } catch {
            statusMessage = "Transfer stopped: \(error.localizedDescription)"
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
}

// EventKit's event queries are synchronous. This worker owns its own event store and
// runs in a detached task, so neither enumeration nor saving blocks the SwiftUI actor.
// It processes one calendar-year window at a time and uses callback enumeration;
// it never builds a calendar-wide [EKEvent] array.
private final class CalendarTransferWorker: @unchecked Sendable {
    private let sourceCalendarID: String
    private let destinationCalendarID: String
    private let historyDirectoryName = "completed-occurrences"

    init(sourceCalendarID: String, destinationCalendarID: String) {
        self.sourceCalendarID = sourceCalendarID
        self.destinationCalendarID = destinationCalendarID
    }

    private final class Counts {
        var copied = 0
        var skipped = 0
        var failed = 0
        var recurringSeriesCopied = 0
        var detachedOccurrencesUpdated = 0
        var eventsScanned = 0
        var seriesIdentifiersSeen: Set<String> = []
        var details: [String] = []

        func addDetail(_ detail: String) {
            if details.count < 20 {
                details.append(detail)
            }
        }
    }

    func countEvents() throws -> Int {
        let eventStore = EKEventStore()
        let (source, _) = try validatedCalendars(in: eventStore)
        let counts = Counts()

        enumerateDateRange(in: eventStore, source: source) { _ in
            counts.eventsScanned += 1
        }
        return counts.eventsScanned
    }

    func copyEvents() throws -> CalendarTransferService.TransferReport {
        let eventStore = EKEventStore()
        let (source, destination) = try validatedCalendars(in: eventStore)
        let historyDirectory = try historyDirectoryURL()
        let counts = Counts()

        enumerateDateRange(in: eventStore, source: source) { sourceEvent in
            counts.eventsScanned += 1
            autoreleasepool {
                do {
                    try self.process(
                        sourceEvent,
                        eventStore: eventStore,
                        destination: destination,
                        historyDirectory: historyDirectory,
                        counts: counts
                    )
                } catch {
                    counts.failed += 1
                    counts.addDetail("An event could not be copied: \(error.localizedDescription)")
                }
            }
        }

        return CalendarTransferService.TransferReport(
            copied: counts.copied,
            skipped: counts.skipped,
            failed: counts.failed,
            recurringSeriesCopied: counts.recurringSeriesCopied,
            detachedOccurrencesUpdated: counts.detachedOccurrencesUpdated,
            eventsScanned: counts.eventsScanned,
            details: counts.details
        )
    }

    private func validatedCalendars(in eventStore: EKEventStore) throws -> (EKCalendar, EKCalendar) {
        guard let source = eventStore.calendar(withIdentifier: sourceCalendarID),
              let destination = eventStore.calendar(withIdentifier: destinationCalendarID) else {
            throw WorkerError.calendarNoLongerAvailable
        }

        guard source.source.sourceType == .local || source.source.sourceType == .exchange else {
            throw WorkerError.sourceTypeNotAllowed
        }
        guard destination.source.sourceType == .local else {
            throw WorkerError.destinationMustBeLocal
        }
        guard source.calendarIdentifier != destination.calendarIdentifier else {
            throw WorkerError.sameCalendar
        }
        guard destination.allowsContentModifications else {
            throw WorkerError.destinationReadOnly
        }
        return (source, destination)
    }

    private func enumerateDateRange(
        in eventStore: EKEventStore,
        source: EKCalendar,
        using body: @escaping (EKEvent) -> Void
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current

        var cursor = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1))!
        let overallEnd = calendar.date(from: DateComponents(year: 2101, month: 1, day: 1))!

        while cursor < overallEnd {
            let nextYear = calendar.date(byAdding: .year, value: 1, to: cursor) ?? overallEnd
            let windowEnd = min(nextYear, overallEnd)
            let predicate = eventStore.predicateForEvents(
                withStart: cursor,
                end: windowEnd,
                calendars: [source]
            )

            eventStore.enumerateEvents(matching: predicate) { event, _ in
                body(event)
            }

            cursor = windowEnd
        }
    }

    private func process(
        _ sourceEvent: EKEvent,
        eventStore: EKEventStore,
        destination: EKCalendar,
        historyDirectory: URL,
        counts: Counts
    ) throws {
        // Apple's event(withIdentifier:) returns the first occurrence for a recurring
        // item. That gives us the original series anchor date rather than rebasing its
        // recurrence rule on whichever occurrence happened to be enumerated first.
        let masterEvent: EKEvent
        if let firstOccurrence = eventStore.calendarItem(withIdentifier: sourceEvent.calendarItemIdentifier) as? EKEvent {
            masterEvent = firstOccurrence
        } else {
            masterEvent = sourceEvent
        }

        if masterEvent.recurrenceRules?.isEmpty == false {
            try processRecurringSeries(
                sourceOccurrence: sourceEvent,
                masterEvent: masterEvent,
                eventStore: eventStore,
                destination: destination,
                historyDirectory: historyDirectory,
                counts: counts
            )
        } else {
            try processSingleEvent(
                sourceEvent,
                eventStore: eventStore,
                destination: destination,
                historyDirectory: historyDirectory,
                counts: counts
            )
        }
    }

    private func processRecurringSeries(
        sourceOccurrence: EKEvent,
        masterEvent: EKEvent,
        eventStore: EKEventStore,
        destination: EKCalendar,
        historyDirectory: URL,
        counts: Counts
    ) throws {
        guard let recurrenceRules = masterEvent.recurrenceRules, !recurrenceRules.isEmpty else {
            throw WorkerError.recurrenceRuleUnavailable
        }

        let seriesIdentifier = masterEvent.calendarItemIdentifier

        let seriesMarker = markerURL(
            kind: "series",
            identity: "\(sourceCalendarID)|\(destinationCalendarID)|\(seriesIdentifier)",
            directory: historyDirectory
        )

        let firstOccurrenceSeenThisRun = counts.seriesIdentifiersSeen.insert(seriesIdentifier).inserted
        if firstOccurrenceSeenThisRun {
            if FileManager.default.fileExists(atPath: seriesMarker.path) {
                counts.skipped += 1
            } else {
                let destinationSeries = makeCopy(of: masterEvent, in: destination, eventStore: eventStore)
                destinationSeries.recurrenceRules = recurrenceRules
                try eventStore.save(destinationSeries, span: .thisEvent, commit: true)
                try writeCompletionMarker(at: seriesMarker)
                counts.copied += 1
                counts.recurringSeriesCopied += 1
            }
        }

        // A detached occurrence is an edited exception to the repeating series.
        // Apply its changed values to the matching occurrence of the newly-created
        // local series, instead of creating a second unrelated event.
        if sourceOccurrence.isDetached {
            try applyDetachedOccurrence(
                sourceOccurrence,
                seriesIdentifier: seriesIdentifier,
                eventStore: eventStore,
                destination: destination,
                historyDirectory: historyDirectory,
                counts: counts
            )
        }
    }

    private func applyDetachedOccurrence(
        _ sourceOccurrence: EKEvent,
        seriesIdentifier: String,
        eventStore: EKEventStore,
        destination: EKCalendar,
        historyDirectory: URL,
        counts: Counts
    ) throws {
        guard let originalOccurrenceDate = sourceOccurrence.occurrenceDate else {
            throw WorkerError.detachedOccurrenceDateUnavailable
        }

        let identity = "\(sourceCalendarID)|\(destinationCalendarID)|\(seriesIdentifier)|\(Int64(originalOccurrenceDate.timeIntervalSince1970))"
        let marker = markerURL(kind: "exception", identity: identity, directory: historyDirectory)
        if FileManager.default.fileExists(atPath: marker.path) {
            counts.skipped += 1
            return
        }

        // Query a small window around the original recurrence date, then compare
        // occurrenceDate because the exception's actual startDate may have moved.
        let searchStart = originalOccurrenceDate.addingTimeInterval(-86_400)
        let searchEnd = originalOccurrenceDate.addingTimeInterval(172_800)
        let predicate = eventStore.predicateForEvents(
            withStart: searchStart,
            end: searchEnd,
            calendars: [destination]
        )

        var matchingDestinationOccurrence: EKEvent?
        eventStore.enumerateEvents(matching: predicate) { candidate, stop in
            guard let candidateOccurrenceDate = candidate.occurrenceDate else { return }
            if abs(candidateOccurrenceDate.timeIntervalSince(originalOccurrenceDate)) < 1 {
                matchingDestinationOccurrence = candidate
                stop.pointee = true
            }
        }

        guard let destinationOccurrence = matchingDestinationOccurrence else {
            throw WorkerError.destinationOccurrenceNotFound
        }

        if sourceOccurrence.status == .canceled {
            try eventStore.remove(destinationOccurrence, span: .thisEvent, commit: true)
        } else {
            copyMutableFields(from: sourceOccurrence, to: destinationOccurrence)
            try eventStore.save(destinationOccurrence, span: .thisEvent, commit: true)
        }

        try writeCompletionMarker(at: marker)
        counts.detachedOccurrencesUpdated += 1
    }

    private func processSingleEvent(
        _ sourceEvent: EKEvent,
        eventStore: EKEventStore,
        destination: EKCalendar,
        historyDirectory: URL,
        counts: Counts
    ) throws {
        let itemIdentifier = sourceEvent.calendarItemIdentifier
        let start = Int64(sourceEvent.startDate.timeIntervalSince1970)
        let identity = "\(sourceCalendarID)|\(destinationCalendarID)|\(itemIdentifier)|\(start)"
        let marker = markerURL(kind: "single", identity: identity, directory: historyDirectory)

        if FileManager.default.fileExists(atPath: marker.path) {
            counts.skipped += 1
            return
        }

        let destinationEvent = makeCopy(of: sourceEvent, in: destination, eventStore: eventStore)
        try eventStore.save(destinationEvent, span: .thisEvent, commit: true)
        try writeCompletionMarker(at: marker)
        counts.copied += 1
    }

    private func makeCopy(of source: EKEvent, in destination: EKCalendar, eventStore: EKEventStore) -> EKEvent {
        let copy = EKEvent(eventStore: eventStore)
        copy.calendar = destination
        copyMutableFields(from: source, to: copy)
        copy.recurrenceRules = source.recurrenceRules
        return copy
    }

    private func copyMutableFields(from source: EKEvent, to destination: EKEvent) {
        destination.title = source.title
        destination.startDate = source.startDate
        destination.endDate = source.endDate
        destination.isAllDay = source.isAllDay
        destination.timeZone = source.timeZone
        destination.location = source.location
        destination.notes = notesIncludingInvitationSnapshot(from: source)
        destination.url = source.url
        destination.availability = source.availability
        destination.alarms = source.alarms?.map { alarm in
            if let absoluteDate = alarm.absoluteDate {
                return EKAlarm(absoluteDate: absoluteDate)
            }
            return EKAlarm(relativeOffset: alarm.relativeOffset)
        }
    }

    /// EventKit exposes invitation participants as read-only objects. Since it cannot
    /// add attendees to a new event, retain the exposed names, addresses, roles, RSVP
    /// states, and organizer as a clearly labelled text snapshot in local notes.
    /// This is informative only; it does not create live invitees or transfer ownership.
    private func notesIncludingInvitationSnapshot(from event: EKEvent) -> String? {
        var lines: [String] = []
        if let organizer = event.organizer {
            lines.append("Organizer: \(participantDescription(organizer))")
        }
        if let attendees = event.attendees, !attendees.isEmpty {
            lines.append("Attendees:")
            for attendee in attendees {
                lines.append("• \(participantDescription(attendee))")
            }
        }
        switch event.status {
        case .confirmed: lines.append("Source event status: confirmed")
        case .tentative: lines.append("Source event status: tentative")
        case .canceled: lines.append("Source event status: canceled")
        case .none: break
        @unknown default: break
        }

        let originalNotes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lines.isEmpty else {
            return originalNotes?.isEmpty == false ? originalNotes : nil
        }

        let snapshot = """
        Invitation details copied as text only (not live invitees):
        \(lines.joined(separator: "\n"))
        """

        if let originalNotes, !originalNotes.isEmpty {
            return originalNotes + "\n\n" + snapshot
        }
        return snapshot
    }

    private func participantDescription(_ participant: EKParticipant) -> String {
        var components: [String] = []
        if let name = participant.name, !name.isEmpty {
            components.append(name)
        }
        let address = participant.url.absoluteString
        if !address.isEmpty {
            components.append(address)
        }
        components.append(roleDescription(participant.participantRole))
        components.append(statusDescription(participant.participantStatus))
        if participant.isCurrentUser {
            components.append("this account")
        }
        return components.joined(separator: " — ")
    }

    private func roleDescription(_ role: EKParticipantRole) -> String {
        switch role {
        case .required: return "Required"
        case .optional: return "Optional"
        case .chair: return "Chair"
        case .nonParticipant: return "Non-participant"
        case .unknown: return "Role unknown"
        @unknown default: return "Role unknown"
        }
    }

    private func statusDescription(_ status: EKParticipantStatus) -> String {
        switch status {
        case .pending: return "Pending"
        case .accepted: return "Accepted"
        case .declined: return "Declined"
        case .tentative: return "Tentative"
        case .delegated: return "Delegated"
        case .completed: return "Completed"
        case .inProcess: return "In progress"
        case .unknown: return "Status unknown"
        @unknown default: return "Status unknown"
        }
    }

    private func transferDateRange() -> (Date, Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let start = calendar.date(from: DateComponents(year: 1900, month: 1, day: 1))!
        let end = calendar.date(from: DateComponents(year: 2101, month: 1, day: 1))!
        return (start, end)
    }

    private func historyDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        guard let cachesDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            throw WorkerError.historyStorageUnavailable
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

    private func markerURL(kind: String, identity: String, directory: URL) -> URL {
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appendingPathComponent("\(kind)-\(digest).done")
    }

    private func writeCompletionMarker(at url: URL) throws {
        try Data().write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }

    private enum WorkerError: LocalizedError {
        case calendarNoLongerAvailable
        case sourceTypeNotAllowed
        case destinationMustBeLocal
        case sameCalendar
        case destinationReadOnly
        case recurrenceRuleUnavailable
        case detachedOccurrenceDateUnavailable
        case destinationOccurrenceNotFound
        case historyStorageUnavailable

        var errorDescription: String? {
            switch self {
            case .calendarNoLongerAvailable: return "One of the selected calendars is no longer available."
            case .sourceTypeNotAllowed: return "The source must be a local or Exchange calendar."
            case .destinationMustBeLocal: return "The destination must be stored locally on this iPhone."
            case .sameCalendar: return "Choose two different calendars."
            case .destinationReadOnly: return "The local destination calendar is read-only."
            case .recurrenceRuleUnavailable: return "The recurring event's rule could not be read."
            case .detachedOccurrenceDateUnavailable: return "A modified occurrence did not provide its original recurrence date."
            case .destinationOccurrenceNotFound: return "A matching occurrence could not be found in the copied local series."
            case .historyStorageUnavailable: return "Local duplicate-prevention storage is unavailable."
            }
        }
    }
}

