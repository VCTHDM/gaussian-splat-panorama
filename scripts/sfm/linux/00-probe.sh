#!/usr/bin/env bash
# Probe GS-Ubuntu2204 for SfM. No GPU job, no driver install, no reboot.
set -eu
export LANG=C.UTF-8
OUT="${1:-/tmp/gs-sfm-probe.json}"
mkdir -p "$(dirname "$OUT")"
python3 - "$OUT" <<'PY'
import json, os, platform, shutil, subprocess, sys
from pathlib import Path

def run(cmd, timeout=30):
    try:
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=timeout)
        return {"cmd": cmd, "exit": p.returncode, "stdout": (p.stdout or "")[-4000:], "stderr": (p.stderr or "")[-2000:]}
    except Exception as e:
        return {"cmd": cmd, "exit": None, "error": str(e)}

uname = run(["uname", "-a"])
osrel = {}
try:
    for line in Path("/etc/os-release").read_text(encoding="utf-8").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            osrel[k] = v.strip().strip('"')
except Exception as e:
    osrel = {"error": str(e)}

py = run(["python3", "--version"])
py_full = run(["python3", "-c", "import sys,sysconfig; print(sys.version); print(sys.executable); print(sysconfig.get_platform()); print(sys.version_info[:3])"])
which_py = run(["which", "python3"])
venv_mod = run(["python3", "-c", "import venv,ensurepip; print('venv_ok')"])
pip = run(["python3", "-m", "pip", "--version"])
apt_py = run(["dpkg-query", "-W", "-f=${Package} ${Version}\\n", "python3", "python3-venv", "python3-pip", "python3-dev", "python3-opencv"])

mem = {}
try:
    info = {}
    for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
        k, v = line.split(":", 1)
        info[k] = v.strip()
    mem = {k: info.get(k) for k in ("MemTotal", "MemFree", "MemAvailable", "SwapTotal", "SwapFree")}
except Exception as e:
    mem = {"error": str(e)}

disk_root = run(["df", "-B1", "--output=size,used,avail,pcent,target", "/"])
disk_mntc = run(["df", "-B1", "--output=size,used,avail,pcent,target", "/mnt/c"])
nproc = run(["nproc"])
who = run(["id"])
home = str(Path.home())
opt_writable = os.access("/opt", os.W_OK)
home_writable = os.access(home, os.W_OK)

nvidia = run(["/usr/lib/wsl/lib/nvidia-smi", "-L"], timeout=20)
nvidia_q = run(["/usr/lib/wsl/lib/nvidia-smi", "--query-gpu=name,memory.total,memory.used,driver_version", "--format=csv,noheader"], timeout=20)

# Network probes: only record, do not rewrite proxy.
pypi = run(["python3", "-m", "pip", "index", "versions", "pycolmap"], timeout=45)
curl_pypi = run(["curl", "-sS", "-I", "--max-time", "20", "https://pypi.org/simple/pycolmap/"])
curl_pano = run(["curl", "-sS", "-I", "--max-time", "20", "https://raw.githubusercontent.com/colmap/colmap/4.2.0/python/pycolmap/panorama.py"])
curl_gh = run(["curl", "-sS", "-I", "--max-time", "20", "https://github.com/colmap/colmap/raw/4.2.0/python/pycolmap/panorama.py"])

# Try to fetch a small JSON from PyPI for 4.2.0 files.
curl_json = run(["curl", "-sS", "--max-time", "30", "https://pypi.org/pypi/pycolmap/json"])
pypi_files = []
pypi_ver = None
try:
    import json as _json
    data = _json.loads(curl_json.get("stdout") or "")
    pypi_ver = data.get("info", {}).get("version")
    releases = data.get("releases", {})
    for ver in ("4.2.0", "4.1.1", pypi_ver):
        if not ver:
            continue
        for f in releases.get(ver, [])[:30]:
            pypi_files.append({
                "version": ver,
                "filename": f.get("filename"),
                "python": f.get("python_version"),
                "packagetype": f.get("packagetype"),
                "size": f.get("size"),
                "md5": (f.get("digests") or {}).get("md5"),
                "sha256": (f.get("digests") or {}).get("sha256"),
            })
except Exception as e:
    pypi_files = [{"error": str(e)}]

# Existing gs-sfm?
existing = {
    "opt_gs": Path("/opt/gs").exists(),
    "opt_gs_sfm": Path("/opt/gs/env/gs-sfm").exists(),
    "root_gs": Path("/root/gs").exists(),
}

report = {
    "schema": "gs.sfm.linux.probe.v1",
    "uname": uname,
    "os_release": osrel,
    "python3": py,
    "python3_full": py_full,
    "which_python3": which_py,
    "venv": venv_mod,
    "pip": pip,
    "apt_python": apt_py,
    "mem": mem,
    "disk_root": disk_root,
    "disk_mntc": disk_mntc,
    "nproc": nproc,
    "id": who,
    "home": home,
    "opt_writable": opt_writable,
    "home_writable": home_writable,
    "nvidia_smi_L": nvidia,
    "nvidia_smi_query": nvidia_q,
    "pypi_index_pycolmap": pypi,
    "curl_pypi_head": curl_pypi,
    "curl_pano_raw_head": curl_pano,
    "curl_pano_gh_head": curl_gh,
    "pypi_latest": pypi_ver,
    "pypi_files_of_interest": pypi_files,
    "existing": existing,
    "linux_gpu_driver_installed": Path("/usr/bin/nvidia-smi").exists() and not str(Path("/usr/bin/nvidia-smi").resolve()).startswith("/usr/lib/wsl"),
}
Path(sys.argv[1]).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
print("WROTE", sys.argv[1])
PY
