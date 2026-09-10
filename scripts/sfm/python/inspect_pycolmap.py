#!/usr/bin/env python3
"""Dump pycolmap 4.2 API surfaces needed by the rig SfM wrapper."""
from __future__ import annotations

import inspect
import json
import sys
from pathlib import Path


def pub(obj) -> list[str]:
    return [n for n in dir(obj) if not n.startswith("_")]


def sig(obj) -> str | None:
    try:
        return str(inspect.signature(obj))
    except Exception:
        return None


def main() -> int:
    import pycolmap

    names = [
        "Database",
        "Camera",
        "Image",
        "Rig",
        "Frame",
        "Rigid3d",
        "Rotation3d",
        "Reconstruction",
        "CameraModelId",
        "FeatureExtractionOptions",
        "FeatureMatchingOptions",
        "IncrementalPipelineOptions",
        "IncrementalMapperOptions",
        "SiftExtractionOptions",
        "SiftMatchingOptions",
        "ImageReaderOptions",
        "BundleAdjustmentOptions",
        "extract_features",
        "match_exhaustive",
        "match_sequential",
        "match_imported",
        "import_matches",
        "incremental_mapping",
        "triangulate_points",
        "bundle_adjustment",
    ]
    out: dict = {
        "version": getattr(pycolmap, "__version__", None),
        "file": getattr(pycolmap, "__file__", None),
        "module_names": [n for n in dir(pycolmap) if "match" in n.lower() or "map" in n.lower() or "extract" in n.lower() or "rig" in n.lower() or "ceres" in n.lower() or "caspar" in n.lower() or "cuda" in n.lower() or "gpu" in n.lower() or "pano" in n.lower()],
        "objects": {},
    }
    for n in names:
        if not hasattr(pycolmap, n):
            out["objects"][n] = {"present": False}
            continue
        obj = getattr(pycolmap, n)
        rec = {"present": True, "type": type(obj).__name__, "callable_sig": sig(obj) if callable(obj) else None, "dir": pub(obj)}
        if inspect.isclass(obj):
            rec["init"] = sig(obj)
            try:
                inst = None
                rec["instance_dir"] = pub(obj)
            except Exception as e:
                rec["instance_error"] = str(e)
        out["objects"][n] = rec

    pano_path = Path("/opt/gs/vendor/colmap-4.2.0/panorama.py")
    if pano_path.exists():
        text = pano_path.read_text(encoding="utf-8")
        out["panorama_py"] = {
            "path": str(pano_path),
            "bytes": pano_path.stat().st_size,
            "has_reconstruct": "def reconstruct" in text,
            "has_get_virtual_rotations": "def get_virtual_rotations" in text,
            "defs": [ln.strip() for ln in text.splitlines() if ln.startswith("def ") or ln.startswith("class ")],
        }
        try:
            sys.path.insert(0, str(pano_path.parent))
            import panorama as pano  # type: ignore

            out["panorama_import"] = {
                "file": getattr(pano, "__file__", None),
                "names": pub(pano),
                "get_virtual_rotations_sig": sig(getattr(pano, "get_virtual_rotations", None)),
            }
        except Exception as e:
            out["panorama_import"] = {"error": str(e)}

    dest = Path("/opt/gs/evidence/pycolmap-api.json")
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_text(json.dumps(out, indent=2, default=str) + "\n", encoding="utf-8")
    win = Path("/mnt/c/Users/Administrator/Desktop/01_项目与代码/高斯破溅/logs/sfm/linux-setup/pycolmap-api.json")
    try:
        win.parent.mkdir(parents=True, exist_ok=True)
        win.write_text(dest.read_text(encoding="utf-8"), encoding="utf-8")
    except Exception:
        pass
    print("WROTE", dest)
    print("version", out["version"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
