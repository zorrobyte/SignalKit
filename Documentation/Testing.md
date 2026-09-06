# Testing and verification

Run `bash Scripts/test-simulator.sh` from a checkout with Xcode 26.5+, Node.js, and jq. Set `SIMULATOR_ID` to select an installed iPhone simulator and `RESULT_ROOT` to an empty artifact directory. The script audits source/documentation, runs every library and example test with coverage, enforces regression floors, builds Release, and compiles every target in the Swift 6 language mode with complete concurrency checking and warnings treated as errors. It requires no server or credentials. CI runs the same command on macOS 26.

## Test matrix

| Target | Deterministic coverage |
| --- | --- |
| DurableSync | FIFO and bounded batches, duplicate replay, append during drain, concurrent drains, corrupt/truncated files, disk read/write/ack failures, recovery, soft cap, compaction policy validation, retry budgets, cancellation, noncooperative timeouts |
| ActivityTracking | Engine outing/segment/dwell transitions, region entry/exit reconciliation, duplicate events, manual lifecycle, motion states/noise, sampling policy, fresh/stale/inaccurate location filters, thinning, persisted home/state repair, permission states, location request success/error/timeout, background session ownership, roaming departures/rests/base adoption and runtime mode switching |
| HealthSync | Seven-day and configurable windows, DST, changed-only checkpoints, relaunch, empty visibility versus confirmed deletions, locked-store recovery, observer ownership/completion, anchored pagination, metric units/statistics, merged intervals, invalid values, outbox expiry/compaction/batching/failures, status persistence, SDK catalog |
| SignalKitExamples | Public API compilation, complete tracking event encoding, durable reopen and ordered upload, explicit HealthSync construction without permission side effects |

Tests exercise production coordinators with injected native drivers and transports. They do not replace the queue, engine, or reconciliation algorithm. Fixtures are synthetic and isolated in temporary storage/UserDefaults suites. Parameterized cases can make Xcode's execution count larger than its test-definition count.

## Coverage policy

All source files, including native adapters, remain in the reported denominator. CI enforces these line-coverage floors:

| Module | Floor |
| --- | ---: |
| DurableSync | 97% |
| ActivityTracking | 91% |
| HealthSync | 81% |
| Compiled examples | 95% |

Additional file floors cover the write log, engine, location/motion coordinators, health coordinator, and upload pipeline. Inspect `Scripts/check-coverage.mjs` for exact values. The generated `coverage.json` and `.xcresult` are evidence for each run, not committed user data. Coverage measures executed lines, not proof of all possible behavior.

The September 6, 2026 release-candidate simulator run (iOS 26.5, Xcode 26.5) passed 73 test definitions: DurableSync 97.99%, ActivityTracking 92.10%, HealthSync 81.92%, and example implementations 100%. Examples are a non-product target statically linked into ExampleTests; their coverage counts only implementation files, not test source. Refer to CI artifacts for each subsequent run. Native CoreLocation/CoreMotion/HealthKit forwarding adapters have low or zero runtime coverage; their real sensor behavior is **not verified** by these percentages.

## Physical-device release validation still required

- Grant, deny, revoke, and change precise/Always permissions. Verify that empty HealthKit reads do not erase server values without deletion evidence.
- Collect real steps, daylight, workouts, sleep, visits, motion, and region transitions. Check supported types on the oldest deployed OS as well as the newest.
- Lock the phone during reads; unlock and verify catch-up. Test low-power mode, background refresh disabled, and OS-terminated wakes. User force-quit is a separate platform limitation.
- Stay offline, restart the app, restore connectivity, and verify replay and server deduplication. Simulate low storage without destroying real health data.
- Measure multi-hour battery use and background task expiration. Verify no observer completion or background session leaks.

The simulator suite is an automated release gate, not certification of hardware collection or battery behavior. A host app must also test its uploader, identity boundaries, entitlements, lifecycle wiring, and UI against a pinned package version.
