# ActivityTracking integration

Retain one `LocationCoordinator` and one `MotionCoordinator` per active tracker. Construct them during app initialization so background location launches register a delegate promptly. Supply ordinary app defaults for settings and a separate defaults suite/App Group for durable engine state. The host chooses the home coordinate and can preserve/change it with the public coordinator APIs.

```swift
let motion = MotionCoordinator() // diagnostics default to no-op
let location = LocationCoordinator(
    output: yourTrackingOutput,
    defaults: appDefaults,
    stateDefaults: trackingStateDefaults,
    motion: motion,
    precisePurposeKey: "preciseForOuting"
)
location.onSnapshot = { /* write your widget snapshot */ }
location.onOutingCompleted = { id, date in /* app-specific completion */ }
location.onWake = { /* optional app wake maintenance */ }
location.bootstrap()
// From a user-facing permissions flow:
location.requestAuthorization()
```

## Your TrackingOutput implementation

Implement `TrackingOutput`, which extends `ActivityBackend`. The engine supplies stable device-generated outing/segment IDs. Every callback should immediately write a durable local operation; do not wait for a server to create an ID before accepting the next event. `recordSample` and `recordHome` are synchronous local-sink calls. `flush()` is a bounded opportunity to send queued operations.

The host owns the Codable operation enum and maps it to its backend. `DurableWriteLog` provides storage/replay mechanics. Preserve FIFO lifecycle ordering and use the client IDs for idempotency. Surface storage failures; a sink that silently drops writes does not satisfy the contract.

`ActivityBackend` covers start/end session or outing, mode updates, maximum distance/record updates, segment start/end, dwell/place observation, and farthest-distance state. Server IDs returned by start/place methods are advisory and may be nil offline. All coordinates are degrees, distances/accuracy/altitude are meters, speeds are meters per second, and `LocationSample.timestamp` is Unix milliseconds. Dates in engine callbacks are native `Date` values.

The buildable `Examples/OfflineTrackingOutput.swift` demonstrates a standalone durable adapter. Identity, storage-suite choices, widgets, Live Activities, and notification policy remain in the host.

## State machine and platform behavior

The engine serializes events, persists client identities before awaiting output callbacks, and reconciles home/dwell state on cold boot. States are at-home, transit, on-site, and a legacy session state. Continuous GPS is armed during transit and stopped during settled dwells. Motion and speed adjust sample cadence. Home and dwell region identifiers are currently `home` and `dwell`; reserve these in the host and run one tracker per process.

`EngineStateStore(defaults:)` uses `activityEngine.state.v2`. Give each account/tracker a separate defaults suite. CoreLocation callback timing, significant-change thresholds, motion availability, and terminated-app delivery are controlled by iOS. User force-quit and system restrictions can prevent delivery; this library cannot guarantee an always-running process.

Required host setup: `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSMotionUsageDescription`, a matching `NSLocationTemporaryUsageDescriptionDictionary` purpose key, and location background mode where continuous background tracking is used. Request Always and Precise access with an accurate explanation. The package cannot grant permissions or install entitlements for the host.

Callbacks `onDistanceChanged`, `onContextChanged`, `onOutingEnded`, and `onStateChanged` let hosts update their presentation. Their default behavior is no-op. No ActivityKit/WidgetKit/backend SDK dependencies are pulled into ActivityTracking.
