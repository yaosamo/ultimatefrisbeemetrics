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


def base_label(label: str) -> str:
    if label.startswith("forehand"):
        return "forehand"
    if label.startswith("backhand"):
        return "backhand"
    if label.startswith("hammer"):
        return "hammer"
    return label


def power_variant(label: str) -> str:
    if label.endswith("_short"):
        return "short"
    if label.endswith("_long"):
        return "long"
    return "standard"


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


def mean_or_zero(values: list[float]) -> float:
    return statistics.fmean(values) if values else 0.0


def window_values(frames: list[dict], peak_index: int, key: str, start: float, end: float) -> list[float]:
    peak_time = frames[peak_index]["timestamp"]
    values = []
    for frame in frames:
        dt = frame["timestamp"] - peak_time
        if start <= dt <= end:
            values.append(frame[key])
    return values


def window_frames(frames: list[dict], peak_index: int, start: float, end: float) -> list[dict]:
    peak_time = frames[peak_index]["timestamp"]
    values = []
    for frame in frames:
        dt = frame["timestamp"] - peak_time
        if start <= dt <= end:
            values.append(frame)
    return values


def integrate_window(frames: list[dict], key: str) -> float:
    if len(frames) < 2:
        return 0.0

    area = 0.0
    previous = frames[0]
    for current in frames[1:]:
        dt = current["timestamp"] - previous["timestamp"]
        if dt > 0:
            area += ((previous[key] + current[key]) * 0.5) * dt
        previous = current
    return area


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
    normalized_pre_mean_z = sign * mean_or_zero(pre_z)
    normalized_post_mean_z = sign * mean_or_zero(post_z)
    normalized_post_abs_mean_z = mean_or_zero([abs(sign * v) for v in post_z])
    signed_spin_area = sign * sum(window_values(frames, peak_index, "rotationZ", -0.10, 0.25))

    release_frames = window_frames(frames, peak_index, -0.10, 0.25)

    acceleration_features: dict[str, float] = {}
    for axis in ("X", "Y", "Z"):
        key = f"acceleration{axis}"
        axis_values = [frame[key] for frame in release_frames]
        peak_accel = peak_frame[key]
        mean_accel = mean_or_zero(axis_values)
        area_accel = integrate_window(release_frames, key)
        acceleration_features[f"peak_accel_{axis.lower()}"] = peak_accel
        acceleration_features[f"mean_accel_{axis.lower()}"] = mean_accel
        acceleration_features[f"accel_area_{axis.lower()}"] = area_accel

    gravity_features: dict[str, float] = {}
    for axis in ("X", "Y", "Z"):
        key = f"gravity{axis}"
        axis_values = [frame[key] for frame in release_frames]
        peak_gravity = peak_frame[key]
        mean_gravity = mean_or_zero(axis_values)
        gravity_range = (max(axis_values) - min(axis_values)) if axis_values else 0.0
        gravity_features[f"peak_gravity_{axis.lower()}"] = peak_gravity
        gravity_features[f"mean_gravity_{axis.lower()}"] = mean_gravity
        gravity_features[f"gravity_range_{axis.lower()}"] = gravity_range

    return {
        "sample_id": sample["id"],
        "label": sample["label"],
        "base_label": base_label(sample["label"]),
        "power_variant": power_variant(sample["label"]),
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
        **acceleration_features,
        **gravity_features,
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
    counts_by_base_label = defaultdict(int)
    events_by_label = defaultdict(int)
    events_by_base_label = defaultdict(int)
    wrists_by_label: dict[str, set[str]] = defaultdict(set)
    wrists_by_base_label: dict[str, set[str]] = defaultdict(set)

    for sample in samples:
        label = sample["label"]
        family = base_label(label)
        counts_by_label[label] += 1
        counts_by_base_label[family] += 1
        wrists_by_label[label].add(sample["watchWrist"])
        wrists_by_base_label[family].add(sample["watchWrist"])
    for event in events:
        events_by_label[event["label"]] += 1
        events_by_base_label[event["base_label"]] += 1

    print("Dataset")
    print(f"  recordings: {len(samples)}")
    print(f"  segmented throw windows: {len(events)}")
    for label in ("backhand", "forehand", "hammer"):
        if counts_by_base_label[label] == 0:
            continue
        wrists = ", ".join(sorted(wrists_by_base_label[label]))
        print(
            f"  {label}: recordings={counts_by_base_label[label]} "
            f"segmented_throws={events_by_base_label[label]} wrists={wrists}"
        )
    for label in sorted(counts_by_label):
        wrists = ", ".join(sorted(wrists_by_label[label]))
        print(
            f"  {label}: recordings={counts_by_label[label]} "
            f"segmented_throws={events_by_label[label]} wrists={wrists}"
        )
    print()

    print("By Power Variant")
    for label in sorted(counts_by_label):
        wrists = ", ".join(sorted(wrists_by_label[label]))
        variant = power_variant(label)
        print(
            f"  {label} ({variant}): recordings={counts_by_label[label]} "
            f"segmented_throws={events_by_label[label]} wrists={wrists}"
        )
    print()


def print_feature_summary(events: list[dict], label: str, *, event_key: str = "base_label") -> None:
    label_events = [event for event in events if event[event_key] == label]
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
        "peak_accel_x",
        "peak_accel_y",
        "peak_accel_z",
        "mean_accel_x",
        "mean_accel_y",
        "mean_accel_z",
        "accel_area_x",
        "accel_area_y",
        "accel_area_z",
        "peak_gravity_x",
        "peak_gravity_y",
        "peak_gravity_z",
        "mean_gravity_x",
        "mean_gravity_y",
        "mean_gravity_z",
        "gravity_range_x",
        "gravity_range_y",
        "gravity_range_z",
    ]

    print(f"{label}:")
    for feature_name in feature_names:
        values = [event[feature_name] for event in label_events]
        print(f"  {feature_name}: {summarize(values)}")
    print()


def print_power_summary(events: list[dict], label: str) -> None:
    variants = ["short", "long", "standard"]
    printed = False
    for variant in variants:
        variant_events = [
            event for event in events
            if event["base_label"] == label and event["power_variant"] == variant
        ]
        if not variant_events:
            continue
        printed = True
        print(f"{label} ({variant}):")
        print(f"  peak_rot_mag: {summarize([event['peak_rot_mag'] for event in variant_events])}")
        print(f"  peak_acc_mag: {summarize([event['peak_acc_mag'] for event in variant_events])}")
        print(f"  mean_accel_y: {summarize([event['mean_accel_y'] for event in variant_events])}")
        print(f"  normalized_post_mean_z: {summarize([event['normalized_post_mean_z'] for event in variant_events])}")
        print(f"  mean_gravity_z: {summarize([event['mean_gravity_z'] for event in variant_events])}")
        print()
    if not printed:
        print(f"{label} by power: no segmented throws")
        print()


def separation_score(fore_values: list[float], back_values: list[float]) -> float:
    fore_median = statistics.median(fore_values)
    back_median = statistics.median(back_values)
    fore_low = min(fore_values)
    fore_high = max(fore_values)
    back_low = min(back_values)
    back_high = max(back_values)
    overlap_low = max(fore_low, back_low)
    overlap_high = min(fore_high, back_high)
    overlap = max(0.0, overlap_high - overlap_low)
    range_span = max(fore_high, back_high) - min(fore_low, back_low)
    margin = abs(fore_median - back_median)
    if range_span <= 0:
        return 0.0
    return margin - overlap - (0.05 * range_span)


def print_sweep_direction_candidates(events: list[dict]) -> None:
    forehands = [event for event in events if event["base_label"] == "forehand"]
    backhands = [event for event in events if event["base_label"] == "backhand"]
    if not forehands or not backhands:
        return

    candidate_features = [
        "peak_accel_x",
        "peak_accel_y",
        "peak_accel_z",
        "mean_accel_x",
        "mean_accel_y",
        "mean_accel_z",
        "accel_area_x",
        "accel_area_y",
        "accel_area_z",
    ]

    ranked: list[tuple[float, str, float, float]] = []
    for feature_name in candidate_features:
        fore_values = [event[feature_name] for event in forehands]
        back_values = [event[feature_name] for event in backhands]
        fore_median = statistics.median(fore_values)
        back_median = statistics.median(back_values)
        ranked.append(
            (
                separation_score(fore_values, back_values),
                feature_name,
                fore_median,
                back_median,
            )
        )

    ranked.sort(reverse=True)

    print("Sweep-direction candidates")
    for score, feature_name, fore_median, back_median in ranked[:5]:
        direction = "forehand > backhand" if fore_median > back_median else "backhand > forehand"
        print(
            f"  {feature_name}: score={score:.3f} "
            f"forehand_median={fore_median:.3f} "
            f"backhand_median={back_median:.3f} "
            f"({direction})"
        )
    print()


def print_hammer_orientation_candidates(events: list[dict]) -> None:
    hammers = [event for event in events if event["base_label"] == "hammer"]
    non_hammers = [event for event in events if event["base_label"] in {"forehand", "backhand"}]
    if not hammers or not non_hammers:
        return

    candidate_features = [
        "mean_gravity_x",
        "mean_gravity_y",
        "mean_gravity_z",
        "peak_gravity_x",
        "peak_gravity_y",
        "peak_gravity_z",
        "gravity_range_x",
        "gravity_range_y",
        "gravity_range_z",
        "mean_accel_z",
        "accel_area_z",
        "normalized_post_mean_z",
    ]

    ranked: list[tuple[float, str, float, float]] = []
    for feature_name in candidate_features:
        hammer_values = [event[feature_name] for event in hammers]
        non_hammer_values = [event[feature_name] for event in non_hammers]
        hammer_median = statistics.median(hammer_values)
        non_hammer_median = statistics.median(non_hammer_values)
        ranked.append(
            (
                separation_score(hammer_values, non_hammer_values),
                feature_name,
                hammer_median,
                non_hammer_median,
            )
        )

    ranked.sort(reverse=True)

    print("Hammer orientation candidates")
    for score, feature_name, hammer_median, non_hammer_median in ranked[:8]:
        direction = "hammer > non-hammer" if hammer_median > non_hammer_median else "non-hammer > hammer"
        print(
            f"  {feature_name}: score={score:.3f} "
            f"hammer_median={hammer_median:.3f} "
            f"non_hammer_median={non_hammer_median:.3f} "
            f"({direction})"
        )
    print()


def suggest_thresholds(events: list[dict]) -> None:
    forehands = [event for event in events if event["base_label"] == "forehand"]
    backhands = [event for event in events if event["base_label"] == "backhand"]
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
    print()
    print("By Power")
    print_power_summary(events, "forehand")
    print_power_summary(events, "backhand")
    print_power_summary(events, "hammer")
    print_sweep_direction_candidates(events)
    print_hammer_orientation_candidates(events)


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
    for label in ("forehand", "backhand", "hammer"):
        print_feature_summary(events, label)
    suggest_thresholds(events)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
