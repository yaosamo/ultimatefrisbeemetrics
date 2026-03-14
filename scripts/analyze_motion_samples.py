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
RELEASE_WINDOW_BEFORE_SECONDS = 0.10
RELEASE_WINDOW_AFTER_SECONDS = 0.25
POST_SPIN_WINDOW_START_SECONDS = 0.02
POST_SPIN_WINDOW_END_SECONDS = 0.20
HAMMER_GRAVITY_Y_THRESHOLD = 0.10
FOREHAND_LATERAL_SWEEP_THRESHOLD = 0.05
FOREHAND_POST_SPIN_THRESHOLD = 1.4
FOREHAND_LONG_POST_SPIN_THRESHOLD = 7.0
BACKHAND_LONG_ACCELERATION_THRESHOLD = 7.0
HAMMER_LONG_GRAVITY_Z_THRESHOLD = -0.35
MIN_RECOMMENDATION_COUNT = 8


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
    parser.add_argument(
        "--expected-counts",
        type=Path,
        help=(
            "Optional JSON file with per-recording expected throw counts. "
            "Supports a mapping of sample_id -> expected_count, or a list of "
            "objects with sample_id and expected_count."
        ),
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


def load_expected_counts(path: Path | None) -> dict[str, int]:
    if path is None:
        return {}

    raw = json.loads(path.read_text(encoding="utf-8"))
    if isinstance(raw, dict):
        return {str(key): int(value) for key, value in raw.items()}

    if isinstance(raw, list):
        counts: dict[str, int] = {}
        for item in raw:
            if not isinstance(item, dict):
                raise ValueError("Expected counts list items must be objects.")
            sample_id = item.get("sample_id")
            expected_count = item.get("expected_count")
            if sample_id is None or expected_count is None:
                raise ValueError("Expected counts entries need sample_id and expected_count.")
            counts[str(sample_id)] = int(expected_count)
        return counts

    raise ValueError("Expected counts file must be a JSON object or array.")


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


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    if len(values) == 1:
        return values[0]

    sorted_values = sorted(values)
    position = (len(sorted_values) - 1) * pct
    lower_index = int(position)
    upper_index = min(lower_index + 1, len(sorted_values) - 1)
    weight = position - lower_index
    lower = sorted_values[lower_index]
    upper = sorted_values[upper_index]
    return lower + ((upper - lower) * weight)


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
    post_z = window_values(
        frames,
        peak_index,
        "rotationZ",
        POST_SPIN_WINDOW_START_SECONDS,
        POST_SPIN_WINDOW_END_SECONDS,
    )
    normalized_pre_mean_z = sign * mean_or_zero(pre_z)
    normalized_post_mean_z = sign * mean_or_zero(post_z)
    normalized_post_abs_mean_z = mean_or_zero([abs(sign * v) for v in post_z])
    signed_spin_area = sign * sum(
        window_values(
            frames,
            peak_index,
            "rotationZ",
            -RELEASE_WINDOW_BEFORE_SECONDS,
            RELEASE_WINDOW_AFTER_SECONDS,
        )
    )

    release_frames = window_frames(
        frames,
        peak_index,
        -RELEASE_WINDOW_BEFORE_SECONDS,
        RELEASE_WINDOW_AFTER_SECONDS,
    )

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
        "normalized_lateral_sweep": mean_or_zero([sign * frame["accelerationY"] for frame in release_frames]),
        "normalized_post_spin": normalized_post_mean_z,
        "peak_acceleration_magnitude": max(acc_mags[peak_index], 0.0),
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


def print_wrist_breakdown(events: list[dict]) -> None:
    print("By Wrist")
    if not events:
        print("  no segmented throws")
        print()
        return

    grouped: dict[tuple[str, str], list[dict]] = defaultdict(list)
    for event in events:
        grouped[(event["base_label"], event["watch_wrist"])].append(event)

    for family in ("forehand", "backhand", "hammer"):
        family_events = [event for event in events if event["base_label"] == family]
        if not family_events:
            continue
        wrists = sorted({event["watch_wrist"] for event in family_events})
        print(f"  {family}: wrists={', '.join(wrists)}")
        for wrist in wrists:
            wrist_events = grouped[(family, wrist)]
            print(
                f"    {wrist}: n={len(wrist_events)} "
                f"lateral_median={statistics.median([event['normalized_lateral_sweep'] for event in wrist_events]):.3f} "
                f"post_spin_median={statistics.median([event['normalized_post_spin'] for event in wrist_events]):.3f} "
                f"gravity_y_median={statistics.median([event['mean_gravity_y'] for event in wrist_events]):.3f}"
            )
    print()


def print_recording_breakdown(samples: list[dict], events: list[dict]) -> None:
    print("By Recording")
    event_count_by_sample: dict[str, int] = defaultdict(int)
    for event in events:
        event_count_by_sample[event["sample_id"]] += 1

    for sample in samples:
        sample_id = str(sample["id"])
        print(
            f"  {sample_id}: label={sample['label']} wrist={sample['watchWrist']} "
            f"duration={sample['duration']:.1f}s segmented_throws={event_count_by_sample[sample_id]}"
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


def print_detector_feature_summary(events: list[dict], label: str) -> None:
    label_events = [event for event in events if event["base_label"] == label]
    if not label_events:
        print(f"{label} detector-facing features: no segmented throws")
        print()
        return

    print(f"{label} detector-facing features:")
    for feature_name in (
        "normalized_lateral_sweep",
        "normalized_post_spin",
        "mean_gravity_y",
        "mean_gravity_z",
        "peak_acceleration_magnitude",
    ):
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


def print_dataset_warnings(events: list[dict]) -> None:
    counts = defaultdict(int)
    base_counts = defaultdict(int)
    warnings: list[str] = []

    for event in events:
        counts[event["label"]] += 1
        base_counts[event["base_label"]] += 1

    for family in ("forehand", "backhand", "hammer"):
        if base_counts[family] < MIN_RECOMMENDATION_COUNT:
            warnings.append(
                f"{family} has only {base_counts[family]} segmented throws; family tuning is low-confidence."
            )

    for label, count in sorted(counts.items()):
        if count < MIN_RECOMMENDATION_COUNT:
            warnings.append(
                f"{label} has only {count} segmented throws; power tuning is low-confidence."
            )

    wrists = sorted({event["watch_wrist"] for event in events})
    if len(wrists) < 2:
        warnings.append(
            f"dataset only contains {', '.join(wrists) or 'unknown'} wrist data; "
            "wrist-normalized thresholds may not generalize to left and right without validation."
        )

    print("Dataset warnings")
    if not warnings:
        print("  none")
    else:
        for warning in warnings:
            print(f"  {warning}")
    print()


def print_family_metrics(events: list[dict], *, wrist: str | None = None) -> None:
    scoped_events = events if wrist is None else [event for event in events if event["watch_wrist"] == wrist]
    if not scoped_events:
        return

    family_confusion: dict[str, defaultdict[str, int]] = defaultdict(lambda: defaultdict(int))
    predicted_totals: dict[str, int] = defaultdict(int)
    actual_totals: dict[str, int] = defaultdict(int)
    correct_totals: dict[str, int] = defaultdict(int)

    for event in scoped_events:
        predicted_style, _ = classify_current_swift_rule(event)
        actual_style = event["base_label"]
        family_confusion[actual_style][predicted_style] += 1
        predicted_totals[predicted_style] += 1
        actual_totals[actual_style] += 1
        if predicted_style == actual_style:
            correct_totals[actual_style] += 1

    title = "Family Metrics" if wrist is None else f"Family Metrics ({wrist})"
    print(title)
    for family in ("forehand", "backhand", "hammer"):
        actual = actual_totals[family]
        predicted = predicted_totals[family]
        correct = correct_totals[family]
        if actual == 0 and predicted == 0:
            continue
        precision = (correct / predicted) if predicted else 0.0
        recall = (correct / actual) if actual else 0.0
        f1 = (2 * precision * recall / (precision + recall)) if (precision + recall) else 0.0
        print(
            f"  {family}: precision={precision:.1%} recall={recall:.1%} "
            f"f1={f1:.1%} support={actual}"
        )
    print()


def classify_current_swift_rule(event: dict) -> tuple[str, str]:
    if event["mean_gravity_y"] < HAMMER_GRAVITY_Y_THRESHOLD:
        style = "hammer"
    elif (
        event["normalized_lateral_sweep"] > FOREHAND_LATERAL_SWEEP_THRESHOLD
        and event["normalized_post_spin"] > FOREHAND_POST_SPIN_THRESHOLD
    ):
        style = "forehand"
    else:
        style = "backhand"

    if style == "forehand":
        power = "long" if event["normalized_post_spin"] >= FOREHAND_LONG_POST_SPIN_THRESHOLD else "short"
    elif style == "backhand":
        power = (
            "long"
            if event["peak_acceleration_magnitude"] >= BACKHAND_LONG_ACCELERATION_THRESHOLD
            else "short"
        )
    else:
        power = "long" if event["mean_gravity_z"] >= HAMMER_LONG_GRAVITY_Z_THRESHOLD else "short"

    return style, power


def print_current_rule_replay(events: list[dict]) -> None:
    family_confusion: dict[str, defaultdict[str, int]] = defaultdict(lambda: defaultdict(int))
    power_confusion: dict[str, defaultdict[str, int]] = defaultdict(lambda: defaultdict(int))
    family_correct = 0
    power_correct = 0
    labeled_power_total = 0

    for event in events:
        predicted_style, predicted_power = classify_current_swift_rule(event)
        actual_family = event["base_label"]
        actual_power = event["power_variant"]

        family_confusion[actual_family][predicted_style] += 1
        if actual_family == predicted_style:
            family_correct += 1

        if actual_power in {"short", "long"}:
            labeled_power_total += 1
            power_confusion[f"{actual_family}_{actual_power}"][f"{predicted_style}_{predicted_power}"] += 1
            if actual_family == predicted_style and actual_power == predicted_power:
                power_correct += 1

    print("Current Swift rule replay")
    print(f"  family accuracy: {family_correct}/{len(events)} ({family_correct / len(events):.1%})")
    if labeled_power_total:
        print(
            "  family+power accuracy: "
            f"{power_correct}/{labeled_power_total} ({power_correct / labeled_power_total:.1%})"
        )
    print("  family confusion:")
    for actual in ("forehand", "backhand", "hammer"):
        predictions = family_confusion.get(actual)
        if not predictions:
            continue
        parts = [f"{predicted}={count}" for predicted, count in sorted(predictions.items())]
        print(f"    {actual}: " + ", ".join(parts))
    print("  labeled power confusion:")
    for actual in sorted(power_confusion):
        predictions = power_confusion[actual]
        parts = [f"{predicted}={count}" for predicted, count in sorted(predictions.items())]
        print(f"    {actual}: " + ", ".join(parts))
    print()

    print_family_metrics(events)
    for wrist in sorted({event["watch_wrist"] for event in events}):
        print_family_metrics(events, wrist=wrist)


def print_throw_detection_metrics(samples: list[dict], events: list[dict], expected_counts: dict[str, int]) -> None:
    print("Throw Detection Metrics")
    event_count_by_sample: dict[str, int] = defaultdict(int)
    for event in events:
        event_count_by_sample[event["sample_id"]] += 1

    if not expected_counts:
        print("  unavailable: provide --expected-counts with per-recording expected throw counts")
        print("  current script can still compare family classification on segmented throw windows")
        print()
        return

    sample_ids = {str(sample["id"]) for sample in samples}
    matched_ids = [sample_id for sample_id in expected_counts if sample_id in sample_ids]
    if not matched_ids:
        print("  unavailable: expected counts file did not match any sample ids in this export")
        print()
        return

    total_expected = 0
    total_detected = 0
    total_true_positive = 0

    for sample in samples:
        sample_id = str(sample["id"])
        if sample_id not in expected_counts:
            continue
        expected = expected_counts[sample_id]
        detected = event_count_by_sample[sample_id]
        true_positive = min(expected, detected)
        total_expected += expected
        total_detected += detected
        total_true_positive += true_positive
        print(
            f"  {sample_id}: expected={expected} detected={detected} "
            f"matched={true_positive} over={max(detected - expected, 0)} "
            f"missed={max(expected - detected, 0)}"
        )

    precision = (total_true_positive / total_detected) if total_detected else 0.0
    recall = (total_true_positive / total_expected) if total_expected else 0.0
    print(
        f"  overall: expected={total_expected} detected={total_detected} "
        f"precision={precision:.1%} recall={recall:.1%}"
    )
    print("  note: this is count-level detection quality, not per-frame event matching")
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


def print_threshold_review(events: list[dict]) -> None:
    forehands = [event for event in events if event["base_label"] == "forehand"]
    backhands = [event for event in events if event["base_label"] == "backhand"]
    hammers = [event for event in events if event["base_label"] == "hammer"]

    print("Suggested threshold review")
    if len(forehands) >= MIN_RECOMMENDATION_COUNT and len(backhands) >= MIN_RECOMMENDATION_COUNT:
        fore_post_spin = [event["normalized_post_spin"] for event in forehands]
        back_post_spin = [event["normalized_post_spin"] for event in backhands]
        fore_lateral = [event["normalized_lateral_sweep"] for event in forehands]
        back_lateral = [event["normalized_lateral_sweep"] for event in backhands]

        suggested_post_spin = (statistics.median(fore_post_spin) + statistics.median(back_post_spin)) / 2.0
        conservative_lateral = (percentile(fore_lateral, 0.25) + percentile(back_lateral, 0.75)) / 2.0

        print(
            "  forehand/backhand:"
            f" normalized_post_spin midpoint={suggested_post_spin:.3f}"
            f" current={FOREHAND_POST_SPIN_THRESHOLD:.3f}"
        )
        print(
            "  forehand/backhand:"
            f" normalized_lateral_sweep overlap midpoint={conservative_lateral:.3f}"
            f" current={FOREHAND_LATERAL_SWEEP_THRESHOLD:.3f}"
        )
    else:
        print("  forehand/backhand: not enough segmented throws for a confident recommendation")

    if len(hammers) >= MIN_RECOMMENDATION_COUNT:
        hammer_gravity_y = [event["mean_gravity_y"] for event in hammers]
        non_hammer_gravity_y = [
            event["mean_gravity_y"] for event in events if event["base_label"] in {"forehand", "backhand"}
        ]
        suggested_hammer = (statistics.median(hammer_gravity_y) + statistics.median(non_hammer_gravity_y)) / 2.0
        print(
            "  hammer:"
            f" mean_gravity_y midpoint={suggested_hammer:.3f}"
            f" current={HAMMER_GRAVITY_Y_THRESHOLD:.3f}"
        )
    else:
        print("  hammer: not enough segmented throws for a confident recommendation")

    forehand_short = [event for event in forehands if event["power_variant"] == "short"]
    forehand_long = [event for event in forehands if event["power_variant"] == "long"]
    backhand_short = [event for event in backhands if event["power_variant"] == "short"]
    backhand_long = [event for event in backhands if event["power_variant"] == "long"]

    if len(forehand_short) >= MIN_RECOMMENDATION_COUNT and len(forehand_long) >= MIN_RECOMMENDATION_COUNT:
        short_spin = [event["normalized_post_spin"] for event in forehand_short]
        long_spin = [event["normalized_post_spin"] for event in forehand_long]
        suggested_forehand_power = (statistics.median(short_spin) + statistics.median(long_spin)) / 2.0
        print(
            "  forehand power:"
            f" normalized_post_spin midpoint={suggested_forehand_power:.3f}"
            f" current={FOREHAND_LONG_POST_SPIN_THRESHOLD:.3f}"
        )
    else:
        print("  forehand power: not enough segmented throws for a confident recommendation")

    if len(backhand_short) >= MIN_RECOMMENDATION_COUNT and len(backhand_long) >= MIN_RECOMMENDATION_COUNT:
        short_acc = [event["peak_acceleration_magnitude"] for event in backhand_short]
        long_acc = [event["peak_acceleration_magnitude"] for event in backhand_long]
        suggested_backhand_power = (statistics.median(short_acc) + statistics.median(long_acc)) / 2.0
        print(
            "  backhand power:"
            f" peak_acceleration midpoint={suggested_backhand_power:.3f}"
            f" current={BACKHAND_LONG_ACCELERATION_THRESHOLD:.3f}"
        )
    else:
        print("  backhand power: not enough segmented throws for a confident recommendation")
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
    try:
        expected_counts = load_expected_counts(args.expected_counts)
    except ValueError as error:
        print(f"Invalid expected counts file: {error}", file=sys.stderr)
        return 1

    samples = export.get("samples", [])
    if not samples:
        print("No samples found in export.", file=sys.stderr)
        return 1

    events: list[dict] = []
    for sample in samples:
        events.extend(segment_sample(sample))

    print_dataset_summary(samples, events)
    print_wrist_breakdown(events)
    print_recording_breakdown(samples, events)
    for label in ("forehand", "backhand", "hammer"):
        print_feature_summary(events, label)
    for label in ("forehand", "backhand", "hammer"):
        print_detector_feature_summary(events, label)
    print_dataset_warnings(events)
    print_throw_detection_metrics(samples, events, expected_counts)
    print_current_rule_replay(events)
    print_threshold_review(events)
    suggest_thresholds(events)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
