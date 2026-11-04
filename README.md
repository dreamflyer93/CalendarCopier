# Calendar Copier

Native SwiftUI iPhone app that copies events between calendars exposed to iOS through EventKit. Original events remain untouched. Calendar data is processed locally on the iPhone; the project has no server or analytics.

## Build

The GitHub Actions workflow in `.github/workflows/build-unsigned-ipa.yml` builds an unsigned iOS app on a GitHub-hosted macOS runner and packages an unsigned IPA. This artifact is not installable until a local signing tool signs it with your Apple Account.

## Current limitations

- The app currently copies recurrence instances as standalone events, not the original recurrence series and exceptions.
- It scans 1 January 1900 through 1 January 2101.
- Attendees, organiser identity, RSVP state and provider-specific invitation metadata are not copied.
- Duplicate protection remembers copies created by this app; it does not detect similar events already in the destination calendar.
- Test with a small calendar before transferring an important calendar.
