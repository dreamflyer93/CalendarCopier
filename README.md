# Calendar Copier

Native SwiftUI iPhone app that copies events between calendars stored locally on the iPhone using EventKit.

## Privacy model

- **Local calendars only.** The app filters both source and destination calendars to EventKit's `EKSourceType.local`. iCloud/CalDAV, Exchange, subscribed, and other non-local calendars are hidden and are also rejected again immediately before copying.
- **No app networking.** The app target has no network clients, analytics, advertising, remote logging, web views, third-party SDKs, or package dependencies. The app never opens event URLs; it only copies the URL field as event data.
- **No event content stored by the app.** Event contents are read from EventKit and written to the selected local destination calendar. The app's duplicate-prevention cache stores only SHA-256 hashes of source calendar/item identifiers and occurrence dates, not event titles, notes, locations, or URLs.
- **Local history cache.** Duplicate-prevention state is kept in the app's Caches directory, written atomically with complete file protection and marked excluded from backups. iOS can purge caches; if it does, duplicate-prevention history resets and a later run may create duplicates.
- **Privacy manifest.** The app declares no tracking and no collected data.

### Important boundary

This is an app-code privacy design, not a device-wide network firewall. The app does not control iOS backups, diagnostics, device-management software, or network activity from other apps and accounts. For the strongest offline transfer, enable Airplane Mode and also ensure Wi-Fi is off while copying. The app deliberately does not offer cloud calendars because EventKit writes to a provider-managed calendar may be synchronised by that provider.

The GitHub Actions workflow builds the app from source code. It does not receive calendar data from an iPhone; no calendar data is part of the repository or build artifact.

## Build

The GitHub Actions workflow in `.github/workflows/build-unsigned-ipa.yml` builds an unsigned iOS app on a GitHub-hosted macOS runner and packages an unsigned IPA. The artifact must be signed locally before installation.

## Current functional limitations

- Recurrence instances are copied as separate events, not as their original recurrence series and exceptions.
- The scan range is 1 January 1900 through 1 January 2101.
- Attendees, organiser identity, RSVP state, and provider-specific invitation metadata are not copied.
- Duplicate protection remembers successful copies by source occurrence. The cache can be purged by iOS, and it does not detect similar events already present in the destination.
- The app requests full EventKit calendar access because it must read source events and create destination events.
- Test with a small local calendar before transferring an important calendar.
