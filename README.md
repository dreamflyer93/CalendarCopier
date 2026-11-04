# Calendar Copier

Native SwiftUI iPhone app that copies calendar events locally using EventKit.

## Privacy model

- **Exchange is source-only.** You may choose a local calendar or an Exchange calendar as the source. The app filters and re-checks the source type before every operation.
- **Destination is local-only.** The destination picker lists only EventKit's local source calendars (typically shown as “On My iPhone”). The transfer service re-checks the destination type immediately before saving. Exchange, iCloud/CalDAV, Google/CalDAV, subscribed, and other provider-backed calendars cannot be destinations.
- **No app networking.** The app target contains no network clients, analytics, advertising, remote logging, web views, third-party SDKs, or package dependencies. It does not open event URLs; it copies the URL field as data only.
- **No event content stored in the app's own files.** Event contents are read from EventKit and written directly to the local destination calendar. The duplicate-prevention cache contains only empty marker files named with SHA-256 hashes of identifiers; event titles, notes, locations, URLs, and other event content are not written to the app's cache.
- **Protected local cache.** Duplicate markers use complete file protection and are excluded from backups. They are stored in Caches, which iOS may purge. If purged, duplicate prevention resets and a future transfer may create duplicates.
- **Privacy manifest.** The app declares no tracking and no collected data.

### What “local-only destination” can and cannot guarantee

This prevents this app from saving copied events into an Exchange or other cloud-backed calendar. It does **not** turn the iPhone into a device-wide network-isolated system. Exchange data is made available by the iOS Exchange account integration; iOS and the Exchange provider control normal account synchronisation. Device backups, diagnostics, device-management software, and other apps are also outside this app's control. For a strictly offline copy operation, enable Airplane Mode and also ensure Wi-Fi is off; Exchange events must already be available on the device for this to work offline.

The GitHub Actions workflow builds source code only. It does not receive calendar data from an iPhone; no calendar data is part of the repository or build artifact.

## Copy behaviour and limitations

- **Recurring series:** the app copies the recurrence rules and original first-occurrence date so the destination receives a repeating series rather than a set of unrelated events.
- **Modified recurrence occurrences:** when EventKit exposes a detached occurrence and its original recurrence date, the app finds the corresponding destination occurrence and applies the source changes to that single occurrence. Some provider-specific cancelled/deleted exceptions may not be exposed by EventKit and therefore cannot be reproduced.
- **Attendees and organiser:** EventKit exposes these as read-only participant objects and explicitly does not allow an app to add or modify participants. Where exposed by iOS, the app copies participant names, participant addresses, roles, RSVP states, and the organiser into the event notes as an informational snapshot. These are **not live invitees**, do not preserve meeting ownership, and do not send or recreate invitations.
- **Provider-specific invitation metadata:** EventKit does not expose the raw Exchange invitation payload or all provider metadata, so those details cannot be copied with this offline/local-only design.
- The supported query range is 1 January 1900 through 1 January 2101. The app scans it one calendar year at a time using EventKit callback enumeration on a background task. It does not build one array containing every event across the whole range.
- Duplicate protection remembers successful copies per destination. Its cache is disposable and does not detect similar events already present in the destination. A force-quit in the small interval after saving an event but before its marker is written could still cause that event to be copied again on retry.
- The app requests full EventKit calendar access because it must read source events and create destination events.
- Test with a small local calendar before transferring an important calendar.
