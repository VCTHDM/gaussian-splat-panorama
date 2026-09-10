# 候选管线：47 秒视频 → 高斯 + 地形网格

状态：**候选，尚未正式。** 2026-09-10 在本机对最短视频实际跑通。给 GPT 验收：过程没问题再升为正式管线。进度仍只记 `TODO与进度.md`；版本锁在 `docs/environment.md`。

本文只写**已经执行并出产物**的步骤。不要把未跑的脚本、旧任务书或 30,000 轮基准验收写进来。

## 结论（验收时先看这里）

对 `全景素材/f640ef4cc3c8cbda0df51f7eb2d79368.mp4`（47.6 秒，1280×640 全景）已经得到：

- 可打开的高斯：`jobs/shortest-pilot/results/gaussian-local.ply`
- 地形参考网格：`jobs/shortest-pilot/results/terrain-reference.ply`
- 查看：`http://127.0.0.1:8765/viewer/?mode=gaussian` / `?mode=mesh` / `?mode=sparse`

这是 **20 个全景帧的局部场景、相对尺度**，不是 64 帧连成的完整场地，也没有真实尺寸标定。

## 主机与环境（已锁定，验收时不要重装）

| 项 | 实际 |
|---|---|
| Windows | 11，RTX 4070 Ti，驱动 616.56 |
| WSL | `GS-Ubuntu2204`（Ubuntu 22.04.5），`C:\Program Files\WSL\wsl.exe` 2.7.13 |
| 调用方式 | Windows `scripts/sfm/invoke-wsl.ps1` → 发行版 root bash（自动去 CRLF） |
| SfM Python | `/opt/gs/env/gs-sfm`，pycolmap 4.2.0 |
| 训练 Python | `/opt/gs/env/pgsr`，Python 3.10.12，`torch==2.4.1+cu124` |
| CUDA | `CUDA_HOME=/usr/local/cuda-12.4`，nvcc 12.4.131；`TORCH_CUDA_ARCH_LIST=8.9` |
| PGSR | `/opt/gs/vendor/PGSR`；PyTorch3D 未装，`scene/gaussian_model.py` 用 `build_rotation` 替代 `quaternion_to_matrix` |
| 扩展 | `diff_plane_rasterization`、`simple_knn._C` 已编译 |

Windows 入口：

```powershell
scripts\sfm\invoke-wsl.ps1 -LinuxScriptWin <linux脚本> -TimeoutSec <秒> -LogName <名>
```

## 实际执行顺序

```
原视频（不改）
  → 已抽 64 关键帧 / 遮罩
  → 同步到 Linux
  → 384 像素、12 视向 Rig 展开 + COLMAP
  → 取最大局部模型，转 PINHOLE 扁平数据集
  → 装 PGSR 环境（仅首次）
  → demo 7,000 次（独立目录，确认能看）
  → 完整 30,000 次（主目录）
  → TSDF 导出网格
  → 拷到 Windows results，本地 HTTP 查看
```

对应脚本与是否已跑：

| 步 | 脚本 | 本次 | 说明 |
|---|---|---|---|
| 0 | 保留 `全景素材/` 原视频 | 是 | 不上传、不替换、不删除 |
| 1 | Windows `jobs/shortest-pilot/sfm-prep/` | 复用 | 64 关键帧、遮罩、帧映射事先已有 |
| 2 | `linux/02-sync-inputs.sh` | 是（此前） | 拷到 `/opt/gs/work/shortest-pilot/panos` |
| 3 | `linux/03-run-shortest.sh` → `python/run_shortest.py` | 是（此前） | 384×384、12 相机 Rig、COLMAP |
| 4 | `python/prepare_pgsr.py` | 是（此前） | 最大模型 → PINHOLE `pgsr-data` |
| 5 | `linux/04d-install-pgsr-env.sh` | 是 | 装 torch cu124 + 依赖 + 补丁 + 编译扩展 |
| 6a | `linux/06-train-demo.sh` | 是 | 独立 `/opt/gs/work/demo`，7,000 次，确认可看 |
| 6b | `linux/06-train-pgsr.sh` | 是 | 主输出 30,000 次 |
| 7 | `linux/07-export-pgsr.sh` | 是 | `render.py` TSDF，拷 Windows |
| 8 | `scripts/open-shortest-viewer.ps1` | 是 | `127.0.0.1:8765`，仅本机 |

### 不要再跑 / 未纳入候选

| 脚本 | 原因 |
|---|---|
| `04-setup-training.sh` | 会从 pytorch.org 覆盖已装好的 pgsr |
| `04c-download-training.sh` | 旧下载入口；现用 `download_training_wheels.py` |
| `03b-connect-shortest.sh` | 扩大匹配后最大仅 12 帧，训练未采用 |
| 混装 cu118 | 半成品 `/opt/gs/cache/training-cu118/*.partial` 不能 pip |
| 重装 WSL / Ubuntu / 驱动 | 已可用 |

## 各步实际参数与产物

### SfM（384 Rig）

- 工作区：`/opt/gs/work/shortest-pilot/sfm384/`
- 最大局部模型：`sparse/7/`
- **20 个全景帧 / 240 张透视 / 1,465 点**，未把 64 帧连成一场
- 日志：`/opt/gs/work/shortest-pilot/logs/sfm384.log`
- Windows 稀疏点：`jobs/shortest-pilot/results/sparse-local.ply`

### PGSR 输入

- `/opt/gs/work/shortest-pilot/pgsr-data/`
- `sparse/{cameras,images,points3D}.bin` 直接在 `sparse/` 下（PGSR 读这个布局，不是 `sparse/0/`）
- 相机 `PINHOLE 384 384`；图片名去路径平铺
- `image_mapping.json` 记录原 Rig 名 → 训练名

### 环境安装（04d）

1. TUNA 续传 NVIDIA/Triton wheel，SHA256 校验（不能只看文件大小或 zip 头）
2. `pip install --no-index --no-deps` 本地 nvidia / triton / torch / torchvision  
   **必须 `--no-deps`**：`--no-index` 时装 triton 会找 `filelock`，本地没有会失败
3. TUNA 装 `numpy<2`、open3d、opencv-python-headless、lpips、trimesh、scipy、ninja 等
4. 打 PyTorch3D 补丁，`pip install --no-build-isolation` 两个 CUDA 扩展
5. 确认：`torch.cuda.is_available()`、小 tensor、`diff_plane_rasterization`、`simple_knn._C`

日志：`/opt/gs/work/shortest-pilot/logs/pgsr-env.log`

### Demo 训练（确认用，非正式主输出）

`06-train-demo.sh`：输入仍是 `pgsr-data`，输出只写 `/opt/gs/work/demo/`。

- 7,000 次，densify 到 5,000，最多 40 万点，`-r 1`
- 约 6 分钟，~15 it/s，train PSNR 21.15，约 39.5 万点
- Windows：`jobs/demo/results/gaussian-iter7000.ply`

用户看过 demo 后再跑完整训练。正式管线若采纳，demo 可保留为可选预览，不是必经。

### 完整训练（主输出）

`06-train-pgsr.sh` → `/opt/gs/work/shortest-pilot/pgsr-output/`

```
-r 1
--iterations 30000 --position_lr_max_steps 30000
--densify_until_iter 15000
--max_abs_split_points 0 --max_all_points 1000000
--single_view_weight_from_iter 2000 --multi_view_weight_from_iter 2000
--multi_view_sample_num 16384 --opacity_cull_threshold 0.05
--save_iterations 7000 15000 30000
```

实测（4070 Ti，约 46 分钟）：

| 迭代 | train PSNR | 点数 | Windows 拷贝 |
|---|---|---|---|
| 7,000 | 22.28 | ~99 万 | `gaussian-iter7000.ply`（234M） |
| 15,000 | 24.05 | ~99 万 | `gaussian-iter15000.ply`（236M） |
| 30,000 | **25.64** | ~99 万 | `gaussian-local.ply`（236M） |

显存峰值约 6.5 GB。点数顶到 100 万上限。日志：`/opt/gs/work/shortest-pilot/logs/pgsr-train.log`

### 网格导出

`07-export-pgsr.sh`：

```
render.py -m .../pgsr-output --iteration 30000
  --max_depth 30 --voxel_size 0.04 --use_depth_filter --skip_test
```

- 原始：`mesh/tsdf_fusion.ply`，291 万顶点 → Windows `terrain-raw.ply`（137M）
- 后处理只留最大连通块：`tsdf_fusion_post.ply`，206 万顶点 → `terrain-reference.ply`（101M）
- 后处理丢掉大量碎块（聚类数约 5 万），地面主体还在，边缘/植被可能缺
- 地面大坑原因：全景底端是拍摄者身体（已遮罩），TSDF 在行走轨迹下没有深度，院子中间会空一块。处理：`07b-fill-ground.sh` 补封闭孔并抬浅坑，写出 `terrain-filled.ply`。未重训高斯。

日志：`/opt/gs/work/shortest-pilot/logs/pgsr-export.log`

### 查看

`jobs/shortest-pilot/results/viewer/index.html`，Python `http.server` 绑 `127.0.0.1:8765`。

- 高斯：`?mode=gaussian` 读 `gaussian-local.ply`
- 网格：`?mode=mesh` 读 `terrain-reference.ply`
- 稀疏：`?mode=sparse` 读 `sparse-local.ply`

相机初值：`viewer-config.json`（来自 SfM 水平向中间帧）。相对尺度。

## 已知限制（验收时不要当成 bug 瞒过）

1. 训练用的是最大局部模型 **20 帧**，不是全部 64 帧。
2. 无控制点、无米制尺度。
3. 夜景、384 像素；高斯仍有漂浮雾、边缘发虚。
4. 点数被 `max_all_points=1000000` 卡住，15k 与 30k 的 ply 体积几乎一样，提升主要在外观/几何收敛，不是继续加密。
5. 网格 `voxel_size=0.04`、`max_depth=30` 是按场景半径约 6.4 试出来的，未做参数扫描。
6. `01-setup-env.sh` 仍有管道错误传播和 `has_panorama ... or True` 假阳性；本次未靠它重装 SfM。
7. TUNA 的 JSON API 会 404，wheel 文件 GET 可用；WSL NAT 不能用 Windows localhost 代理。
8. 一次只跑一个重任务（训练 / 导出不要并行）。

## 复跑命令（环境已在时）

在仓库根目录 PowerShell：

```powershell
# 完整训练（约 45–60 分钟）
.\scripts\sfm\invoke-wsl.ps1 -LinuxScriptWin .\scripts\sfm\linux\06-train-pgsr.sh -TimeoutSec 10800 -LogName pgsr-full-train

# 导出网格
.\scripts\sfm\invoke-wsl.ps1 -LinuxScriptWin .\scripts\sfm\linux\07-export-pgsr.sh -TimeoutSec 1800 -LogName pgsr-export

# 打开查看
.\scripts\open-shortest-viewer.ps1
```

环境坏了再跑 `04d-install-pgsr-env.sh`。不要跑 `04-setup-training.sh`。

## 建议 GPT 验收的问题

1. 这条「20 帧局部 + 30k PGSR + TSDF」能否定为 47 秒视频的正式管线？
2. demo 7,000 次是否保留为可选预览，还是正式管线只保留 30k？
3. 下一步是把 64 帧连成一场再训，还是先把本局部结果当正式交付？
4. 网格后处理「只留最大连通块」是否可接受，要不要改 `num_cluster` / `voxel_size`？
5. 未跑的 `03b-connect-shortest.sh` 是否从正式管线排除？

验收通过后：把本文改为正式管线，并改 `本机执行架构与Agent分工.md` / `AGENTS.md` 指向这里；在此之前不要当唯一入口。
