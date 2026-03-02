#!/usr/bin/env python3

import argparse
import json
import math
import statistics
import sys
from collections import defaultdict
from pathlib import Path

MARKER_BEGIN = "[SampleExport] BEGIN"
MARKER_END = "[SampleExport] END"
THROW_ROTATION_THRESHOLD = 7.8
THROW_ACCELERATION_THRESHOLD = 1.35
THROW_COOLDOWN_SECONDS = 0.75
WINDOW_BEFORE_SECONDS = 0.20
WINDOW_AFTER_SECONDS = 0.40


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Analyze exported Apple Watch motion samples and suggest "
            "feature thresholds for forehand/backhand classification."
        )
    )
    parser.add_argument(
        "input",
        type=Path,
        help="Path to exported JSON or a raw Xcode console log containing the export markers.",
    )
    return parser.parse_args()


def merge_exports(exports: list[dict]) -> dict:
    merged_samples: list[dict] = []
    for export in exports:
        merged_samples.extend(export.get("samples", []))
    return {
        "sampleCount": len(merged_samples),
        "samples": merged_samples,
    }


def load_export(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    stripped = text.strip()
    if stripped.startswith("{"):
        return json.loads(stripped)

    exports: list[dict] = []
    search_start = 0

    while True:
        begin = text.find(MARKER_BEGIN, search_start)
        if begin == -1:
            break
        end = text.find(MARKER_END, begin + len(MARKER_BEGIN))
        if end == -1:
            raise ValueError(
                "Found a '[SampleExport] BEGIN' marker without a matching "
                "'[SampleExport] END' marker."
            )

        json_text = text[begin + len(MARKER_BEGIN):end].strip()
        exports.append(json.loads(json_text))
        search_start = end + len(MARKER_END)

    if not exports:
        raise ValueError(
            "Could not find sample export markers. Pass the exported JSON file "
            "or a console log containing '[SampleExport] BEGIN' and '[SampleExport] END'."
        )

    return merge_exports(exports)


def wrist_sign(wrist: str) -> float:
    return -1.0 if wrist.lower() == "right" else 1.0


def magnitude(x: float, y: float, z: float) -> float:
    return math.sqrt((x * x) + (y * y) + (z * z))


def window_values(frames: list[dict], peak_index: int, key: str, start: float, end: float) -> list[float]:
    peak_time = frames[peak_index]["timestamp"]
    values = []
    for frame in frames:
        dt = frame["timestamp"] - peak_time
        if start <= dt <= end:
            values.append(frame[key])
    return values


def summarize(values: list[float]) -> str:
    if not values:
        return "n=0"
    return (
        f"n={len(values)} mean={statistics.fmean(values):.3f} "
        f"median={statistics.median(values):.3f} "
        f"min={min(values):.3f} max={max(values):.3f}"
    )


def analyze_throw_window(sample: dict, frames: list[dict], peak_index: int) -> dict:
    peak_frame = frames[peak_index]
    sign = wrist_sign(sample["watchWrist"])

    rot_mags = [
        magnitude(frame["rotationX"], frame["rotationY"], frame["rotationZ"])
        for frame in frames
    ]
    acc_mags = [
        magnitude(frame["accelerationX"], frame["accelerationY"], frame["accelerationZ"])
        for frame in frames
    ]

    peak_rot_mag = rot_mags[peak_index]
    peak_acc_mag = acc_mags[peak_index]
    peak_rot_z = peak_frame["rotationZ"]
    normalized_peak_z = sign * peak_rot_z

    pre_z = window_values(frames, peak_index, "rotationZ", -0.15, -0.02)
    post_z = window_values(frames, peak_index, "rotationZ", 0.02, 0.20)
    normalized_pre_mean_z = sign * statistics.fmean(pre_z) if pre_z else 0.0
    normalized_post_mean_z = sign * statistics.fmean(post_z) if post_z else 0.0
    normalized_post_abs_mean_z = statistics.fmean([abs(sign * v) for v in post_z]) if post_z else 0.0
    signed_spin_area = sign * sum(window_values(frames, peak_index, "rotationZ", -0.10, 0.25))

    return {
        "sample_id": sample["id"],
        "label": sample["label"],
        "watch_wrist": sample["watchWrist"],
        "peak_timestamp": peak_frame["timestamp"],
        "peak_rot_mag": peak_rot_mag,
        "peak_acc_mag": peak_acc_mag,
        "peak_rot_z": peak_rot_z,
        "normalized_peak_z": normalized_peak_z,
        "normalized_pre_mean_z": normalized_pre_mean_z,
        "normalized_post_mean_z": normalized_post_mean_z,
        "normalized_post_abs_mean_z": normalized_post_abs_mean_z,
        "signed_spin_area_z": signed_spin_area,
    }


def segment_sample(sample: dict) -> list[dict]:
    frames = sample["frames"]
    if not frames:
        return []

    rot_mags = [
        magnitude(frame["rotationX"], frame["rotationY"], frame["rotationZ"])
        for frame in frames
    ]
    acc_mags = [
        magnitude(frame["accelerationX"], frame["accelerationY"], frame["accelerationZ"])
        for frame in frames
    ]

    events: list[dict] = []
    last_peak_time = -float("inf")

    for index in range(1, len(frames) - 1):
        if rot_mags[index] < THROW_ROTATION_THRESHOLD:
            continue
        if acc_mags[index] < THROW_ACCELERATION_THRESHOLD:
            continue
        if rot_mags[index] < rot_mags[index - 1] or rot_mags[index] < rot_mags[index + 1]:
            continue

        peak_time = frames[index]["timestamp"]
        if peak_time - last_peak_time < THROW_COOLDOWN_SECONDS:
            continue

        last_peak_time = peak_time
        events.append(analyze_throw_window(sample, frames, index))

    return events


def print_dataset_summary(samples: list[dict], events: list[dict]) -> None:
    counts_by_label = defaultdict(int)
    events_by_label = defaultdict(int)
    wrists_by_label: dict[str, set[str]] = defaultdict(set)

    for sample in samples:
        counts_by_label[sample["label"]] += 1
        wrists_by_label[sample["label"]].add(sample["watchWrist"])
    for event in events:
        events_by_label[event["label"]] += 1

    print("Dataset")
    print(f"  recordings: {len(samples)}")
    print(f"  segmented throw windows: {len(events)}")
    for label in sorted(counts_by_label):
        wrists = ", ".join(sorted(wrists_by_label[label]))
        print(
            f"  {label}: recordings={counts_by_label[label]} "
            f"segmented_throws={events_by_label[label]} wrists={wrists}"
        )
    print()


def print_feature_summary(events: list[dict], label: str) -> None:
    label_events = [event for event in events if event["label"] == label]
    if not label_events:
        print(f"{label}: no segmented throws")
        print()
        return

    feature_names = [
        "peak_rot_mag",
        "peak_acc_mag",
        "normalized_peak_z",
        "normalized_pre_mean_z",
        "normalized_post_mean_z",
        "normalized_post_abs_mean_z",
        "signed_spin_area_z",
    ]

    print(f"{label}:")
    for feature_name in feature_names:
        values = [event[feature_name] for event in label_events]
        print(f"  {feature_name}: {summarize(values)}")
    print()


def suggest_thresholds(events: list[dict]) -> None:
    forehands = [event for event in events if event["label"] == "forehand"]
    backhands = [event for event in events if event["label"] == "backhand"]
    if not forehands or not backhands:
        print("Need both forehand and backhand recordings before suggesting thresholds.")
        return

    fore_peak = [event["normalized_peak_z"] for event in forehands]
    back_peak = [event["normalized_peak_z"] for event in backhands]
    fore_post = [event["normalized_post_mean_z"] for event in forehands]
    back_post = [event["normalized_post_mean_z"] for event in backhands]

    peak_threshold = (statistics.median(fore_peak) + statistics.median(back_peak)) / 2.0
    post_threshold = (statistics.median(fore_post) + statistics.median(back_post)) / 2.0

    print("Suggested first-pass rule")
    print(
        "  if normalized_peak_z > "
        f"{peak_threshold:.3f} and normalized_post_mean_z > {post_threshold:.3f}: forehand"
    )
    print(
        "  if normalized_peak_z <= "
        f"{peak_threshold:.3f} and normalized_post_mean_z <= {post_threshold:.3f}: backhand"
    )
    print("  else: unknown")
    print()

    print("Separation check")
    print(f"  forehand normalized_peak_z: {summarize(fore_peak)}")
    print(f"  backhand normalized_peak_z: {summarize(back_peak)}")
    print(f"  forehand normalized_post_mean_z: {summarize(fore_post)}")
    print(f"  backhand normalized_post_mean_z: {summarize(back_post)}")


def main() -> int:
    args = parse_args()
    export = load_export(args.input)
    samples = export.get("samples", [])
    if not samples:
        print("No samples found in export.", file=sys.stderr)
        return 1

    events: list[dict] = []
    for sample in samples:
        events.extend(segment_sample(sample))

    print_dataset_summary(samples, events)
    for label in ("forehand", "backhand", "catch"):
        print_feature_summary(events, label)
    suggest_thresholds(events)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
