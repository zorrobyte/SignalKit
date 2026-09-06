# Development and releases

## Run on simulator

```sh
xcodebuild -scheme SignalKit-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

Run from the repository root with Xcode 26.5+ selected. Tests use injected clocks, fake tracking controls/backends, temporary queue files, and isolated journals/checkpoints. No backend deployment or credentials are needed. The catalog test compares generated entries against native HealthKit types on the simulator.

The standalone examples compile as package targets and have their own integration tests. Before a release, run every package suite with coverage and build the Release configuration. Consuming apps should add their own integration suite against a pinned released version. Simulator tests do not certify sensor collection, Health permissions on real data, locked-device retries, battery behavior, or terminated-app wakes. Those require a subsequent physical-device pass.

## Update the HealthKit catalog

`Scripts/generate-health-catalog.mjs` reads public `HKTypeIdentifiers.h` and `HKClinicalType.h` from the selected Xcode's iphoneos SDK (or a `Headers` directory passed as the first argument), then prints an apply_patch patch for `HealthTypeCatalog+Generated.swift`; pass `--write` to update the file directly. Review the generated diff, update specialized factories in `HealthTypeCatalog.swift`, and test on the oldest supported OS and newest simulator available. New identifiers added after the shipped SDK need regeneration or explicit `additional` types. Do not introduce private APIs or runtime class scraping.

## Package boundaries

No app singletons, backend SDKs, IDs, credentials, product strings, WidgetKit, or ActivityKit belong in these targets. Inject services and storage. New behaviors need deterministic tests for offline replay, cancellation, out-of-space handling, and upgrade compatibility. Keep payload/schema decisions in the consumer.

## Versioning

Use semantic version tags, starting at `0.2.0`. Changes to public APIs, stored formats, queue semantics, and identifiers require migration notes. Commit package changes separately from consumers, run tests, then tag/push the package. Update the consumer's package reference and resolved version in its own change. Do not publish real health/location fixtures, logs, credentials, or simulator containers.

The project is MIT-licensed. Public releases must pass the source/history privacy audit and must not contain host-specific names or configuration.
