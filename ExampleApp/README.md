# SignalKit Example

A host app that exercises all three products against a real database, with every
knob they expose wired to a control. One tab per module.

| Tab | What it shows |
| --- | --- |
| **Activity** | Engine phase, anchor, dwell, motion and permissions, plus tracking mode, rest threshold, high-accuracy GPS, home control, and manual outing start/end |
| **Health** | Reconciliation status, today's totals, and the metric selection — toggles per type, statistic pickers, and the calendar-day window |
| **Durable** | Both outboxes, upload and storage tuning, failure injection, database contents, and lifecycle control |
| **Log** | The injected `DiagnosticLog`. SignalKit records into it and never transmits it; the package default discards everything |

The app supplies storage, a metric selection, permission timing, and transport.
It owns no queue, no retry, and no batching — `ActivityTracker` and
`HealthSyncCoordinator` own those.

## Run it

The backend is Python standard library plus SQLite; nothing to install.

```bash
cd ExampleApp/server && python3 server.py 8787 &   # writes signalkit_demo.sqlite
open ../SignalKitExample.xcodeproj                  # set your team, then run
```

The Xcode project is checked in and consumes the package from `..`, so there is
nothing to resolve. It is generated from `project.yml`; if you change that file,
regenerate with [xcodegen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen && xcodegen generate`).

**Signing:** no team is checked in, and HealthKit needs one — even on the
simulator. Ad-hoc signing silently drops the entitlements
(`ENTITLEMENTS_ALLOWED=NO`) and HealthKit then reports *"Missing
com.apple.developer.healthkit entitlement"*. Select your team under Signing &
Capabilities, or pass `DEVELOPMENT_TEAM=XXXXXXXXXX` to `xcodebuild`. A free
personal team is enough.

The simulator ships no Health data, so **Health → Seed sample data** writes some
through plain HealthKit. SignalKit only ever reads.

## Simulating movement

The simulator does real GPS simulation, so the state machine can be exercised
properly — not just teleported between fixed points.

```bash
# Interpolated waypoints at a chosen speed, with a fix every 150 m
xcrun simctl location <udid> start --speed=25 --distance=150   37.3349,-122.0090 37.3650,-122.0500 37.4100,-122.1100

xcrun simctl location <udid> run "Freeway Drive"    # also: City Run, City Bicycle Ride
xcrun simctl location <udid> set 37.3349,-122.0090  # a single fix
xcrun simctl location <udid> clear
```

The same scenarios are in the Simulator's **Features → Location** menu.

Set home at your starting point first, then drive away from it: you will see the
home geofence exit open an outing, transit segments accumulate, max distance
climb, and a stop settle into a dwell. A route at 25 m/s makes the engine call
the outing `drive` on speed alone — CoreMotion reports nothing useful on a
simulator, and the engine is built not to depend on it.

### On a physical device

Set **Durable → Server → Host** to your Mac's LAN address (`192.168.x.x:8787`)
and add a matching ATS exception to `project.yml`, since the connection is
cleartext HTTP:

```yaml
NSAppTransportSecurity:
  NSAllowsLocalNetworking: true
  NSExceptionDomains:
    192.168.1.42:
      NSExceptionAllowsInsecureHTTPLoads: true
```

Rows are keyed by the **Account** field, so a device and a simulator can write to
the same database without colliding.

## Things worth trying

- **Prove durability.** Turn on *Durable → Simulate server outage*. Move the
  simulator's location around, or seed health data. Watch pending climb while the
  server 503s everything, then switch it off and drain: the same event ids are
  redelivered, and the server reports the duplicates it ignored.
- **Watch a rebuild preserve work.** Change a construction-time setting — the
  window length, batch size — and a banner appears. Rebuilding stops the
  coordinators and constructs new ones over the same directory; anything queued
  is still queued afterwards. This is the same stop-and-recreate the docs require
  before switching accounts.
- **See a metric selection reach HealthKit.** Toggle types on the Health tab,
  rebuild, then request access: the permission sheet lists exactly what you
  selected. HealthSync never asks for everything.
- **Break it on purpose.** Delete `UIBackgroundModes: location` from
  `project.yml` and the Activity tab reports background updates unavailable
  rather than crashing — the one host omission that otherwise fails silently.

## The backend

Two endpoints, both idempotent, because delivery is at-least-once:

- `POST /v1/health` upserts by `(account, date, type)` and **rejects a lower
  `recordedAt`**, so a replayed older revision cannot overwrite a newer total.
- `POST /v1/tracking` deduplicates on the client-generated event id.
- `POST /v1/admin/offline` returns 503 to every write — the failure injection.
- `POST /v1/status` records what the client reports about itself, so collection
  state is visible in the database and not only on screen.

Inspect it with `sqlite3 server/signalkit_demo.sqlite` or `GET /v1/stats`.

## What this does not prove

Simulated GPS covers a lot: geofence transitions, speed-driven regime changes,
segment accumulation, dwell detection, queue failure and replay, and the UI.

It does not cover CoreMotion — activity classification stays `unknown` on a
simulator, so walk-versus-drive decisions that depend on it are never exercised.
Nor does it cover real GPS accuracy and battery behavior, locked-device reads
(HealthKit refuses while the device is locked), or delivery to a suspended or
terminated app. Those need a physical device.
