import SwiftUI
import EventKit

struct ContentView: View {
    @StateObject private var service = CalendarTransferService()
    @State private var sourceID: String?
    @State private var destinationID: String?
    @State private var showingConfirmation = false

    private var sourceCalendar: EKCalendar? {
        service.sourceCalendars.first { $0.calendarIdentifier == sourceID }
    }

    private var destinationCalendar: EKCalendar? {
        service.destinationCalendars.first { $0.calendarIdentifier == destinationID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Exchange source → local iPhone destination", systemImage: "iphone")
                    Text("You can read events from local or Exchange calendars. Copied events can be saved only to a calendar stored locally on this iPhone. Exchange is never used as a destination.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Original events are never changed or deleted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !service.permissionGranted {
                    Section("Get started") {
                        Button {
                            Task { await service.requestAccessAndLoadCalendars() }
                        } label: {
                            Label("Allow calendar access", systemImage: "lock.open")
                        }
                    }
                } else {
                    Section("Source calendar (local or Exchange)") {
                        Picker("Choose source", selection: $sourceID) {
                            Text("Choose source").tag(String?.none)
                            ForEach(service.sourceCalendars, id: \.calendarIdentifier) { calendar in
                                Text(sourceCalendarLabel(calendar))
                                    .tag(Optional(calendar.calendarIdentifier))
                            }
                        }
                    }

                    Section("Destination calendar (local only)") {
                        Picker("Choose destination", selection: $destinationID) {
                            Text("Choose destination").tag(String?.none)
                            ForEach(service.destinationCalendars, id: \.calendarIdentifier) { calendar in
                                Text(calendar.title)
                                    .tag(Optional(calendar.calendarIdentifier))
                            }
                        }
                    }

                    Section("Transfer") {
                        HStack {
                            Text("Events in source date range")
                            Spacer()
                            Text("\(service.previewCount)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }

                        Button {
                            service.preview(source: sourceCalendar, destination: destinationCalendar)
                        } label: {
                            Label("Preview transfer", systemImage: "list.magnifyingglass")
                        }
                        .disabled(sourceCalendar == nil || destinationCalendar == nil ||
                                  sourceID == destinationID || service.isBusy)

                        Button {
                            service.preview(source: sourceCalendar, destination: destinationCalendar)
                            showingConfirmation = true
                        } label: {
                            Label("Copy all events", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(sourceCalendar == nil || destinationCalendar == nil ||
                                  sourceID == destinationID || service.isBusy)
                    }

                    if service.isBusy {
                        Section {
                            ProgressView(service.statusMessage)
                        }
                    }

                    if let report = service.lastReport {
                        Section("Transfer report") {
                            reportRow("Copied", value: report.copied, color: .green)
                            reportRow("Already copied", value: report.skipped, color: .secondary)
                            reportRow("Failed", value: report.failed, color: .red)
                            reportRow("Recurring series copied", value: report.recurringSeriesCopied, color: .secondary)
                            reportRow("Modified occurrences preserved", value: report.detachedOccurrencesUpdated, color: .secondary)
                            reportRow("Source events scanned", value: report.eventsScanned, color: .secondary)
                            ForEach(Array(report.details.enumerated()), id: \.offset) { item in
                                Text(item.element)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Privacy") {
                    Text("This app contains no networking, analytics, advertising, remote logging, or third-party SDK code. It reads local and Exchange source calendars through EventKit, and writes copied events only to local iPhone calendars.")
                        .font(.footnote)
                    Text("Calendar queries run in the background in one-year windows using callback enumeration. The app does not hold the complete event range in memory.")
                        .font(.footnote)
                    Text("Attendees and the organiser cannot be recreated as live invitation participants with EventKit. Where iOS exposes them, their names, addresses, roles and RSVP states are copied as informational text into event notes. Provider-specific invitation metadata is not exposed by EventKit.")
                        .font(.footnote)
                    Text("Reading an Exchange calendar is performed through the iOS account integration. This app does not edit the Exchange source or send the copied events to Exchange. The iPhone and its account provider still control normal account synchronisation and device backups.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Status") {
                    Text(service.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if service.permissionGranted {
                        Button("Refresh calendar list") {
                            service.reloadCalendars()
                            if !service.sourceCalendars.contains(where: { $0.calendarIdentifier == sourceID }) {
                                sourceID = nil
                            }
                            if !service.destinationCalendars.contains(where: { $0.calendarIdentifier == destinationID }) {
                                destinationID = nil
                            }
                        }
                    }
                }
            }
            .navigationTitle("Calendar Copier")
            .confirmationDialog(
                "Copy \(service.previewCount) events?",
                isPresented: $showingConfirmation,
                titleVisibility: .visible
            ) {
                Button("Copy events", role: .none) {
                    Task {
                        await service.copyAllEvents(source: sourceCalendar, destination: destinationCalendar)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Events will be added only to \(destinationCalendar?.title ?? "the local destination calendar"). The source will remain unchanged. Recurrence rules are copied as series; modified occurrences are applied where EventKit exposes enough information. Invitation participants are copied as text, not as live invitees.")
            }
        }
    }

    private func sourceCalendarLabel(_ calendar: EKCalendar) -> String {
        let type = calendar.source.sourceType == .exchange ? "Exchange" : "On My iPhone"
        return "\(calendar.title) — \(type)"
    }

    private func reportRow(_ title: String, value: Int, color: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(value)")
                .monospacedDigit()
                .foregroundStyle(color)
        }
    }
}
