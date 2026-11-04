# Calendar Copier

Native SwiftUI iPhone app that copies calendar events locally using EventKit.

## Privacy model

- **Exchange is source-only.** You may choose a local calendar or an Exchange calendar as the source. The app filters and re-checks the source type before every operation.
- **Destination is local-only.** The destination picker lists only EventKit's local source calendars (typically shown as “On My iPhone”). The transfer service re-checks the destination type immediately before saving. Exchange, iCloud/CalDAV, Google/CalDAV, subscribed, and other provider-backed calendars cannot be destinations.
- **No app networking.** The app target contains no network clients, analytics, advertising, remote logging, web views, third-party SDKs, or package dependencies. It does not open event URLs; it copies the URL field as data only.
- **No event content stored in the app's own files.** The app reads source events via EventKit and creates the copies directly in the local destination calendar. Its duplicate-prevention cache contains only empty marker files named with SHA-256 hashes of identifiers; event titles, notes, locations, URLs, and other event content are not written to the app's cache.
- **Protected local cache.** Duplicate markers use complete file protection and are excluded from backups. They are stored in Caches, which iOS may purge. If purged, duplicate prevention resets and a future transfer may create duplicates.
- **Privacy manifest.** The app declares no tracking and no collected data.

### What “local-only destination” can and cannot guarantee

This prevents this app from saving copied events into an Exchange or other cloud-backed calendar. It does **not** turn the iPhone into a device-wide network-isolated system. Exchange data is made available by the iOS Exchange account integration; iOS and the Exchange provider control normal account synchronisation. Device backups, diagnostics, device-management software, and other apps are also outside this app's control. For a strictly offline copy operation, enable Airplane Mode and also ensure Wi-Fi is off; Exchange events must already be available on the device for this to work offline.

The GitHub Actions workflow builds the source code only. It does not receive calendar data from the iPhone; no calendar data is part of the repository or build artifact.

## Build

The GitHub Actions workflow in `.github/workflows/build-unsigned-ipa.yml` builds an unsigned iOS app on a GitHub-hosted macOS runner and packages an unsigned IPA. The artifact must be signed locally before installation.

## Functional limitations

- Recurrence instances are copied as separate events, not as their original recurrence series and exceptions.
- The scan range is 1 January 1900 through 1 January 2101.
- Attendees, organiser identity, RSVP state, and provider-specific invitation metadata are not copied.
- Duplicate protection remembers successful source occurrences per destination using hashed marker filenames. Its cache is disposable and does not detect similar events already present in the destination. A force-quit or system interruption in the very small interval after EventKit saves an event but before its marker is written can still cause that one event to be copied again on retry.
- The app requests full EventKit calendar access because it must read source events and create destination events.
- Event fetching currently materialises the full date-range result in memory; very large calendars may take time or consume substantial memory.
- Test with a small calendar before transferring an important calendar.
