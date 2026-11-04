#!/bin/bash
set -euo pipefail

# Static regression guard for common networking, web-view, analytics, and logging APIs.
# This is a guardrail, not a proof against deliberately obfuscated or indirect code.
for forbidden in \
  "URLSession" "URLRequest" "NWConnection" "NWListener" "NWBrowser" \
  "CFStream" "CFSocket" "NetworkExtension" "WKWebView" \
  "ASWebAuthenticationSession" "SFSafariViewController" \
  "Firebase" "Crashlytics" "Sentry" "AppsFlyer" "Amplitude" "Mixpanel" \
  "NSLog" "os_log" "Logger" "print(" "socket(" "connect(" \
  "import Network" "import WebKit" "import CFNetwork" "import FoundationNetworking"; do
  if grep -RInF --include='*.swift' "$forbidden" CalendarCopier; then
    echo "Privacy audit failed: found forbidden API or SDK marker: $forbidden" >&2
    exit 1
  fi
done

for dependency_file in Package.swift Package.resolved Podfile Cartfile; do
  if [ -e "$dependency_file" ]; then
    echo "Privacy audit failed: unexpected third-party dependency manifest: $dependency_file" >&2
    exit 1
  fi
done

if grep -nE 'XCRemoteSwiftPackageReference|XCSwiftPackageProductDependency|packageReferences' CalendarCopier.xcodeproj/project.pbxproj; then
  echo "Privacy audit failed: Xcode project declares a remote package dependency." >&2
  exit 1
fi

if ! grep -q 'sourceType == .exchange' CalendarCopier/CalendarTransferService.swift; then
  echo "Privacy audit failed: Exchange source support check is missing." >&2
  exit 1
fi

if ! grep -q 'sourceType == .local' CalendarCopier/CalendarTransferService.swift; then
  echo "Privacy audit failed: local destination restriction is missing." >&2
  exit 1
fi

echo "Privacy source audit passed: no common networking/analytics/logging APIs or remote dependencies found; Exchange is source-only and destinations are local."
