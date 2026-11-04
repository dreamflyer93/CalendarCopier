import SwiftUI
import EventKit

struct ContentView: View {
    @StateObject private var service = CalendarTransferService()
    @State private var sourceID: String?
    @State private var destinationID: String?
    @State private var showingConfirmation = false

    private var sourceCalendar: EKCalendar? {
        service.calendars.first { $0.calendarIdentifier == sourceID }
    }

    private var destinationCalendar: EKCalendar? {
        service.calendars.first { $0.calendarIdentifier == destinationID }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label("Local-calendar-only transfer", systemImage: "iphone")
                    Text("Only calendars stored locally on this iPhone are listed. iCloud, Google, Exchange, CalDAV, and subscribed calendars are deliberately excluded.")
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
                    Section("Source calendar (local)") {
                        calendarPicker(selection: $sourceID, placeholder: "Choose source")
                    }

                    Section("Destination calendar (local)") {
                        calendarPicker(selection: $destinationID, placeholder: "Choose destination")
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
                            // Refresh the count immediately before the confirmation dialog;
                            // don't show a stale or zero count when the user skips Preview.
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
                            ForEach(Array(report.details.enumerated()), id: \.offset) { item in
                                Text(item.element)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Privacy") {
                    Text("This app contains no networking, analytics, advertising, remote logging, or third-party SDK code. It reads and writes only local EventKit calendars.")
                        .font(.footnote)
                    Text("iOS backups and background activity from other apps or accounts are controlled by iOS and are outside this app's control. For a strictly offline transfer, use Airplane Mode and make sure Wi-Fi is also off.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Status") {
                    Text(service.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if service.permissionGranted {
                        Button("Refresh local calendar list") {
                            service.reloadCalendars()
                            if !service.calendars.contains(where: { $0.calendarIdentifier == sourceID }) {
                                sourceID = nil
                            }
                            if !service.calendars.contains(where: { $0.calendarIdentifier == destinationID }) {
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
                Text("Events will be added only to \(destinationCalendar?.title ?? "the local destination calendar"). The source will remain unchanged. Recurring events are copied as individual occurrences.")
            }
        }
    }

    @ViewBuilder
    private func calendarPicker(selection: Binding<String?>, placeholder: String) -> some View {
        Picker(placeholder, selection: selection) {
            Text(placeholder).tag(String?.none)
            ForEach(service.calendars, id: \.calendarIdentifier) { calendar in
                Text(calendar.title)
                    .tag(Optional(calendar.calendarIdentifier))
            }
        }
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
