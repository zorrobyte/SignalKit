# ActivityTracking integration

Retain one `LocationCoordinator` and one `MotionCoordinator` per active tracker. Construct them during app initialization so background location launches register a delegate promptly. Supply ordinary app defaults for settings and a separate defaults suite/App Group for durable engine state. In the default home-anchored mode the host chooses the home coordinate and can preserve/change it with the public coordinator APIs. Pass `mode: .roaming()` for users who work from the road and have no fixed home; see [Tracking modes](#tracking-modes).

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

## Tracking modes

`homeAnchored` (default) suits someone whose day is organized around leaving and returning to one place: an outing is the time away from the home geofence. `roaming` suits a truck driver, a traveling nurse, or anyone who wants all movement tracked without a home. There, an outing begins when the device departs (vehicle motion, a fast fix, or leaving the rest fence) and ends once a stop has lasted the rest threshold; that stop becomes the base for the next outing. Shorter stops are dwell segments inside the outing.

```swift
let location = LocationCoordinator(output: yourTrackingOutput, defaults: appDefaults,
    stateDefaults: trackingStateDefaults, motion: motion, mode: .roaming(restThreshold: 6 * 3600))
// A user setting can flip it later; any open outing ends first.
await location.setTrackingMode(.homeAnchored)
```

The rest threshold is evaluated lazily on every engine event and by a best-effort timer while the app is alive. Call `refreshTrackingState()` from a background refresh task or on foreground entry so a rest that completed while suspended is recognized promptly; otherwise the boundary is recognized at the next location or motion event. The first roaming outing may carry a nil `homeLat/homeLng` when no fix arrived before departure. Because the two modes never share an anchor, switching discards the roaming base; the host owns persisting the user's choice and passing it at the next launch.

## Start with ActivityTracker

`ActivityTracker` composes the whole stack: a `MotionCoordinator`, a
`LocationCoordinator`, and a `DurableTrackingOutput` writing
`tracking-events-v1.jsonl` in the directory you supply. Construct it with storage,
a defaults store, and an idempotent uploader; call `bootstrap()` at launch,
`onForeground()` on foreground entry, and `drainUploads()` on network recovery and
in a BGProcessing handler. `stop()` halts observation and retries while preserving
durable events for replay.

Assign presentation callbacks (`onSnapshot`, `onDistanceChanged`,
`onContextChanged`, `onStateChanged`, `onOutingEnded`, `onOutingCompleted`,
`onWake`) on the tracker. It installs its own handlers on `location` to drive the
outbox, so assigning them there instead silently stops uploads. Commands and
observable state that the tracker does not forward remain reachable on `location`
and `motion`.

Storage must be persistent and account-isolated — Application Support or an App
Group, never a temporary directory. Use one tracker and one directory per tracking
identity; pause or recreate it before changing accounts. Identity, storage-suite
choices, widgets, Live Activities, and notification policy remain in the host.

## Your own TrackingOutput implementation

Use `DurableTrackingOutput` directly for a different composition, or implement
`TrackingOutput`, which extends `ActivityBackend`, when the wire format has to be
yours. The engine supplies stable device-generated outing/segment IDs. Every callback should immediately write a durable local operation; do not wait for a server to create an ID before accepting the next event. `recordSample` and `recordHome` are synchronous local-sink calls. `flush()` is a bounded opportunity to send queued operations.

The host owns the Codable operation enum and maps it to its backend. `DurableWriteLog` provides storage/replay mechanics. Preserve FIFO lifecycle ordering and use the client IDs for idempotency. Surface storage failures; a sink that silently drops writes does not satisfy the contract.

`ActivityBackend` covers start/end session or outing, mode updates, maximum distance/record updates, segment start/end, dwell/place observation, and farthest-distance state. Server IDs returned by start/place methods are advisory and may be nil offline. All coordinates are degrees, distances/accuracy/altitude are meters, speeds are meters per second, and `LocationSample.timestamp` is Unix milliseconds. Dates in engine callbacks are native `Date` values.

`Examples/TrackingConfiguration.swift` is the buildable one-call setup. A custom
implementation must preserve the same guarantees `DurableTrackingOutput` provides:
FIFO lifecycle ordering, client IDs as the idempotency key, droppable samples but
never droppable lifecycle events, a bounded per-batch timeout, and storage errors
surfaced rather than swallowed.

## State machine and platform behavior

The engine serializes events, persists client identities before awaiting output callbacks, and reconciles home/dwell state on cold boot. States are at-home, transit, on-site, and a legacy session state. Continuous GPS is armed during transit and stopped during settled dwells. Motion and speed adjust sample cadence. Home and dwell region identifiers are currently `home` and `dwell`; reserve these in the host and run one tracker per process.

`EngineStateStore(defaults:)` uses `activityEngine.state.v2`. Give each account/tracker a separate defaults suite. CoreLocation callback timing, significant-change thresholds, motion availability, and terminated-app delivery are controlled by iOS. User force-quit and system restrictions can prevent delivery; this library cannot guarantee an always-running process.

Without the `location` background mode, `CoreLocationDriver` refuses to enable
background updates and `LocationCoordinator.backgroundUpdatesAvailable` is false:
collection then stops when the app is suspended. Setting it without the mode
raises an uncatchable Objective-C exception, so the driver declines the write
rather than terminating the host. Check the flag in a diagnostics screen; it is a
missing Info.plist entry, not a permission failure.

Required host setup: `NSLocationWhenInUseUsageDescription`, `NSLocationAlwaysAndWhenInUseUsageDescription`, `NSMotionUsageDescription`, a matching `NSLocationTemporaryUsageDescriptionDictionary` purpose key, and location background mode where continuous background tracking is used. Request Always and Precise access with an accurate explanation. The package cannot grant permissions or install entitlements for the host.

Callbacks `onDistanceChanged`, `onContextChanged`, `onOutingEnded`, and `onStateChanged` let hosts update their presentation. Their default behavior is no-op. No ActivityKit/WidgetKit/backend SDK dependencies are pulled into ActivityTracking.
