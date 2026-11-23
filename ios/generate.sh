#!/bin/bash
# Makes Halden.xcodeproj from project.yml (brew install xcodegen). Run after adding or moving
# files; CI checks that the committed project matches.
set -euo pipefail
cd "$(dirname "$0")"
xcodegen generate --quiet --spec project.yml
