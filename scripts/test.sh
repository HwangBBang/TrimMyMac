#!/usr/bin/env bash
# Run swift test with the correct flags for CommandLineTools-only environments.
# Xcode.app makes Testing.framework visible automatically; CLT requires -F explicitly
# so that `#if canImport(Testing)` evaluates to true in the SPM-generated test runner.
#
# Usage:
#   ./scripts/test.sh [extra swift test arguments]
#   ./scripts/test.sh --filter ScaffoldSmokeTests
set -euo pipefail

CLT_FRAMEWORKS="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

exec swift test \
    -Xswiftc -F -Xswiftc "${CLT_FRAMEWORKS}" \
    "$@"
