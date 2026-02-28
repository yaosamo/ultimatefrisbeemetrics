# UltimateFrisbeeMetric

UltimateFrisbeeMetric is a minimal watchOS training app for ultimate frisbee players. It uses Apple Watch motion sensors to estimate:

- throws performed during a drill
- catches completed after a throw
- live catch rate for the current session
- recent session history for repeat training

## What it does

The watch app samples `CMDeviceMotion` and applies a simple heuristics-based detector:

- a throw is inferred from a high wrist rotation burst combined with strong user acceleration
- a catch is inferred when a short impact-like event arrives shortly after a throw
- a short cooldown prevents one movement from being counted multiple times

This is a training prototype, not a game-officiating system. Thresholds are intentionally conservative and should be tuned on-device with real throwing and catching drills.

## Project structure

- `UltimateFrisbeeMetric.xcodeproj`: Xcode project
- `UltimateFrisbeeMetric Watch App/`: watchOS SwiftUI app target

## Run

1. Open `UltimateFrisbeeMetric.xcodeproj` in Xcode.
2. Select the `UltimateFrisbeeMetric Watch App` scheme.
3. Run on an Apple Watch or watchOS simulator.
4. Start a training session from the main screen.

## Sensor notes

`CoreMotion` is available on Apple Watch, but realistic throw and catch detection needs testing on physical hardware. The current detector is built to be understandable and easy to tune rather than overly complex.

## Next improvements

1. Add `HealthKit` workout sessions so motion tracking stays reliable during longer training blocks.
2. Mirror session summaries to the paired iPhone using `WatchConnectivity`.
3. Export drill history for coaches or longitudinal player analysis.
