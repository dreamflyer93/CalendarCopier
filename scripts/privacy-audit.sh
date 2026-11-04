#!/bin/bash
set -euo pipefail

# This is a regression guard for common networking and remote-logging APIs.
# It is not a mathematical proof that arbitrary native code cannot use sockets.
if grep -RInE --include='*.swift' \
  'import[[:space:]]+(Network|WebKit|CFNetwork|FoundationNetworking)|URLSession|URLRequest|NWConnection|NWListener|NWBrowser|CFStream|CFSocket|socket[[:space:]]*\\(|print[[:space:]]*\\(|NSLog[[:space:]]*\\(|os_log[[:space:]]*\\(|Logger[[:space:]]*\\(' \
  CalendarCopier; then
  echo "Privacy audit failed: a network or remote-logging API was found in app Swift sources." >&2
  exit 1
fi

for dependency_file in Package.swift Package.resolved Podfile Cartfile; do
  if [ -e "$dependency_file" ]; then
    echo "Privacy audit failed: unexpected third-party dependency manifest: $dependency_file" >&2
    exit 1
  fi
done

echo "Privacy source audit passed: no common networking or remote-logging APIs or third-party dependency manifests found."
