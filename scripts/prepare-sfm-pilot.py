#!/usr/bin/env python3
"""Keyframe window selection + lightweight SfM prep from existing shortest-pilot PTS.

Does not re-scan all source videos. Does not start COLMAP / GPU SfM.
"""
from __future__ import annotations

import argparse
import csv
import json
import math
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import cv2
import numpy as np


def write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def load_pts(csv_path: Path) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    with csv_path.open("r", encoding="utf-8", newline="") as f:
        for raw in csv.DictReader(f):
            pts = raw.get("pts_time")
            try:
                pts_f = float(pts) if pts not in (None, "") else None
            except ValueError:
                pts_f = None
            idx = int(raw["index"]) if raw.get("index") not in (None, "") else len(rows)
            kf = raw.get("key_frame")
            rows.append(
                {
                    "index": idx,
                    "pts_time": pts_f,
                    "key_frame": kf,
                    "pict_type": raw.get("pict_type"),
                    "width": raw.get("width"),
                    "height": raw.get("height"),
                }
            )
    return rows


def pts_acceptance(rows: list[dict[str, Any]], summary: dict[str, Any] | None) -> dict[str, Any]:
    pts_vals = [r["pts_time"] for r in rows if r["pts_time"] is not None]
    dts = np.diff(pts_vals) if len(pts_vals) >= 2 else np.array([])
    noninc = int(np.sum(dts <= 0)) if dts.size else 0
    first = pts_vals[0] if pts_vals else None
    last = pts_vals[-1] if pts_vals else None
    span = (last - first) if first is not None and last is not None else None
    expected_frames = 476
    expected_last = 47.494967
    passed = bool(
        len(rows) == expected_frames
        and len(pts_vals) == expected_frames
        and noninc == 0
        and first == 0.0
        and last is not None
        and abs(last - expected_last) < 1e-4
        and span is not None
        and span > 40.0
    )
    return {
        "parser_on_disk": None if summary is None else summary.get("parser"),
        "frame_rows": len(rows),
        "pts_count": len(pts_vals),
        "pts_first": first,
        "pts_last": last,
        "pts_span_sec": span,
        "negative_or_zero_dt": noninc,
        "expect_frame_rows": expected_frames,
        "expect_pts_last_about": expected_last,
        "passed": passed,
        "note": "Acceptance is named JSON/CSV PTS, not ffprobe exit code.",
    }


def nearest_pts(rows: list[dict[str, Any]], t: float) -> dict[str, Any] | None:
    best = None
    best_d = None
    for row in rows:
        if row["pts_time"] is None:
            continue
        d = abs(row["pts_time"] - t)
        if best_d is None or d < best_d:
            best_d = d
            best = row
    return best


def score_frame(img: np.ndarray) -> dict[str, float]:
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    lap = float(cv2.Laplacian(gray, cv2.CV_64F).var())
    luma = float(gray.mean())
    under = float(np.mean(gray < 16))
    over = float(np.mean(gray > 239))
    # Prefer sharp frames; penalize empty/blown-out.
    score = lap * (1.0 - 0.85 * under) * (1.0 - 0.45 * over)
    if luma < 25 or luma > 230:
        score *= 0.35
    return {
        "laplacian_var": lap,
        "luma_mean": luma,
        "underexposed_fraction": under,
        "overexposed_fraction": over,
        "score": float(score),
    }


def make_nadir_mask(h: int, w: int) -> np.ndarray:
    """White=keep, black=mask. Bottom band is camera body / operator / pole."""
    mask = np.full((h, w), 255, dtype=np.uint8)
    hard = int(round(h * 0.88))
    mask[hard:, :] = 0
    # Soft band above the hard mask, still unreliable for matching.
    soft = int(round(h * 0.84))
    if soft < hard:
        ramp = np.linspace(255, 0, hard - soft, dtype=np.float32)
        for i, v in enumerate(ramp):
            mask[soft + i, :] = np.minimum(mask[soft + i, :], int(v))
    return mask


def make_sky_soft_mask(h: int, w: int) -> np.ndarray:
    mask = np.full((h, w), 255, dtype=np.uint8)
    hard = int(round(h * 0.08))
    mask[:hard, :] = 40
    return mask


def equirect_to_perspective(
    img: np.ndarray, yaw_deg: float, pitch_deg: float, fov_deg: float, out_size: int
) -> np.ndarray:
    h, w = img.shape[:2]
    f = 0.5 * out_size / math.tan(math.radians(fov_deg) / 2.0)
    cx = cy = (out_size - 1) / 2.0
    xs, ys = np.meshgrid(
        np.arange(out_size, dtype=np.float64), np.arange(out_size, dtype=np.float64)
    )
    x = (xs - cx) / f
    y = (ys - cy) / f
    z = np.ones_like(x)
    vx, vy, vz = x, -y, z
    n = np.sqrt(vx * vx + vy * vy + vz * vz)
    vx, vy, vz = vx / n, vy / n, vz / n
    pitch = math.radians(pitch_deg)
    yaw = math.radians(yaw_deg)
    cos_p, sin_p = math.cos(pitch), math.sin(pitch)
    vy2 = vy * cos_p - vz * sin_p
    vz2 = vy * sin_p + vz * cos_p
    vx2 = vx
    cos_y, sin_y = math.cos(yaw), math.sin(yaw)
    vx3 = vx2 * cos_y + vz2 * sin_y
    vz3 = -vx2 * sin_y + vz2 * cos_y
    vy3 = vy2
    lon = np.arctan2(vx3, vz3)
    lat = np.arcsin(np.clip(vy3, -1.0, 1.0))
    map_x = ((lon / (2.0 * math.pi)) + 0.5) * w
    map_y = (0.5 - lat / math.pi) * h
    return cv2.remap(
        img,
        map_x.astype(np.float32),
        map_y.astype(np.float32),
        interpolation=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_WRAP,
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".", type=Path)
    ap.add_argument("--pilot-dir", default="jobs/shortest-pilot", type=Path)
    ap.add_argument("--window-sec", type=float, default=0.75)
    ap.add_argument("--persp-size", type=int, default=512)
    ap.add_argument("--persp-fov", type=float, default=90.0)
    args = ap.parse_args()

    repo = args.repo.resolve()
    pilot = (repo / args.pilot_dir).resolve() if not args.pilot_dir.is_absolute() else args.pilot_dir
    out = pilot / "sfm-prep"
    out.mkdir(parents=True, exist_ok=True)
    kf_dir = out / "keyframes"
    kf_dir.mkdir(parents=True, exist_ok=True)
    persp_dir = out / "perspectives"
    persp_dir.mkdir(parents=True, exist_ok=True)
    mask_dir = out / "masks"
    mask_dir.mkdir(parents=True, exist_ok=True)

    started = datetime.now(timezone.utc).isoformat()
    selection = json.loads((pilot / "selection.json").read_text(encoding="utf-8"))
    pts_summary = json.loads((pilot / "pts_summary.json").read_text(encoding="utf-8"))
    quality_old = json.loads((pilot / "quality_stats.json").read_text(encoding="utf-8"))
    previews = json.loads((pilot / "previews.json").read_text(encoding="utf-8"))
    projection = json.loads((pilot / "projection_assessment.json").read_text(encoding="utf-8"))
    camera_note = (repo / "configs" / "user-camera-note.md").read_text(encoding="utf-8")
    pts_rows = load_pts(pilot / "pts_samples.csv")
    accept = pts_acceptance(pts_rows, pts_summary)
    write_json(out / "pts_acceptance.json", accept)
    if not accept["passed"]:
        write_json(out / "run_meta.json", {"ok": False, "pts_acceptance": accept, "started_utc": started})
        print(json.dumps({"ok": False, "reason": "pts_acceptance_failed", "accept": accept}, ensure_ascii=False))
        return 2

    src = Path(selection["selected_path"])
    window = float(args.window_sec)

    # Annotate existing previews with requested vs nearest PTS; keep files.
    preview_annotated = []
    for fr in previews.get("frames") or []:
        t = fr.get("t_sec")
        nearest = nearest_pts(pts_rows, float(t)) if t is not None else None
        preview_annotated.append(
            {
                **fr,
                "requested_time_sec": t,
                "actual_pts_sec": None if nearest is None else nearest["pts_time"],
                "source_frame_index": None if nearest is None else nearest["index"],
                "filename_time_is": "requested_seek",
            }
        )
    write_json(pilot / "previews.json", {"time_basis": "requested_vs_actual_pts", "frames": preview_annotated})

    # Map old linspace quality times to nearest PTS without claiming they were real PTS.
    old_times = quality_old.get("sample_pts_sec") or quality_old.get("requested_time_sec") or []
    mapped = []
    for t in old_times:
        nearest = nearest_pts(pts_rows, float(t))
        mapped.append(
            {
                "requested_time_sec": float(t),
                "actual_pts_sec": None if nearest is None else nearest["pts_time"],
                "source_frame_index": None if nearest is None else nearest["index"],
            }
        )
    quality_new = dict(quality_old)
    quality_new["requested_time_sec"] = [m["requested_time_sec"] for m in mapped]
    quality_new["actual_pts_sec"] = [m["actual_pts_sec"] for m in mapped]
    quality_new["source_frame_index"] = [m["source_frame_index"] for m in mapped]
    quality_new["samples"] = mapped
    quality_new["sample_pts_sec_note"] = (
        "sample_pts_sec was linspace requested times, not verified frame PTS. "
        "Renamed to requested_time_sec; actual_pts_sec is nearest ffprobe PTS."
    )
    if "sample_pts_sec" in quality_new:
        del quality_new["sample_pts_sec"]
    write_json(pilot / "quality_stats.json", quality_new)

    cap = cv2.VideoCapture(str(src))
    if not cap.isOpened():
        raise RuntimeError(f"OpenCV could not open {src}")

    best_by_window: dict[int, dict[str, Any]] = {}
    decoded = 0
    idx = 0
    while True:
        ok, img = cap.read()
        if not ok or img is None:
            break
        if idx >= len(pts_rows) or pts_rows[idx]["pts_time"] is None:
            # Fall back to capture time if CSV shorter (should not happen).
            pts = cap.get(cv2.CAP_PROP_POS_MSEC) / 1000.0
        else:
            pts = float(pts_rows[idx]["pts_time"])
        widx = int(math.floor(pts / window + 1e-12))
        metrics = score_frame(img)
        rec = {
            "window_index": widx,
            "window_start_sec": widx * window,
            "window_end_sec": (widx + 1) * window,
            "source_frame_index": idx,
            "pts_time": pts,
            **metrics,
            "image": img.copy(),
        }
        prev = best_by_window.get(widx)
        if prev is None or rec["score"] > prev["score"]:
            best_by_window[widx] = rec
        decoded += 1
        idx += 1
    cap.release()

    selected = [best_by_window[k] for k in sorted(best_by_window)]
    if not selected:
        write_json(out / "run_meta.json", {"ok": False, "reason": "no_frames", "decoded": decoded})
        return 3

    h, w = selected[0]["image"].shape[:2]
    nadir = make_nadir_mask(h, w)
    sky = make_sky_soft_mask(h, w)
    cv2.imwrite(str(mask_dir / "nadir_body.png"), nadir)
    cv2.imwrite(str(mask_dir / "sky_soft.png"), sky)
    combined = cv2.min(nadir, np.maximum(sky, 80))
    cv2.imwrite(str(mask_dir / "combined_keep.png"), combined)

    yaws = [0.0, 90.0, 180.0, 270.0]
    csv_path = out / "keyframes.csv"
    rows_out: list[dict[str, Any]] = []
    persp_count = 0
    for i, rec in enumerate(selected):
        pts = rec["pts_time"]
        name = f"kf_{i:04d}_pts{pts:.6f}.jpg"
        dest = kf_dir / name
        cv2.imwrite(str(dest), rec["image"], [int(cv2.IMWRITE_JPEG_QUALITY), 95])
        reason = (
            f"best score={rec['score']:.3f} (laplacian_var={rec['laplacian_var']:.3f}) "
            f"inside [{rec['window_start_sec']:.3f},{rec['window_end_sec']:.3f})s; "
            f"not a hard 0.75s stride sample."
        )
        persp_names = []
        for yaw in yaws:
            pimg = equirect_to_perspective(
                rec["image"], yaw, 0.0, args.persp_fov, args.persp_size
            )
            pmask = equirect_to_perspective(
                cv2.cvtColor(nadir, cv2.COLOR_GRAY2BGR), yaw, 0.0, args.persp_fov, args.persp_size
            )
            pname = f"kf_{i:04d}_yaw{int(yaw):03d}.jpg"
            mname = f"kf_{i:04d}_yaw{int(yaw):03d}_nadir.png"
            cv2.imwrite(str(persp_dir / pname), pimg, [int(cv2.IMWRITE_JPEG_QUALITY), 92])
            cv2.imwrite(str(persp_dir / mname), cv2.cvtColor(pmask, cv2.COLOR_BGR2GRAY))
            persp_names.append(pname)
            persp_count += 1
        row = {
            "kf_index": i,
            "window_index": rec["window_index"],
            "window_start_sec": rec["window_start_sec"],
            "window_end_sec": rec["window_end_sec"],
            "source_frame_index": rec["source_frame_index"],
            "pts_time": rec["pts_time"],
            "image_name": name,
            "image_path": str(dest),
            "width": w,
            "height": h,
            "laplacian_var": rec["laplacian_var"],
            "luma_mean": rec["luma_mean"],
            "underexposed_fraction": rec["underexposed_fraction"],
            "overexposed_fraction": rec["overexposed_fraction"],
            "score": rec["score"],
            "reason": reason,
            "perspectives": ";".join(persp_names),
        }
        rows_out.append(row)
        rec.pop("image", None)

    with csv_path.open("w", encoding="utf-8", newline="") as f:
        fields = [
            "kf_index",
            "window_index",
            "window_start_sec",
            "window_end_sec",
            "source_frame_index",
            "pts_time",
            "image_name",
            "image_path",
            "width",
            "height",
            "laplacian_var",
            "luma_mean",
            "underexposed_fraction",
            "overexposed_fraction",
            "score",
            "reason",
            "perspectives",
        ]
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows_out)

    write_json(out / "keyframes.json", {"count": len(rows_out), "window_sec": window, "frames": rows_out})

    projection_update = dict(projection)
    projection_update["pilot_assumption"] = "equirectangular_visual_not_calibrated"
    projection_update["is_proven_stitched_equirectangular"] = False
    projection_update["hard_apply_panorama_rig"] = False
    projection_update["visual_evidence"] = {
        "preview_used": str(pilot / "previews" / "frame_01_t11.899s.jpg"),
        "observed": [
            "Full spherical unwrap: sky/pole stretch at top, operator/pole/camera body unwrapped at bottom.",
            "Left and right edges continue the same paved ground and nadir object (wraparound).",
            "Trees, ground, buildings, and moving pedestrians are present.",
        ],
        "camera_user_note": camera_note.strip(),
        "intrinsics": "unknown",
        "allowed_for_shortest_pilot": True,
        "do_not_block_on_user_proof": True,
    }
    write_json(pilot / "projection_assessment.json", projection_update)

    defects = {
        "source": src.name,
        "resolution": {"width": w, "height": h},
        "nadir_body_mask": {
            "path": str(mask_dir / "nadir_body.png"),
            "rule": "bottom 12% hard mask, 12-16% soft ramp; camera body/operator/pole.",
            "fixed": True,
        },
        "sky_pole": {
            "path": str(mask_dir / "sky_soft.png"),
            "rule": "top 8% down-weighted; pole stretch and stitch arcs visible.",
            "fixed": False,
            "note": "Not a hard exclude of all sky; matching should not rely on polar band.",
        },
        "pedestrians": {
            "detected_by": "visual inspection of previews, not an automatic person model",
            "impact": "moving people will break multi-view consistency; do not treat as static structure.",
            "action_this_stage": "record only; no instance masks generated.",
        },
        "stitch_arcs": "sky contains arc-like stitch artifacts",
        "camera_calibration": "unknown; user camera note is 美碳v3 / mentech PanoX V3 on sibling 3840x1920 files",
        "selected_file_is_1280x640_export": True,
    }
    write_json(out / "defects.json", defects)

    sfm_plan = {
        "status": "prepared_not_started",
        "do_not_start_gpu_sfm": True,
        "assumption": "equirectangular visual hypothesis for shortest-pilot only",
        "images": {
            "equirect_original": str(kf_dir),
            "count": len(rows_out),
            "resolution": [w, h],
        },
        "perspectives": {
            "dir": str(persp_dir),
            "size": args.persp_size,
            "fov_deg": args.persp_fov,
            "yaws_deg": yaws,
            "pitch_deg": 0,
            "count": persp_count,
            "note": "512 chosen over 1024; source is 1280x640 so 1024 would upsample.",
        },
        "masks": {
            "nadir": str(mask_dir / "nadir_body.png"),
            "sky_soft": str(mask_dir / "sky_soft.png"),
            "per_perspective_nadir": "kf_*_yaw*_nadir.png beside each perspective jpeg",
        },
        "colmap": {
            "planned_version": "4.2.0",
            "planned_host": "WSL GS-Ubuntu2204",
            "started": False,
            "rig": "4 overlapping-enough horizontal perspectives per pano; top/bottom cube faces omitted (sky/nadir).",
        },
        "next": "Start COLMAP only after WSL distro and CUDA visibility are ready. Not this stage.",
    }
    write_json(out / "sfm_plan.json", sfm_plan)

    ended = datetime.now(timezone.utc).isoformat()
    meta = {
        "started_utc": started,
        "ended_utc": ended,
        "decoded_frames": decoded,
        "windows": len(best_by_window),
        "selected_keyframes": len(rows_out),
        "window_sec": window,
        "pts_acceptance": accept,
        "source": str(src),
        "uploaded": False,
        "sfm_started": False,
    }
    write_json(out / "run_meta.json", meta)
    print(
        json.dumps(
            {
                "ok": True,
                "decoded": decoded,
                "keyframes": len(rows_out),
                "perspectives": persp_count,
                "out": str(out),
            },
            ensure_ascii=False,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
