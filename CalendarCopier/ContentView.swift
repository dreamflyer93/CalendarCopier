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
                    Label("Copy events between calendars on this iPhone.", systemImage: "calendar.badge.arrow.2")
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
                    Section("Source calendar") {
                        calendarPicker(selection: $sourceID, placeholder: "Choose source")
                    }

                    Section("Destination calendar") {
                        calendarPicker(selection: $destinationID, placeholder: "Choose destination")
                    }

                    Section("Transfer") {
                        HStack {
                            Text("Events found")
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
                                Text(item.element).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Status") {
                    Text(service.statusMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if service.permissionGranted {
                        Button("Refresh calendar list") { service.reloadCalendars() }
                    }
                }

                Section {
                    Text("Calendar Copier processes events locally on this iPhone. It does not upload calendar contents to a server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
                Text("Events will be added to \(destinationCalendar?.title ?? "the destination calendar"). Your source calendar will remain unchanged. Recurring events are copied as individual occurrences.")
            }
        }
    }

    @ViewBuilder
    private func calendarPicker(selection: Binding<String?>, placeholder: String) -> some View {
        Picker(placeholder, selection: selection) {
            Text(placeholder).tag(String?.none)
            ForEach(service.calendars, id: \.calendarIdentifier) { calendar in
                Text("\(calendar.title) — \(calendar.source.title)")
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
