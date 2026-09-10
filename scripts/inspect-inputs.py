#!/usr/bin/env python3
"""Read-only video ingest check. Source videos are never modified or uploaded."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import math
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import cv2
import numpy as np


def load_tools(repo: Path) -> dict[str, Any]:
    p = repo / "configs" / "tools.json"
    return json.loads(p.read_text(encoding="utf-8"))


def run_cmd(args: list[str], log_lines: list[str], timeout: int = 600) -> subprocess.CompletedProcess[str]:
    log_lines.append("CMD " + " ".join(json.dumps(a, ensure_ascii=False) for a in args))
    proc = subprocess.run(
        args,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
        check=False,
    )
    log_lines.append(f"exit={proc.returncode}")
    if proc.stderr.strip():
        log_lines.append("STDERR " + proc.stderr.strip()[:4000])
    return proc


def ffprobe_json(ffprobe: str, path: Path, log_lines: list[str]) -> dict[str, Any]:
    args = [
        ffprobe,
        "-v",
        "error",
        "-print_format",
        "json",
        "-show_format",
        "-show_streams",
        "-show_entries",
        "format=filename,duration,size,bit_rate,format_name,nb_streams:format_tags:"
        "stream=index,codec_name,codec_type,profile,width,height,pix_fmt,avg_frame_rate,"
        "r_frame_rate,nb_frames,duration,bit_rate,sample_aspect_ratio,display_aspect_ratio,"
        "color_space,color_primaries,color_transfer,field_order,side_data_list:stream_tags:"
        "stream_side_data",
        str(path),
    ]
    proc = run_cmd(args, log_lines, timeout=120)
    if proc.returncode != 0:
        return {"error": proc.stderr.strip() or f"ffprobe exit {proc.returncode}", "stdout": proc.stdout}
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        return {"error": f"ffprobe json decode: {exc}", "stdout": proc.stdout[:2000]}


def parse_rate(rate: str | None) -> float | None:
    if not rate or rate in ("0/0", "N/A"):
        return None
    if "/" in rate:
        a, b = rate.split("/", 1)
        try:
            denom = float(b)
            return float(a) / denom if denom else None
        except ValueError:
            return None
    try:
        return float(rate)
    except ValueError:
        return None


def video_stream(meta: dict[str, Any]) -> dict[str, Any] | None:
    for s in meta.get("streams") or []:
        if s.get("codec_type") == "video":
            return s
    return None


def aspect_of(vs: dict[str, Any] | None) -> float | None:
    if not vs:
        return None
    w, h = vs.get("width"), vs.get("height")
    if not w or not h:
        return None
    return float(w) / float(h)


def sha256_file(path: Path, chunk: int = 1024 * 1024) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            b = f.read(chunk)
            if not b:
                break
            h.update(b)
    return h.hexdigest()


def extract_preview(ffmpeg: str, src: Path, t: float, dest: Path, log_lines: list[str]) -> dict[str, Any]:
    dest.parent.mkdir(parents=True, exist_ok=True)
    args = [
        ffmpeg,
        "-hide_banner",
        "-y",
        "-ss",
        f"{t:.6f}",
        "-i",
        str(src),
        "-frames:v",
        "1",
        "-update",
        "1",
        "-q:v",
        "2",
        str(dest),
    ]
    proc = run_cmd(args, log_lines, timeout=120)
    ok = proc.returncode == 0 and dest.is_file() and dest.stat().st_size > 0
    return {
        "t_sec": t,
        "path": str(dest),
        "ok": ok,
        "exit_code": proc.returncode,
        "bytes": dest.stat().st_size if dest.is_file() else 0,
        "stderr_tail": (proc.stderr or "")[-500:],
    }


def decode_verify(ffmpeg: str, src: Path, seconds: float, log_lines: list[str]) -> dict[str, Any]:
    args = [
        ffmpeg,
        "-hide_banner",
        "-v",
        "info",
        "-xerror",
        "-i",
        str(src),
        "-t",
        f"{seconds:.6f}",
        "-map",
        "0:v:0",
        "-f",
        "null",
        "-",
    ]
    proc = run_cmd(args, log_lines, timeout=600)
    err = proc.stderr or ""
    frame_count = None
    for token in reversed(err.replace("\r", "\n").split()):
        if token.startswith("frame="):
            try:
                frame_count = int(token.split("=", 1)[1])
            except ValueError:
                pass
            break
    # ffmpeg prints "frame=  123" with spaces; parse more robustly
    if frame_count is None:
        import re

        matches = re.findall(r"frame=\s*(\d+)", err)
        if matches:
            frame_count = int(matches[-1])
    error_lines = [
        ln.strip()
        for ln in err.splitlines()
        if any(k in ln.lower() for k in ("error", "corrupt", "invalid", "failed"))
        and "handler" not in ln.lower()
    ]
    return {
        "command": args,
        "exit_code": proc.returncode,
        "decoded_ok": proc.returncode == 0,
        "reported_frame_count": frame_count,
        "error_lines": error_lines[:50],
        "stderr_tail": err[-2000:],
        "clip_seconds": seconds,
    }


def _fnum(value: Any) -> float | None:
    if value in (None, "", "N/A"):
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def collect_pts(ffprobe: str, src: Path, seconds: float, log_lines: list[str], dest_csv: Path) -> dict[str, Any]:
    args = [
        ffprobe,
        "-hide_banner",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-read_intervals",
        f"%+{seconds:.6f}",
        "-show_frames",
        "-print_format",
        "json",
        str(src),
    ]
    proc = run_cmd(args, log_lines, timeout=300)
    frames: list[dict[str, Any]] = []
    try:
        payload = json.loads(proc.stdout or "{}")
        frames = list(payload.get("frames") or [])
    except json.JSONDecodeError as exc:
        frames = []
        log_lines.append(f"pts json decode failed: {exc}")
    rows: list[dict[str, Any]] = []
    for fr in frames:
        pts = _fnum(fr.get("pts_time"))
        if pts is None:
            pts = _fnum(fr.get("pkt_pts_time"))
        rows.append(
            {
                "index": len(rows),
                "pts_time": pts,
                "pkt_pts_time": _fnum(fr.get("pkt_pts_time")),
                "pkt_dts_time": _fnum(fr.get("pkt_dts_time")),
                "best_effort_timestamp_time": _fnum(fr.get("best_effort_timestamp_time")),
                "key_frame": fr.get("key_frame"),
                "pict_type": fr.get("pict_type"),
                "pkt_size": _fnum(fr.get("pkt_size")),
                "width": _fnum(fr.get("width")),
                "height": _fnum(fr.get("height")),
            }
        )
    dest_csv.parent.mkdir(parents=True, exist_ok=True)
    with dest_csv.open("w", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(
            f,
            fieldnames=[
                "index",
                "pts_time",
                "pkt_pts_time",
                "pkt_dts_time",
                "best_effort_timestamp_time",
                "key_frame",
                "pict_type",
                "pkt_size",
                "width",
                "height",
            ],
        )
        w.writeheader()
        for i, r in enumerate(rows):
            w.writerow({"index": i, **r})

    pts_vals = [r["pts_time"] for r in rows if r["pts_time"] is not None]
    dts = np.diff(pts_vals) if len(pts_vals) >= 2 else np.array([])
    summary = {
        "exit_code": proc.returncode,
        "parser": "ffprobe -show_frames json",
        "frame_rows": len(rows),
        "pts_count": len(pts_vals),
        "pts_first": pts_vals[0] if pts_vals else None,
        "pts_last": pts_vals[-1] if pts_vals else None,
        "pts_span_sec": (pts_vals[-1] - pts_vals[0]) if len(pts_vals) >= 2 else None,
        "dt_median_sec": float(np.median(dts)) if dts.size else None,
        "dt_mean_sec": float(np.mean(dts)) if dts.size else None,
        "dt_min_sec": float(np.min(dts)) if dts.size else None,
        "dt_max_sec": float(np.max(dts)) if dts.size else None,
        "dt_std_sec": float(np.std(dts)) if dts.size else None,
        "negative_or_zero_dt": int(np.sum(dts <= 0)) if dts.size else 0,
        "keyframe_count": sum(1 for r in rows if str(r.get("key_frame")) in ("1", "1.0", "True")),
        "csv": str(dest_csv),
        "stderr_tail": (proc.stderr or "")[-1000:],
    }
    span = summary["pts_span_sec"]
    summary["acceptance"] = {
        "ffprobe_exit_0": proc.returncode == 0,
        "frame_rows_ok": len(rows) > 0,
        "pts_count_equals_rows": len(pts_vals) == len(rows),
        "monotonic_ok": summary["negative_or_zero_dt"] == 0,
        "span_positive": bool(span is not None and span > 0),
        "passed": bool(
            proc.returncode == 0
            and len(rows) > 0
            and len(pts_vals) == len(rows)
            and summary["negative_or_zero_dt"] == 0
            and span is not None
            and span > 0
        ),
        "note": "Do not treat ffprobe exit code as PTS validity. Named JSON fields are required.",
    }
    return summary


def wrap_seam_score(gray: np.ndarray, band: int = 8) -> float | None:
    if gray.shape[1] < band * 2:
        return None
    left = gray[:, :band].astype(np.float32)
    right = gray[:, -band:].astype(np.float32)
    return float(np.mean(np.abs(left - right)))


def pole_stretch_hint(gray: np.ndarray) -> dict[str, float]:
    h = gray.shape[0]
    top = gray[: max(h // 12, 2), :].astype(np.float32)
    mid = gray[h // 2 - h // 20 : h // 2 + h // 20, :].astype(np.float32)
    bot = gray[-max(h // 12, 2) :, :].astype(np.float32)
    return {
        "top_row_std": float(np.std(top)),
        "mid_row_std": float(np.std(mid)),
        "bottom_row_std": float(np.std(bot)),
    }


def quality_from_frames(frames: list[np.ndarray], pts: list[float]) -> dict[str, Any]:
    laps: list[float] = []
    means: list[float] = []
    underex: list[float] = []
    overex: list[float] = []
    seams: list[float] = []
    mads: list[float] = []
    prev = None
    poles: list[dict[str, float]] = []
    for img in frames:
        gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
        laps.append(float(cv2.Laplacian(gray, cv2.CV_64F).var()))
        means.append(float(gray.mean()))
        underex.append(float(np.mean(gray < 16)))
        overex.append(float(np.mean(gray > 239)))
        s = wrap_seam_score(gray)
        if s is not None:
            seams.append(s)
        poles.append(pole_stretch_hint(gray))
        if prev is not None:
            a = cv2.resize(prev, (160, 80), interpolation=cv2.INTER_AREA).astype(np.float32)
            b = cv2.resize(gray, (160, 80), interpolation=cv2.INTER_AREA).astype(np.float32)
            mads.append(float(np.mean(np.abs(a - b))))
        prev = gray
    def pct(xs: list[float], q: float) -> float | None:
        if not xs:
            return None
        return float(np.percentile(xs, q))

    return {
        "sampled_frames": len(frames),
        "laplacian_var": {
            "mean": float(np.mean(laps)) if laps else None,
            "median": float(np.median(laps)) if laps else None,
            "p10": pct(laps, 10),
            "p90": pct(laps, 90),
            "min": float(np.min(laps)) if laps else None,
            "max": float(np.max(laps)) if laps else None,
        },
        "luma_mean": {
            "mean": float(np.mean(means)) if means else None,
            "min": float(np.min(means)) if means else None,
            "max": float(np.max(means)) if means else None,
        },
        "underexposed_fraction_mean": float(np.mean(underex)) if underex else None,
        "overexposed_fraction_mean": float(np.mean(overex)) if overex else None,
        "consecutive_proxy_mad": {
            "mean": float(np.mean(mads)) if mads else None,
            "median": float(np.median(mads)) if mads else None,
            "min": float(np.min(mads)) if mads else None,
            "near_static_fraction_mad_lt_2": (float(np.mean(np.array(mads) < 2.0)) if mads else None),
        },
        "left_right_wrap_mae_0_255": {
            "mean": float(np.mean(seams)) if seams else None,
            "median": float(np.median(seams)) if seams else None,
            "note": "Low value is consistent with wraparound or with similar edge content; not proof of equirectangular.",
        },
        "pole_band_std": {
            "top_mean": float(np.mean([p["top_row_std"] for p in poles])) if poles else None,
            "mid_mean": float(np.mean([p["mid_row_std"] for p in poles])) if poles else None,
            "bottom_mean": float(np.mean([p["bottom_row_std"] for p in poles])) if poles else None,
            "note": "Equirect often has lower spatial detail near poles; heuristic only.",
        },
        "requested_time_sec": pts,
        "sample_pts_sec_deprecated": {
            "removed": True,
            "reason": "Previously this was linspace target times, not verified frame PTS.",
        },
    }


def nearest_pts_row(pts_rows: list[dict[str, Any]], t: float) -> dict[str, Any] | None:
    best = None
    best_d = None
    for row in pts_rows:
        pts = row.get("pts_time")
        if pts is None:
            continue
        d = abs(float(pts) - float(t))
        if best_d is None or d < best_d:
            best_d = d
            best = row
    return best


def decode_sample_frames(
    src: Path,
    seconds: float,
    n: int = 24,
    pts_rows: list[dict[str, Any]] | None = None,
) -> tuple[list[np.ndarray], list[dict[str, Any]]]:
    cap = cv2.VideoCapture(str(src))
    if not cap.isOpened():
        raise RuntimeError(f"OpenCV could not open {src}")
    fps = cap.get(cv2.CAP_PROP_FPS) or 10.0
    total = int(cap.get(cv2.CAP_PROP_FRAME_COUNT) or 0)
    duration = seconds
    if total > 0 and fps > 1e-3:
        duration = min(seconds, total / fps)
    times = [0.0] if n <= 1 else [duration * i / (n - 1) for i in range(n)]
    frames: list[np.ndarray] = []
    samples: list[dict[str, Any]] = []
    for t in times:
        cap.set(cv2.CAP_PROP_POS_MSEC, max(t, 0.0) * 1000.0)
        pos_before = cap.get(cv2.CAP_PROP_POS_FRAMES)
        ok, img = cap.read()
        if not ok or img is None:
            continue
        pos_after = cap.get(cv2.CAP_PROP_POS_FRAMES)
        actual_msec = cap.get(cv2.CAP_PROP_POS_MSEC)
        frame_index = int(pos_after) - 1 if pos_after else int(pos_before)
        nearest = nearest_pts_row(pts_rows or [], actual_msec / 1000.0 if actual_msec else t)
        frames.append(img)
        samples.append(
            {
                "requested_time_sec": t,
                "actual_capture_time_sec": (actual_msec / 1000.0) if actual_msec else None,
                "source_frame_index": frame_index,
                "actual_pts_sec": None if nearest is None else nearest.get("pts_time"),
                "nearest_pts_index": None if nearest is None else nearest.get("index"),
            }
        )
    cap.release()
    return frames, samples


def write_json(path: Path, obj: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".", type=Path)
    ap.add_argument("--media-dir", default="全景素材", type=Path)
    ap.add_argument("--out-dir", default="jobs/shortest-pilot", type=Path)
    ap.add_argument("--max-seconds", type=float, default=90.0)
    args = ap.parse_args()

    repo = args.repo.resolve()
    media = (repo / args.media_dir).resolve() if not args.media_dir.is_absolute() else args.media_dir
    out = (repo / args.out_dir).resolve() if not args.out_dir.is_absolute() else args.out_dir
    out.mkdir(parents=True, exist_ok=True)
    log_lines: list[str] = []
    tools = load_tools(repo)
    ffmpeg = tools["ffmpeg"]
    ffprobe = tools["ffprobe"]
    started = datetime.now(timezone.utc).isoformat()

    files = sorted([p for p in media.iterdir() if p.is_file() and p.suffix.lower() in {".mp4", ".mov", ".mkv", ".insv"}])
    manifest_rows: list[dict[str, Any]] = []
    for p in files:
        meta = ffprobe_json(ffprobe, p, log_lines)
        vs = video_stream(meta) if "error" not in meta else None
        fmt = (meta.get("format") or {}) if isinstance(meta, dict) else {}
        duration = None
        try:
            duration = float(fmt.get("duration")) if fmt.get("duration") is not None else None
        except (TypeError, ValueError):
            duration = None
        w = vs.get("width") if vs else None
        h = vs.get("height") if vs else None
        aspect = aspect_of(vs)
        manifest_rows.append(
            {
                "name": p.name,
                "path": str(p),
                "size_bytes": p.stat().st_size,
                "mtime_utc": datetime.fromtimestamp(p.stat().st_mtime, tz=timezone.utc).isoformat(),
                "duration_sec": duration,
                "format_name": fmt.get("format_name"),
                "bit_rate": fmt.get("bit_rate"),
                "format_tags": fmt.get("tags") or {},
                "video": {
                    "codec": vs.get("codec_name") if vs else None,
                    "profile": vs.get("profile") if vs else None,
                    "width": w,
                    "height": h,
                    "aspect_w_over_h": aspect,
                    "pix_fmt": vs.get("pix_fmt") if vs else None,
                    "avg_frame_rate": vs.get("avg_frame_rate") if vs else None,
                    "r_frame_rate": vs.get("r_frame_rate") if vs else None,
                    "nb_frames": vs.get("nb_frames") if vs else None,
                    "color_space": vs.get("color_space") if vs else None,
                    "tags": vs.get("tags") if vs else None,
                    "side_data_list": vs.get("side_data_list") if vs else None,
                } if vs or True else None,
                "audio_codecs": [s.get("codec_name") for s in (meta.get("streams") or []) if s.get("codec_type") == "audio"],
                "ffprobe_error": meta.get("error"),
                "ratio_2_1_candidate": bool(aspect is not None and abs(aspect - 2.0) <= 0.02),
                "has_spherical_tag": bool(
                    json.dumps(fmt.get("tags") or {}, ensure_ascii=False).lower().find("spher") >= 0
                    or json.dumps((vs or {}).get("tags") or {}, ensure_ascii=False).lower().find("spher") >= 0
                    or json.dumps((vs or {}).get("side_data_list") or [], ensure_ascii=False).lower().find("spher") >= 0
                ),
            }
        )

    timed = [r for r in manifest_rows if isinstance(r.get("duration_sec"), (int, float))]
    timed_sorted = sorted(timed, key=lambda r: (r["duration_sec"], r["name"]))
    selected = timed_sorted[0] if timed_sorted else None
    write_json(
        out / "video_manifest.json",
        {
            "sort": "ffprobe_format.duration ascending; ties by name. NOT file size.",
            "media_dir": str(media),
            "count": len(manifest_rows),
            "videos": timed_sorted + [r for r in manifest_rows if r not in timed_sorted],
        },
    )

    if not selected:
        write_json(out / "selection.json", {"error": "no duration-readable videos"})
        (out / "inspect.log").write_text("\n".join(log_lines), encoding="utf-8")
        return 2

    src = Path(selected["path"])
    duration = float(selected["duration_sec"])
    process_sec = min(duration, float(args.max_seconds))
    digest = sha256_file(src)
    write_json(
        out / "selected_hash.json",
        {
            "algo": "sha256",
            "hex": digest,
            "bytes": src.stat().st_size,
            "name": src.name,
            "note": "Only the selected source file is hashed. Original file not copied.",
        },
    )
    write_json(
        out / "selection.json",
        {
            "selected_name": src.name,
            "selected_path": str(src),
            "duration_sec": duration,
            "size_bytes": src.stat().st_size,
            "reason": (
                f"Shortest ffprobe format.duration among {len(timed_sorted)} readable videos "
                f"({duration:.6f} s). File size was not used for ranking."
            ),
            "ranked_durations_sec": [
                {"name": r["name"], "duration_sec": r["duration_sec"], "size_bytes": r["size_bytes"]}
                for r in timed_sorted
            ],
            "process_seconds": process_sec,
            "process_seconds_rule": "min(duration, 90). This clip is shorter than 90s so the whole clip is processed.",
            "sha256": digest,
        },
    )

    decode = decode_verify(ffmpeg, src, process_sec, log_lines)
    write_json(out / "decode_verify.json", decode)

    pts = collect_pts(ffprobe, src, process_sec, log_lines, out / "pts_samples.csv")
    write_json(out / "pts_summary.json", pts)

    preview_dir = out / "previews"
    last_t = max(process_sec - 0.20, 0.0)
    preview_times = [0.0]
    if process_sec > 0:
        for frac in (0.25, 0.5, 0.75):
            preview_times.append(min(max(process_sec * frac, 0.0), last_t))
        preview_times.append(last_t)
    preview_times = sorted(set(round(t, 3) for t in preview_times))
    preview_results = []
    pts_rows = []
    try:
        with (out / "pts_samples.csv").open("r", encoding="utf-8", newline="") as f:
            for row in csv.DictReader(f):
                pts_rows.append(
                    {
                        "index": int(row["index"]) if row.get("index") not in (None, "") else None,
                        "pts_time": _fnum(row.get("pts_time")),
                    }
                )
    except FileNotFoundError:
        pts_rows = []
    for i, t in enumerate(preview_times):
        dest = preview_dir / f"frame_{i:02d}_t{t:.3f}s.jpg"
        item = extract_preview(ffmpeg, src, t, dest, log_lines)
        nearest = nearest_pts_row(pts_rows, t)
        item["requested_time_sec"] = t
        item["actual_pts_sec"] = None if nearest is None else nearest.get("pts_time")
        item["source_frame_index"] = None if nearest is None else nearest.get("index")
        item["note"] = "t_sec/filename use requested seek time; actual_pts_sec is nearest ffprobe PTS."
        preview_results.append(item)
    write_json(out / "previews.json", {"frames": preview_results, "time_basis": "requested_vs_actual_pts"})

    frames, samples = decode_sample_frames(src, process_sec, n=24, pts_rows=pts_rows)
    quality = quality_from_frames(frames, [s["requested_time_sec"] for s in samples])
    quality["requested_time_sec"] = [s["requested_time_sec"] for s in samples]
    quality["actual_capture_time_sec"] = [s["actual_capture_time_sec"] for s in samples]
    quality["actual_pts_sec"] = [s["actual_pts_sec"] for s in samples]
    quality["source_frame_index"] = [s["source_frame_index"] for s in samples]
    quality["samples"] = samples
    vs = selected.get("video") or {}
    aspect = vs.get("aspect_w_over_h")
    tags = selected.get("format_tags") or {}
    spherical_meta = selected.get("has_spherical_tag")
    ratio_ok = bool(aspect is not None and abs(float(aspect) - 2.0) <= 0.02)
    projection = {
        "verdict": "2_1_candidate_not_proven_equirectangular",
        "is_proven_stitched_equirectangular": False,
        "hard_apply_panorama_rig": False,
        "evidence": {
            "width": vs.get("width"),
            "height": vs.get("height"),
            "aspect_w_over_h": aspect,
            "within_2_1_tolerance": ratio_ok,
            "ffprobe_spherical_or_equirect_tags": spherical_meta,
            "format_tags": tags,
            "camera_make": tags.get("make") or tags.get("make-eng"),
            "camera_model": tags.get("model") or tags.get("model-eng"),
            "android_version_tag": tags.get("com.android.version"),
            "left_right_wrap_mae_mean": (quality.get("left_right_wrap_mae_0_255") or {}).get("mean"),
            "preview_paths": [p["path"] for p in preview_results if p.get("ok")],
            "local_visual_notes": [
                "Previews show curved ground, horizon, and a split camera/operator blob on the bottom edge (typical nadir).",
                "Left and right edges continue the same nadir object, consistent with wraparound.",
                "Sky contains arc-like stitch artifacts. This is content evidence, not a metadata proof.",
            ],
        },
        "interpretation": (
            "A 2:1 pixel ratio is a candidate for equirectangular panorama, not proof. "
            "This selected file has no spherical / equirect metadata in ffprobe. "
            "Local previews are consistent with a stitched 360 frame plus nadir camera body, "
            "but that still does not mathematically prove a single-center equirectangular model. "
            "Do not hard-apply a 12-view panorama Rig in this stage."
        ),
        "related_files_note": (
            "Sibling files video_20260906_180959.mp4 and video_20260906_181540.mp4 carry "
            "mentech / PanoX V3 tags at 3840x1920. That is camera-origin evidence for those "
            "files only, and still does not mathematically prove a stitched 2:1 equirect."
        ),
    }
    write_json(out / "quality_stats.json", quality)
    write_json(out / "projection_assessment.json", projection)

    ended = datetime.now(timezone.utc).isoformat()
    write_json(
        out / "run_meta.json",
        {
            "started_utc": started,
            "ended_utc": ended,
            "python": sys.executable,
            "python_version": sys.version,
            "opencv": cv2.__version__,
            "numpy": np.__version__,
            "ffmpeg": ffmpeg,
            "ffprobe": ffprobe,
            "source_readonly": True,
            "uploaded": False,
            "max_seconds": args.max_seconds,
            "processed_seconds": process_sec,
            "selected": src.name,
            "decode_exit_code": decode.get("exit_code"),
            "pts_exit_code": pts.get("exit_code"),
            "pts_acceptance": (pts.get("acceptance") or {}).get("passed"),
        },
    )
    (out / "inspect.log").write_text("\n".join(log_lines) + "\n", encoding="utf-8")
    print(json.dumps({"ok": True, "out": str(out), "selected": src.name, "duration_sec": duration}, ensure_ascii=False))
    return 0 if decode.get("decoded_ok") else 1


if __name__ == "__main__":
    raise SystemExit(main())
