# Contributing

Contributions are welcome when they keep the repository useful as a readable reference
implementation.

## Development workflow

1. Read [CONTEXT.md](CONTEXT.md) before changing session, path, or latency terminology.
2. Keep machine-local runtime values under ignored paths; never commit TURN credentials or raw
   screen-capture evidence.
3. Add behavior tests for business logic, parsers, state machines, and public interfaces. Use build,
   lint, schema, and diff validation for mechanical configuration or documentation changes.
4. Run `make verify` before opening a pull request.
5. Use Conventional Commits for commit messages.

Environment-dependent Android TV E2E is documented separately in
[`docs/runbooks/android-tv-e2e.md`](docs/runbooks/android-tv-e2e.md). A pull request does not need to
repeat the full quantitative baseline unless it changes capture, encode, transport, decode, render,
clock calibration, or evidence analysis.

## Pull requests

Describe the user-visible or measurement contract, the alternatives considered for core design
changes, the commands actually run, and any validation that could not be performed. Avoid bundling
unrelated cleanup with behavior changes.
