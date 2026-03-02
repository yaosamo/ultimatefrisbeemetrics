# UltimateFrisbeeMetric

UltimateFrisbeeMetric is a watchOS training app for ultimate frisbee players. It uses Apple Watch motion sensors to estimate:

- throws performed during a drill
- throw family: `forehand`, `backhand`, `hammer`
- throw power: `short` or `long`
- recent session history
- synced live/session metrics in the iPhone companion app

## What It Does

The watch app samples `CMDeviceMotion` and applies a heuristics-based detector:

- a throw is inferred from a high wrist rotation burst combined with strong user acceleration
- once a throw peak is found, the app waits for a short release window and classifies throw family
- after family classification, it classifies throw power as `short` or `long`
- a cooldown prevents one movement from being counted multiple times

This is a training prototype, not a game-officiating system. Thresholds are intentionally data-driven and should be updated as more labeled recordings are collected.

## Business Logic

### 1. Throw Detection

Live throw detection happens in `UltimateFrisbeeMetric Watch App/ThrowDetectionEngine.swift`.

A movement becomes a throw candidate when all of these are true:

- total rotation magnitude is at least `7.8`
- total user acceleration magnitude is at least `1.35`
- at least `0.75s` passed since the previous counted throw

When that happens, the app records the peak time and uses a release window:

- `0.10s` before peak
- `0.25s` after peak

Classification is based on that window, not a single frame.

### 2. Wrist Normalization

The app has a `Watch Wrist` setting:

- `Left`
- `Right`

Some signed sensor values are flipped for the right wrist so equivalent throws can map into a shared internal frame.

Right now that normalization is applied to:

- `rotationRate.z`
- `userAcceleration.y`

The current thresholds were learned from left-handed, left-wrist sample data, so right-handed players should still be validated with their own recordings.

### 3. Family Classification

The current live family classifier runs in this order:

1. `Hammer`
2. `Forehand`
3. fallback to `Backhand`

Current rules:

- `Hammer`
  - if release-window `mean_gravity_y < 0.10`
- `Forehand`
  - if normalized release-window `mean_accel_y > 0.30`
  - and normalized post-release `mean rotationRate.z > 2.0`
- `Backhand`
  - anything not classified as `Hammer` or `Forehand`

Why this shape:

- `Hammer` is mainly an orientation-plane problem
- `Forehand` vs `Backhand` is mainly a sweep-direction plus follow-through problem

### 4. Power Classification

After family is known, the app classifies `short` vs `long`.

Current thresholds:

- `Forehand`
  - `long` if normalized post-release `mean rotationRate.z >= 7.0`
  - otherwise `short`
- `Backhand`
  - `long` if peak acceleration magnitude `>= 7.0`
  - otherwise `short`
- `Hammer`
  - `long` if release-window `mean_gravity_z >= -0.35`
  - otherwise `short`

These thresholds came from the current labeled dataset and should be expected to move as more players are recorded.

### 5. Session Metrics

The watch stores and syncs:

- total throws
- family totals
- per-family short/long totals
- session wrist used for that recording

Examples:

- forehand count
- forehand short / forehand long
- backhand count
- backhand short / backhand long
- hammer count
- hammer short / hammer long

## Project Structure

- `UltimateFrisbeeMetric.xcodeproj`: Xcode project
- `UltimateFrisbeeMetric Watch App/`: watchOS SwiftUI app target
- `UltimateFrisbeeMetric iPhone App/`: iPhone companion target
- `UltimateFrisbeeMetric Shared/`: shared session/live metric models
- `scripts/`: Mac-side sample analysis scripts

## Run

1. Open `UltimateFrisbeeMetric.xcodeproj` in Xcode.
2. Select the `UltimateFrisbeeMetric Watch App` scheme to run on Apple Watch.
3. Select the `UltimateFrisbeeMetric iPhone App` scheme to run the companion app.
4. Start a training session from the watch main screen.

## Motion Sample Analysis

1. Record labeled motion sessions on the watch from the `Sampling` section.
2. Available labels:
   - `Backhand Short`
   - `Backhand Long`
   - `Forehand Short`
   - `Forehand Long`
   - `Hammer Short`
   - `Hammer Long`
3. Use long recordings and perform many repetitions during each recording.
4. In Xcode, tap `Print All Samples JSON` and copy the export between `[SampleExport] BEGIN` and `[SampleExport] END` into a file such as `samples.json`.
5. Run:

```bash
python3 scripts/analyze_motion_samples.py samples.json
```

The script accepts either:

- the raw JSON export
- or a full Xcode console log containing one or more export marker blocks

The script does all of this:

- segments likely throws from long recordings
- groups labels into families: `forehand`, `backhand`, `hammer`
- keeps `short` / `long` as power variants
- prints per-family feature summaries
- prints by-power summaries
- prints sweep-direction candidates for `forehand` vs `backhand`
- prints orientation candidates for `hammer`

This script is the source of truth for tuning thresholds before changing the watch classifier.

## Current Assumptions

- the watch is worn on the throwing hand
- the current thresholds were tuned from left-handed recordings
- `Forehand` and `Backhand` are defined mostly by lateral arm sweep and wrist follow-through
- `Hammer` is defined more by orientation and upward release plane
- `Short` vs `Long` means same family pattern, different intensity

## Sensor Notes

`CoreMotion` is available on Apple Watch, but realistic throw classification needs testing on physical hardware. Simulator runs are useful for UI and data flow, not for validating motion thresholds.

## Next Improvements

1. Tune thresholds with more right-handed data and decide whether handedness needs its own setting.
2. Improve hammer gating with more gravity/orientation samples.
3. Add per-player calibration and confidence scoring.
4. Improve the iPhone companion app with charts and per-session detail views.
