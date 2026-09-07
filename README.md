# SignalKit

Three Swift packages for collecting location, motion, and health data on iOS —
and actually getting it to your server, without losing any of it when the phone
goes offline, gets force-quit, or reboots mid-trip.

No dependencies. No backend SDK. It never sees your credentials and never uploads
anything itself: you hand it a closure that talks to your server, and it decides
what to send and when to retry.

## Why this is harder than it looks

- **The phone stops your app whenever it wants.** iOS suspends and kills apps
  constantly. Anything held in memory is gone. Every event here is on disk before
  a network call is attempted, so a crash mid-drive resumes the same outing
  instead of starting a second one.
- **Health data changes after the fact.** A watch syncs three hours late and
  yesterday's step count moves. You delete a workout and a day's calories drop.
  Uploading "today's totals" once is wrong; you have to notice what *changed*.
- **You will deliver things twice.** A dropped acknowledgement is
  indistinguishable from a failure, so anything durable is at-least-once. That's
  a constraint on your backend, and it's better to know now than after a user has
  four copies of one trip.

## The three products

### `ActivityTracking` — where has this person been?

Watches CoreLocation and CoreMotion and works out, on its own, when a trip
started and ended. Home-anchored (leaving home starts an outing, coming back ends
it) or roaming (driving starts one, a long stop ends one) for people with no
fixed home. It knows walking from driving and samples GPS accordingly — dense in
a car, sparse when parked — and it keeps its state machine on disk so a cold
launch from a background wake resumes correctly.

Out comes a stream of events: outing started, segment started, a GPS fix, you
stopped here, outing ended.

### `HealthSync` — what did their body do today?

You pick the metrics. It handles permission, registers observers so it wakes when
new samples land, and produces one number per day per metric.

The work is in the corrections. It journals what it has seen, re-uploads only the
days whose numbers actually moved, and refuses to zero out a day just because it
sees nothing — "no data" and "permission denied" are deliberately identical in
Apple's API, so it requires real evidence of deletion first.

### `DurableSync` — the reason nothing gets lost

An append-only log with one rule: an entry is removed only after your uploader
returns successfully. Crash, lose signal, force-quit — it's still there next
launch. It replays in order, in batches, with a timeout so one hung request can't
wedge the queue. When it fills up it drops the oldest raw *samples* and never the
lifecycle events, because a missing GPS point is a gap and a missing "outing
ended" is a corrupt record.

## Install

```swift
.package(url: "https://github.com/zorrobyte/SignalKit.git", from: "0.5.0")
```

Then add the products you need — `ActivityTracking`, `HealthSync`, `DurableSync`
— to your target. iOS 17+; build with Xcode 26.5+ for the current HealthKit
catalog. MIT.

## Quick start

Both entry points take a persistent directory and an upload closure, and are
retained for the life of the process. Return from the closure only once your
server has acknowledged; throw and the work stays queued.

```swift
import ActivityTracking
import HealthKit
import HealthSync

tracker = ActivityTracker(storageDirectory: directory, defaults: .standard) { events in
    try await api.send(events)          // [TrackingEvent]
}

health = HealthSyncCoordinator(storageDirectory: directory, defaults: .standard, metrics: [
    .quantity(HKQuantityType(.stepCount), unit: .count(), id: "steps"),
    .quantity(HKQuantityType(.heartRate), unit: .count().unitDivided(by: .minute()),
              id: "heart_rate", statistic: .average),
]) { totals in
    try await api.send(totals)          // [HealthAggregate]
}

tracker.bootstrap()                     // at launch
health.bootstrap()
```

Then: `requestAuthorization()` from a user action, `onForeground()` /
`syncRecent()` on foreground entry, and `drainUploads()` on network recovery and
in your background handler.

Assign presentation callbacks (`onSnapshot`, `onOutingCompleted`, …) on the
tracker itself, **not** on `tracker.location` — the tracker wires those to drive
its outbox, and replacing them silently stops uploads.

Storage must be persistent and per-account: Application Support or an App Group,
never a temporary directory.

## What your server has to do

Two rules, both consequences of at-least-once delivery:

- **Deduplicate tracking events on `TrackingEvent.id`.** It's generated on device
  before any network call and survives retries and restarts.
- **Upsert health totals by (account, date, type), and reject a lower
  `recordedAt`.** A replayed older revision must not overwrite a newer one.

Get these wrong and replays corrupt data instead of being harmless. The
[durability contract](Documentation/DurableSync.md) spells out what the queue
guarantees and what it leaves to you.

## Host setup you can't skip

The package cannot install these for you, and two of them fail *silently*.

| You need | Or else |
| --- | --- |
| `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSMotionUsageDescription` | Permission requests crash or are refused |
| `NSLocationTemporaryUsageDescriptionDictionary` with your precise-purpose key (default `preciseForOuting`) | Precise-accuracy escalation does nothing |
| `UIBackgroundModes: location` | Tracking stops when the app suspends. `backgroundUpdatesAvailable` reports false; nothing else tells you |
| `NSHealthShareUsageDescription` + the HealthKit entitlement | HealthKit authorization fails |
| `com.apple.developer.healthkit.background-delivery` | Observers never register. `healthBackgroundEnabledTypes` stays 0 with no other symptom |

## What it deliberately doesn't do

Identity and accounts, your server API and schema, widgets, Live Activities,
notifications, medical interpretation, or choosing which health types to request.
Those are yours. Logging is opt-in through an injected `DiagnosticLog` that
discards everything by default; the package never transmits logs.

## Limits worth knowing

- A supported HealthKit type doesn't mean data exists or that read permission was
  granted. Apple hides read-denial on purpose — empty and denied look the same.
- Not every HealthKit object is a daily number. ECG waveforms, routes, clinical
  documents and the like need Apple's specialized APIs, reachable through
  `reader.store`; you define how they're exported.
- Daily summaries are seven **calendar** days including today, not a rolling 168
  hours. Configurable.
- The simulator's GPS simulation does exercise the engine — geofences, speed
  regimes, dwells — but CoreMotion classification stays unknown there, and
  locked-device reads, real GPS accuracy, battery cost, and delivery to a
  suspended or terminated app still need a physical device.

## Documentation

- Integration guides: [ActivityTracking](Documentation/ActivityTracking.md),
  [HealthKit coverage](Documentation/HealthKit.md),
  [durability contract](Documentation/DurableSync.md)
- API reference: [ActivityTracking](Documentation/API/ActivityTracking.md),
  [HealthSync](Documentation/API/HealthSync.md),
  [DurableSync](Documentation/API/DurableSync.md)
- Operations: [lifecycle and failure handling](Documentation/Lifecycle.md),
  [storage and migration](Documentation/Migration.md),
  [test matrix and device limits](Documentation/Testing.md),
  [releases](Documentation/Development.md)
- Buildable examples: [tracking](Examples/TrackingConfiguration.swift),
  [health](Examples/HealthConfiguration.swift)
- [Example app](ExampleApp/README.md): one tab per product, every knob wired to a
  control, and a SQLite backend that enforces the two idempotency rules above

[LICENSE](LICENSE) · [CONTRIBUTING.md](CONTRIBUTING.md) · [SECURITY.md](SECURITY.md)
