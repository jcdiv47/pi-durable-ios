# M0: capabilities on the personal team

Date: 2026-10-26. Xcode 27.0 (27A5252f), macOS 27.2.
Team: **P8FR4R7GEN, a free Personal Team** (`isFreeProvisioningTeam = 1`).
Device: iPhone Air (iPhone18,4) running **iOS 27.2** (24B115). Simulator: iPhone 17 Pro, iOS 26.5.

Run with `scripts/m0-check.sh capabilities` (add `PI_DEVICE=<udid>` for the phone). The app writes
`Documents/m0/capabilities.json`.

## Result: everything M0 needs works on the free team

| Capability | Provisioned (device profile) | Runtime check, device | Simulator |
|---|---|---|---|
| App Groups (`group.dev.jcdiv47.pidurable`) | yes, app + widget | container URL resolves; app writes `snapshots/m0.json`, the widget reads it | ok |
| HealthKit | yes (`healthkit`, `healthkit.access: health-records`, `background-delivery`) | available; `statusForAuthorizationRequest` = `shouldRequest` (no entitlement error) | ok |
| Keychain sharing | `keychain-access-groups: P8FR4R7GEN.*` | write/read/delete ok; default group `P8FR4R7GEN.dev.jcdiv47.pidurable.shared` | ok |
| Widget extension | yes, own profile (`dev.jcdiv47.pidurable.widgets`) | `PiWidgets.appex` embedded and installed | ok |
| Live Activities | Info.plist only (`NSSupportsLiveActivities`) | `areActivitiesEnabled` true; `Activity.request` succeeded, then ended | ok |
| Background modes (`fetch`, `processing`) | Info.plist only | `BGAppRefreshTaskRequest`, `BGProcessingTaskRequest` and iOS 26 `BGContinuedProcessingTaskRequest` (wildcard id `dev.jcdiv47.pidurable.run.*`) all **submitted** | all return `BGTaskSchedulerErrorDomain` 1 (unavailable): expected, the simulator has no BGTaskScheduler |

Xcode created the App IDs and the App Group with `-allowProvisioningUpdates`. No portal steps were needed.

## Caveats of the free team

- **Profiles expire after 7 days** (these expire 2026-11-02). The app stops launching until it is
  rebuilt and reinstalled from Xcode. Fine for development, poor for an agent that is meant to
  run unattended for weeks.
- Free teams are limited to a few App IDs per week and a few sideloaded apps per device. This
  project uses two App IDs (app + widget). A Watch app or more extensions add more.
- Not checked in M0, and known to be unavailable to free teams: **Push Notifications / APNs**.
  That rules out remote Live Activity updates and server-sent wakes. Local notifications,
  BGTaskScheduler and in-app Live Activity updates do work, and those are what the spec relies
  on. If M3 wants push, it needs a paid account.
- Notification permission was not requested (`authorizationStatus` 0 = not determined). That
  happens in M1 UI.

**Recommendation:** keep the free team through M1/M2. Switch to a paid account before relying on
weeks-long unattended use (7-day expiry) or on push.
