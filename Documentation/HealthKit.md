# HealthKit coverage and configuration

## Catalog, permission, and visible data are different

`HealthTypeCatalog.available()` resolves the public SDK's identifier registry against the running OS. It covers quantity, category, characteristic, correlation, document, workout, activity summary, audiogram, ECG, series, vision prescription, state of mind, scored assessment, and medication families. Clinical records are opt-in with `includeClinicalRecords: true` because the host needs additional entitlement/configuration.

The generated registry comes from public Xcode SDK headers, with per-identifier iOS availability checks. It is not private reflection and cannot automatically invent types Apple adds in a future SDK. Pass native types in `additional:` immediately; regenerate the catalog when upgrading Xcode. Unsupported old-OS identifiers are skipped. Specialized factory additions are maintained in `HealthTypeCatalog.swift`.

```swift
let catalog = HealthTypeCatalog.available()
let quantityChoices = catalog.filter { $0.family == .quantity }
// Present choices, then request only the person's selected types:
let selected: Set<HKObjectType> = [HKQuantityType(.heartRate)]
let reader = HealthDataReader()
try await reader.requestAuthorization(read: selected)
```

Do not automatically request the entire catalog in a consuming app. A type being in the catalog means its API is supported, not that hardware/region/features are enabled. Empty samples can mean no visible data or denied access. Successful authorization means the request completed, not that every read was granted. `authorizationStatus(for:)` is not a read-permission check.

`Entry.requiresPerObjectAuthorization` flags types requiring Apple's per-object authorization flow. The reader rejects these in a bulk request; the host must use the native flow on `reader.store`. Entitlements and purpose strings also remain the host's responsibility.

## Daily numeric metrics

- `HealthMetric.quantity`: any compatible quantity/unit. Automatic statistics use a sum for cumulative quantities and an average for discrete quantities. Explicit minimum/maximum/average are supported for discrete types; invalid combinations throw rather than silently returning a wrong total.
- `HealthMetric.categoryDuration`: clip intervals to the day and merge overlaps before summing minutes. Supply explicit category values for sleep stages. Not every category represents a meaningful duration, so use custom metrics for ordinal/event categories.
- `HealthMetric.init`: a custom async native query, stable metric ID, unit, and read types. `sampleTypes` drives observer/change reconciliation. `additionalReadTypes` requests non-sample types needed by the query. Non-sample metrics refresh on explicit/foreground sync, not a sample observer.

Returning `nil` means no visible value and does not overwrite server data. Returning `0` explicitly exports zero. Set `deletionType` only when deleting every known sample for that type/day legitimately makes the metric zero. Unknown deleted UUIDs and ordinary empty reads never justify clearing a prior value. Finite values are required. Changing a metric's definition should use a new metric ID or an explicit checkpoint migration.

## Full-fidelity and nonnumeric access

The package has no numeric-only type whitelist. `samples(type:interval:strictStart:limit:)` returns native `HKSample` subclasses, retaining quantities, category values, workout fields, correlations, and specialized sample metadata. Its default 10,000-record limit is a **limit**, not a claim that the entire result set fits. Use bounded `changes` pages for large exports; use `HKObjectQueryNoLimit` only for deliberately bounded queries.

`changes(type:interval:anchor:limit:)` returns added native samples, deleted UUIDs, the next anchor, and `hasMore`. Use it only for sample types supporting anchored queries. Keep a fixed predicate for each anchor, durably enqueue the payload before persisting its anchor, and reset anchors when changing the predicate/window. A full page needs a subsequent query. Filter expired data again before upload if an outbox may survive beyond its window.

The underlying `reader.store` is public for Apple's specialized query paths:

| Data | Native access/export responsibility |
| --- | --- |
| Characteristics | HKHealthStore characteristic methods, e.g. date of birth; no sample observer |
| ECG | Sample metadata plus HKElectrocardiogramQuery voltage measurements |
| Workout routes / heartbeat series | HKWorkoutRouteQuery / HKHeartbeatSeriesQuery |
| Activity summaries | HKActivitySummaryQuery |
| Clinical / CDA records | Native clinical/document queries; preserve document formats and extra entitlements |
| Vision, state of mind, assessments, medications | Native specialized objects/queries; OS availability and authorization requirements apply |

The daily aggregate uploader deliberately does not pretend these objects are scalar totals. Hosts exporting them define Codable payloads and can use `DurableWriteLog<Payload>` for offline transport. `HealthAggregate` is specifically the daily numeric contract: `date`, `type`, `value`, `unit`, and `recordedAt` (Unix milliseconds).

## Sync guarantees

The change journal persists anchors, sample UUID-to-day mappings, deletion evidence, and pending reconciliation together. Collection scans bounded 500-object pages with an eight-second between-page budget. It yields and schedules continuation for more pages. This budget does not forcibly terminate a running native query.

Each reconciliation pass batches changed totals into a dedicated durable outbox before checkpointing values or acknowledging dirty dates. The uploader compacts obsolete totals, expires dates outside the configured window, uploads at most 49 adjacent records per batch, and checkpoints acknowledgement only after the host closure returns successfully. Backend upserts should key on account/date/type and reject older `recordedAt` values. A timeout may race a late server success, so retries must be safe.

Health database lock errors stop the pass until unlock/foreground. Other errors schedule retry. Background delivery is best effort, not a schedule guarantee. Storage failures remain visible and cannot be treated as success.

## Host setup

Enable HealthKit and, for observer delivery, its background-delivery entitlement. Provide `NSHealthShareUsageDescription`. Health Records need their dedicated access entitlement and usage/required-record configuration. Supply any purpose strings required for additional native flows. Request only data the app genuinely uses and keep the user-facing explanation accurate. The package never writes samples to HealthKit.

References: [Apple data types](https://developer.apple.com/documentation/healthkit/data-types), [authorization](https://developer.apple.com/documentation/healthkit/authorizing-access-to-health-data), [HealthKit setup](https://developer.apple.com/documentation/healthkit/setting-up-healthkit), and the public headers in Xcode's HealthKit SDK.
