#!/bin/bash
# Compiles the SwiftUI-free AI engine + tactical test harness into a standalone
# macOS binary and runs it. No Xcode test target required.
set -e
cd "$(dirname "$0")"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
OUT="$(mktemp -d)/aitests"

xcrun swiftc -D DEBUG -sdk "$SDK" -target arm64-apple-macos13 -o "$OUT" \
    Tractor/Models/Card.swift \
    Tractor/Models/Player.swift \
    Tractor/Models/Deck.swift \
    Tractor/Models/GameState.swift \
    Tractor/Engine/CardComparator.swift \
    Tractor/Engine/TrickEvaluator.swift \
    Tractor/Engine/AIPlayer.swift \
    Tractor/Engine/AIPlayer+Lead.swift \
    Tractor/Engine/AIPlayer+Follow.swift \
    Tractor/Engine/AIPlayer+Scoring.swift \
    Tractor/Engine/AIPlayer+MonteCarlo.swift \
    Tractor/Engine/AIPlayer+Debug.swift \
    AITests/main.swift

"$OUT"
