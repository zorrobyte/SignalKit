# Contributing

SignalKit is a Swift package for iOS sensor collection and durable transport. Contributions must keep the three library products independent of any particular app or server.

## Local setup

1. Install Xcode 26.5 or newer and select it with `xcode-select`.
2. Clone this repository. No accounts, backend services, device data, or secrets are required for package tests.
3. Run `Scripts/test-simulator.sh` to build every target, run all suites, and produce coverage and test-result artifacts.
4. Read the guide and API reference for the product you are changing. Storage format or replay changes also require the durability guide.

Use injectable drivers/readers for deterministic tests. Do not add test-only switches that disable the production algorithm. Tests must drive the same coordinator/engine/queue code as a host app; only native sensors and transport are substituted. Add a regression test before fixing a failure.

## Review checklist

- Public symbols have purpose, parameter/unit, lifecycle, and failure documentation.
- Examples compile as part of the test build. They do not require a hidden host project.
- New code has normal, boundary, failure, cancellation, and recovery cases where relevant.
- Test fixtures contain invented values only. Never attach real health data, routes, UUID mappings, account details, diagnostic logs, or simulator containers.
- Changes preserve FIFO lifecycle ordering, at-least-once delivery, and old stored payload decoding unless a migration is included.
- Coverage does not regress silently. Native framework adapters are reported separately, not mislabeled as device-tested.
- No application names, server SDKs, product IDs, App Group IDs, credentials, or analytics clients enter library targets.
- Run a Release build in addition to Debug tests. Document any new minimum SDK or OS requirement.

## Pull requests and releases

Keep PRs focused. Explain the changed contract, tests run, relevant coverage, and any real-device checks still outstanding. Public API and persisted-data changes need changelog/migration entries. Before tagging, run the public-release audit and all simulator checks. Never move a public version tag to new code.

Contributions are provided under the repository's MIT license. See [SECURITY.md](SECURITY.md) for vulnerability handling rather than posting sensitive repro data in an issue.
