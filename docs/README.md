# Documentation

This index separates stable reference documentation from historical implementation records.

## Runbooks

- [Local development](runbooks/local-development.md): toolchain, build, CLI, and diagnostics.
- [Runtime configuration](runbooks/runtime-configuration.md): WS/WSS, Direct, and TURN/UDP fields.
- [Android TV E2E](runbooks/android-tv-e2e.md): authoritative functional and quantitative runner.
- [macOS capture permission](runbooks/macos-capture-permission.md): Screen Recording and display
  lifecycle recovery.
- [Signaling server](runbooks/signaling-server.md): local execution, deployment, and metrics.
- [Single-Mac macOS E2E](runbooks/single-mac-e2e.md): legacy two-process comparison path.

## Architecture decisions

- [ADR-0001: private API for the virtual extended display](adr/0001-use-private-api-for-virtual-extended-display.md)
- [ADR-0002: Java Views for the Android TV reference receiver](adr/0002-use-java-views-for-android-tv-reference-receiver.md)
- [Domain vocabulary](../CONTEXT.md)

## Research and design records

- [Initial feasibility research](research/2026-07-13-feasibility-baseline.md)
- [macOS Sender → Android TV Receiver research](research/2026-07-15-macos-sender-android-tv-receiver.md)
- [Cross-platform receiver design](superpowers/specs/2026-07-16-macos-sender-android-tv-receiver-design.md)
- [Cross-platform implementation and evidence plan](superpowers/plans/2026-07-16-macos-sender-android-tv-receiver.md)

Files under `docs/superpowers/` are retained as historical design and execution evidence. Current
setup instructions live in the runbooks and root README.

## Follow-ups

- [Content-aware capture efficiency](follow-ups/content-aware-capture-efficiency.md)
- [Apple low-latency rate control](follow-ups/apple-low-latency-rate-control.md)
