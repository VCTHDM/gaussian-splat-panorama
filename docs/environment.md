# 本机环境与锁定版本

编制：2026-09-09。更新：2026-09-10。Windows 操作 + WSL2 Ubuntu 22.04 重建，不改成 Windows 全套训练。当前进度只记在 `TODO与进度.md`；本文件锁版本、路径和不要重做的操作。

## 当前可用（2026-09-10）

训练尚未开始。高斯和网格尚未生成。

| 项 | 锁定 / 实测 |
|---|---|
| WSL | `C:\Program Files\WSL\wsl.exe` **2.7.13.0**，发行版 `GS-Ubuntu2204`（Ubuntu 22.04.5，WSL2）。**禁止再跑 msiexec / wsl --install / 重下 Ubuntu** |
| GPU | RTX 4070 Ti，Windows 驱动 616.56；WSL 内 `/usr/lib/wsl/lib/nvidia-smi -L` 可见。未装 Linux 显卡驱动 |
| Windows nvcc | 13.2.78。**不是** WSL 内 toolkit，编译 PGSR 不要用它 |
| SfM Python | `/opt/gs/env/gs-sfm`，Python 3.10.12，`pycolmap==4.2.0`。**不要重装** |
| PGSR Python | `/opt/gs/env/pgsr`，Python 3.10.12 |
| PyTorch | `torch==2.4.1+cu124`，`torchvision==0.19.1+cu124`，`torch.version.cuda==12.4`。只走 cu124，**不要混装 cu118** |
| CUDA 编译 | `CUDA_HOME=/usr/local/cuda-12.4`（nvcc 12.4.131）。另有 `/usr/local/cuda-11.8`（11.8.89）备用，训练不用 |
| 架构 | `TORCH_CUDA_ARCH_LIST=8.9`（4070 Ti） |
| CUDA 扩展 | `diff_plane_rasterization==0.0.0`、`simple_knn==0.0.0`，已编译进 pgsr site-packages |
| PGSR 源码 | `/opt/gs/vendor/PGSR`（https://github.com/zju3dv/PGSR） |
| PyTorch3D | **未安装**。`scene/gaussian_model.py` 已改为 `from utils.general_utils import build_rotation as quaternion_to_matrix` |
| 查看 | Windows Blender `C:\Program Files\Blender Foundation\Blender 5.1\blender.exe`；点云查看器 `http://127.0.0.1:8765/viewer/?mode=sparse` |

pgsr 环境其它已装版本：`numpy==1.26.4`、`open3d==0.19.0`、`opencv-python-headless==4.11.0.86`（cv2 4.11.0）、`plyfile==1.1.3`、`lpips==0.1.4`、`trimesh==5.1.0`、`scipy==1.15.3`、`ninja==1.13.2`、`tqdm==4.70.0`、`tensorboard==2.21.0`。

导入确认（2026-09-10 04:59 UTC，日志 `/opt/gs/work/shortest-pilot/logs/pgsr-env.log`）：

```text
torch 2.4.1+cu124 cuda 12.4
cuda_available True
device NVIDIA GeForce RTX 4070 Ti
tensor_sum 8.0
PGSR_ENV_READY
```

```bash
export PATH="/usr/local/cuda-12.4/bin:/opt/gs/env/pgsr/bin:$PATH"
export CUDA_HOME=/usr/local/cuda-12.4
/opt/gs/env/pgsr/bin/python -c "import torch, cv2, open3d, plyfile, diff_plane_rasterization, simple_knn._C; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

GPT 写的 `scripts/sfm/linux/00–07` 是分步脚本，没有一条编排训练/导出/查看的管线。当前先在独立目录跑 demo：`scripts/sfm/linux/06-train-demo.sh`，输出 `/opt/gs/work/demo/` 与 Windows `jobs/demo/`。主任务 `06-train-pgsr.sh` 仍指向 `shortest-pilot`，管线落成后再切。不要先重装环境。

## 路径

| 用途 | 位置 |
|---|---|
| 原视频 | `全景素材/f640ef4cc3c8cbda0df51f7eb2d79368.mp4`（47.6 秒，1280×640） |
| Windows 关键帧 | `jobs/shortest-pilot/sfm-prep/` |
| Linux 工作区 | `/opt/gs/work/shortest-pilot/` |
| SfM 384 | `/opt/gs/work/shortest-pilot/sfm384/`，最大模型 `sparse/7/` |
| PGSR 输入 | `/opt/gs/work/shortest-pilot/pgsr-data/` |
| PGSR 输出（训练后） | `/opt/gs/work/shortest-pilot/pgsr-output/`（目录尚未因训练产生） |
| Windows 点云 | `jobs/shortest-pilot/results/sparse-local.ply` |
| cu124 wheel 缓存 | Linux `/opt/gs/cache/training/`（已完整，可离线重装 pgsr） |
| cu118 半成品 | `/opt/gs/cache/training-cu118/torch-cu118.whl.partial`，**不是可安装 wheel，不要 pip** |
| Windows 失败缓存 | 仓库 `cache/training-wheels/`，不完整，不能安装 |

## 脚本：用哪条、别重跑哪条

经 `scripts/sfm/invoke-wsl.ps1` 调用 Linux 脚本（自动去 CRLF）。

| 脚本 | 状态 |
|---|---|
| `linux/01-setup-env.sh` | SfM 环境已完成。已知管道错误传播和 `has_panorama ... or True` 假阳性；再用时顺手修，不要当重装入口 |
| `linux/04-setup-training.sh` | **不要再跑**。它会从 `download.pytorch.org/whl/cu124` 在线装 torch，且会动已经可用的 pgsr venv |
| `linux/04c-download-training.sh` | 旧下载入口。现用下面的 Python 下载器 |
| `python/download_training_wheels.py` | 按 torch METADATA 拉 NVIDIA/Triton wheel。TUNA 文件为主、官方为镜像；**用 SHA256，不只看 zip/文件大小**。TUNA 的 `/pypi/{name}/{version}/json` 会 404，元数据回落到 pypi.org |
| `linux/04d-install-pgsr-env.sh` | **实际完成环境的入口**：缓存 wheel → `--no-deps` 装 NVIDIA/triton/torch → TUNA 装 Python 依赖 → 打 PyTorch3D 补丁 → 编译两个 CUDA 扩展 → 最小导入确认。wheel 已齐时跳过下载 |
| `linux/04b-finish-training-deps.sh` | 备用：本地 `--no-index --no-deps` 装 wheel，再装 Python 依赖。环境已装好，不必再跑 |
| `linux/05-build-pgsr.sh` | 补丁可重复执行；扩展已编译。缺扩展时才再跑 |
| `linux/06-train-demo.sh` | 独立 demo **已跑完**（2026-09-10）：7,000 次，exit 0，PSNR 21.15。输出 `/opt/gs/work/demo/pgsr-output`，Windows `jobs/demo/results/gaussian-iter7000.ply` |
| `linux/06-train-pgsr.sh` | 47 秒完整训练：30,000 次，densify 至 15,000，最多 100 万点，输出 `/opt/gs/work/shortest-pilot/pgsr-output` |
| `linux/07-export-pgsr.sh` | **未跑**。仍写 shortest-pilot 路径 |

`04d` 里 NVIDIA/triton/torch 必须 `--no-deps`：`--no-index` 时装 triton 会要 `filelock`，本地缓存没有，会失败。Python 小依赖走 TUNA `https://pypi.tuna.tsinghua.edu.cn/simple`。

## 网络（已核实，不要改代理）

- WSL NAT **不能**用 Windows `127.0.0.1` 代理。未改代理配置，未关 TLS 校验。
- TUNA **GET** 可用，大 wheel 约 10–30 MiB/s。`pypi.nvidia.com` / `files.pythonhosted.org` 曾低速、超时、TLS 中断，不要当首选。
- 不要把 Windows `cache/training-wheels/` 或 cu118 `.partial` 交给 pip。

## 已实测（Windows 主机）

| 项 | 值 | 来源 |
|---|---|---|
| OS | Windows 11 专业版 build 26100 | `reports/env-doctor.json` |
| CPU | i5-12490F 6C/12T | 同上 |
| RAM | 31.85 GiB 可见 | 同上 |
| GPU | RTX 4070 Ti，驱动 616.56，12282 MiB | nvidia-smi |
| 存储 | 一块 NVMe；C: 约 200 GiB 空闲量级 | 主机盘；Linux 根分区 `/dev/sdd` 约 1007G、占用约 7–8G |
| VirtualMachinePlatform | Enabled，RestartNeeded=false | Get-WindowsOptionalFeature |
| Microsoft-Windows-Subsystem-Linux | Enabled；CBS 重启已完成 | `reports/wsl-post-reboot-verify.json` |
| wsl.exe | `C:\Program Files\WSL\wsl.exe` 2.7.13.0 | 同上 |
| grok | 1.0.13 (5e9a58528b76) | `configs/tools.json` |
| ffmpeg/ffprobe | WinGet Gyan.FFmpeg.Shared 8.1.2 | 同上 |
| 隔离 Python | `env/gs-control` 3.11.15 + opencv-headless 5.0.0 + numpy 2.4.6 | 输入检查 |
| 系统 Python | 3.12.7 | 不往系统装研究包 |
| uv | 0.11.16 | 已有 |
| Windows COLMAP | 未安装 | 重建走 WSL pycolmap，不在 Windows 装 COLMAP |
| Chocolatey ffmpeg shim | 目标缺失，禁止执行 | tools.json |

未扫描凭据目录，未倾倒环境变量。

## WSL / Ubuntu 安装锁（已完成，禁止重做）

| 项 | 锁定 | 状态 |
|---|---|---|
| WSL | GitHub `microsoft/WSL` **2.7.13**，不用 2.9.x 预览 | 已安装 |
| MSI | `wsl.2.7.13.0.x64.msi` SHA256 `a3505a50f4cc585551d11d9de824ba4375448d7a68f2e71d3fb315fa986fc754` | **禁止再跑 msiexec** |
| 发行版 | Ubuntu 22.04.5 `.wsl` SHA256 `4499c4fe257f2fc83145b429ce211a0a43fd590e70d6261ede616210947d9f8f` | 已 `wsl --import` 为 `GS-Ubuntu2204`，目录 `env/wsl/GS-Ubuntu2204` |
| msiexec | `/qn /norestart` | 禁止自动重启 |

CUDA 编译工具装的是 `cuda-nvcc`、`cuda-cudart-dev`、`cuda-cccl` 及依赖，不是完整 CUDA toolkit。两个扩展已用现有头文件编过，不必先补全 toolkit。

授权见 `configs/install-authorization.md`。离线包验收：`reports/offline-ready.json`。

## 明确不做

- 预览版 WSL、自动重启、盲目 DISM RestoreHealth、改 BCD、换驱动、造 IWslSupport 注册表
- 重装 WSL / Ubuntu / 显卡驱动，或把训练改到纯 Windows
- 重装 `/opt/gs/env/gs-sfm` 或 `/opt/gs/env/pgsr`
- 混装 cu118 与 cu124；把 cu118 `.partial` 或 Windows 残缺 wheel 交给 pip
- 再跑 `04-setup-training.sh` 从官方 index 覆盖已装 torch
- 用户未要求时启动 `06-train-pgsr.sh`
- 把 Chocolatey shim 或 `where ffmpeg` 第一项当可用工具
- 把 Windows nvcc 13.2 当成 WSL 内 toolkit
