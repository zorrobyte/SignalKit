# Changelog

## 0.2.0

- Initial public release of ActivityTracking, HealthSync, and DurableSync.
- Inject backend, storage, diagnostics, and presentation hooks.
- Add SDK-derived HealthKit catalog, configurable numeric metrics, native sample/change readers, and specialized-query access.
- Preserve seven-calendar-day default, deletion-safe reconciliation, durable value checkpoints, and bounded batched replay.
- Add 73 simulator tests spanning every module and compiled integration examples.
- Add injectable native drivers, API/lifecycle/migration references, coverage gates, and a public-source audit.
- Handle confirmed empty deletions when HealthKit returns its no-data error; coalesce concurrent health drains.
