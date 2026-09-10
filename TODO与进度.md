# 进度与下一步

更新：2026-09-10，约 16:05（本机时间）。**47 秒高斯+网格已出。** 地面大坑已用补洞网格处理（`terrain-filled.ply`），未重训。候选管线 `docs/executed-pipeline.md`。锁定见 `docs/environment.md`。

## 训练环境（已完成）

目标已达到：`/opt/gs/env/pgsr` 可导入 PyTorch，能用 RTX 4070 Ti，两个 CUDA 扩展可导入。只走 cu124，未混装 cu118。

### 实际版本

- Python 3.10.12，venv：`/opt/gs/env/pgsr`
- `torch==2.4.1+cu124`，`torchvision==0.19.1+cu124`，`torch.version.cuda==12.4`
- `torch.cuda.is_available()==True`，设备 `NVIDIA GeForce RTX 4070 Ti`，小 CUDA tensor 求和为 8.0
- `CUDA_HOME=/usr/local/cuda-12.4`（nvcc 12.4.131），`TORCH_CUDA_ARCH_LIST=8.9`
- `numpy==1.26.4`，`open3d==0.19.0`，`opencv-python-headless==4.11.0.86`，`plyfile==1.1.3`
- 另有 `lpips==0.1.4`、`trimesh==5.1.0`、`scipy==1.15.3`、`ninja==1.13.2`、`tqdm==4.70.0`、`tensorboard==2.21.0`
- CUDA 扩展：`diff_plane_rasterization==0.0.0`、`simple_knn==0.0.0`，均已编译并导入；`simple_knn._C` 为 `.so`
- PyTorch3D 未安装；`scene/gaussian_model.py` 已改为 `from utils.general_utils import build_rotation as quaternion_to_matrix`

### 可运行命令

```bash
export PATH="/usr/local/cuda-12.4/bin:/opt/gs/env/pgsr/bin:$PATH"
export CUDA_HOME=/usr/local/cuda-12.4
/opt/gs/env/pgsr/bin/python -c "import torch, cv2, open3d, plyfile, diff_plane_rasterization, simple_knn._C; print(torch.__version__, torch.cuda.is_available(), torch.cuda.get_device_name(0))"
```

用户要求继续训练时：`scripts/sfm/linux/06-train-pgsr.sh`（经 `scripts/sfm/invoke-wsl.ps1`）。不要重装此环境，不要改走 cu118。

### 环境清单

1. [x] **PyTorch + torchvision + CUDA 运行库**：cu124 一条路线。NVIDIA/Triton wheel 已从 TUNA 续传并校验后装入。
2. [x] **PGSR Python 依赖**：已装入 pgsr 环境。
3. [x] **PyTorch3D 局部替代**：补丁已应用。
4. [x] **两个 CUDA 扩展**：`diff-plane-rasterization`、`simple-knn` 已 `pip install --no-build-isolation`。
5. [x] **最小运行确认**：导入与 CUDA tensor 已通过。日志：Linux `/opt/gs/work/shortest-pilot/logs/pgsr-env.log`。

### 已有环境：直接复用（不要重做）

- WSL2 发行版 `GS-Ubuntu2204`、GPU 驱动接口已可用；不重装 WSL/Ubuntu，不改显卡驱动，不重启。
- SfM 环境 `/opt/gs/env/gs-sfm` 已安装 `pycolmap==4.2.0`，且实际完成重建。不要重装或修改。
- PGSR 源码：`/opt/gs/vendor/PGSR`。
- `build-essential`、`python3-dev`、`libgl1`、`libglib2.0-0` 已安装。
- CUDA 编译工具：`/usr/local/cuda-11.8`（11.8.89）与 `/usr/local/cuda-12.4`（12.4.131）。训练只用 12.4。
- Windows Blender：`C:\Program Files\Blender Foundation\Blender 5.1\blender.exe`。

### 安装过程备忘（环境已完成，不必再下）

- 入口脚本：`scripts/sfm/linux/04d-install-pgsr-env.sh`；wheel 下载：`scripts/sfm/python/download_training_wheels.py`（TUNA 为主、官方为镜像，SHA256 校验）。
- 完整 cu124 wheel 在 Linux `/opt/gs/cache/training/`。cu118 的 `/opt/gs/cache/training-cu118/torch-cu118.whl.partial` 未使用，不要拿去 pip。
- Windows `cache/training-wheels/` 仍是不完整文件，不能安装。
- TUNA GET 实测可用（约 10–30 MiB/s）。WSL NAT 仍不能用 Windows localhost 代理；未改代理、未关 TLS。

## 已有的直接复用

- 输入：`全景素材/f640ef4cc3c8cbda0df51f7eb2d79368.mp4`，47.6 秒，1280×640。
- 64 个关键帧、帧映射和遮罩：`jobs/shortest-pilot/sfm-prep/`。正式 384 像素展开已生成于 Linux `sfm384/images/`。
- Windows FFmpeg 可用；`GS-Ubuntu2204` 的 WSL2 和 RTX 4070 Ti 驱动接口已可用，无需再次安装 WSL 或重启。
- SfM 脚本：`scripts/sfm/`；Linux Python 环境：`/opt/gs/env/gs-sfm`。pycolmap 4.2.0 已安装，64 帧已同步并完成局部重建。
- 已有稀疏模型、demo 高斯、47 秒完整高斯和地形参考网格。

## 继续时直接做

1. [x] **跑 SfM。** 64 帧已同步，768 张 384×384 透视图、固定 12 相机 Rig 已完成展开、匹配和稀疏重建。最大局部模型含 20 个全景帧 / 240 个透视相机 / 1,465 点；未连成完整场景。
2. [x] **跑高斯（完整）。** 30,000 次 exit 0，约 46 分钟。train L1 0.030，PSNR 25.64。ply：`jobs/shortest-pilot/results/gaussian-local.ply`（236M，即 iteration_30000）。
3. [x] **出地形网格。** `07-export-pgsr.sh` exit 0。原始融合 291 万顶点 → `terrain-raw.ply`（137M）；后处理 206 万顶点 → `terrain-reference.ply`（101M）。相对尺度；后处理只留最大连通块，小碎片已滤。

不要求控制点、全量分块、90% 注册率或独立精度报告后才交付。

## 仅在出错时查

- 依赖日志：Linux `/tmp/gs-sfm-setup.log`；暂停记录：`logs/sfm/pause-linux-probe.txt`。
- 安装脚本已知问题：`scripts/sfm/01-setup-env.sh` 的管道错误传播，以及 `has_panorama ... or True` 的假阳性，在使用该脚本时顺手修正，不另开审查任务。
- 上次 Grok 日志：`logs/grok-03-shortest-sfm-20260909-212703990-c21b6186/`。模型进程已在 21:40 左右停止，不自动恢复旧会话。
- 已批准安装范围：`configs/install-authorization.md`。旧待重启、待安装报告不代表现在又需要处理这些事项。
- 环境锁定：`docs/environment.md`、`configs/tools.json`。不要再跑 `04-setup-training.sh`。
- 候选管线（待 GPT 验收）：`docs/executed-pipeline.md`。未验收前不要当成唯一入口，也不要另起一套编排框架。

后续每次只在这里更新：已经生成的文件、当前错误、下一步命令。执行约定见 `AGENTS.md`，路线见 `本机执行架构与Agent分工.md`；旧阶段任务书里的验收关卡不再执行。

## 本次运行产物与下一步

- SfM：Linux `/opt/gs/work/shortest-pilot/sfm384/`，最大模型 `sparse/7/`；日志 `logs/sfm384.log` 位于其上一级工作目录。
- Windows 可用点云：`jobs/shortest-pilot/results/sparse-local.ply`；摘要 `sfm-result.json` 同目录。这是稀疏点云，还不是高斯或网格。
- PGSR 输入已准备：Linux `/opt/gs/work/shortest-pilot/pgsr-data/`。相机转换为 PINHOLE，240 张图片采用唯一平铺文件名，原 Rig 模型保留。
- PGSR 源码：`/opt/gs/vendor/PGSR`。训练环境已就绪，见文档顶部。安装日志：`/opt/gs/work/shortest-pilot/logs/pgsr-env.log`。
- 扩大时间匹配范围的结果在 `sfm384/sparse-wide/`，最大仅 12 帧，训练继续采用原先的 20 帧模型。
- 本地点云查看器：`http://127.0.0.1:8765/viewer/?mode=sparse`，仅绑定本机；重开脚本 `scripts/open-shortest-viewer.ps1`。
- Demo 高斯：Linux `/opt/gs/work/demo/pgsr-output/point_cloud/iteration_7000/point_cloud.ply`（94M）；Windows `jobs/demo/results/gaussian-iter7000.ply`。中途 `iteration_2000` 52M。日志 `/opt/gs/work/demo/logs/pgsr-train.log`。约 6 分钟、15 it/s，train PSNR 21.15，约 39.5 万点。这是 demo，不是 shortest-pilot 最终模型。
- 完整高斯：Linux `/opt/gs/work/shortest-pilot/pgsr-output/point_cloud/iteration_30000/point_cloud.ply`；Windows `jobs/shortest-pilot/results/gaussian-local.ply`。中途 7000/15000 同目录 `gaussian-iter7000.ply`、`gaussian-iter15000.ply`。日志 `logs/pgsr-train.log`。
- 地形网格：查看器用 `jobs/shortest-pilot/results/terrain-filled.ply`（补地面孔/浅坑）。未补版本仍保留：`terrain-reference.ply`、`terrain-raw.ply`。原因是拍摄者挡住天底，TSDF 走不到脚下地面。
- 查看器：`http://127.0.0.1:8765/viewer/?mode=gaussian` 高斯，`?mode=mesh` 已补地面的网格，`?mode=sparse` 稀疏点。重开 `scripts/open-shortest-viewer.ps1`。相对尺度。
