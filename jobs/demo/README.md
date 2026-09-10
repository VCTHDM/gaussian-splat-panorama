# Demo 训练目录

独立于 `jobs/shortest-pilot`。GPT 写的 `scripts/sfm/linux/00-07` 是分步脚本，**没有**一条能编排「训练 → 导出 → 查看」的管线。本目录先用现有脚本出可看的高斯；等管线落成后再切过去。

| 项 | 路径 |
|---|---|
| 输入（复用，不复制） | Linux `/opt/gs/work/shortest-pilot/pgsr-data/`（240 张 384 透视 + PINHOLE） |
| 训练输出 | Linux `/opt/gs/work/demo/pgsr-output/` |
| 日志 | Linux `/opt/gs/work/demo/logs/pgsr-train.log` |
| Windows 拷贝 | `jobs/demo/results/` |
| 训练脚本 | `scripts/sfm/linux/06-train-demo.sh` |
| 主任务脚本（未跑） | `scripts/sfm/linux/06-train-pgsr.sh` → `shortest-pilot/pgsr-output` |

参数与主任务相同：7000 次，2000/7000 保存。不要把 demo 产出当成 shortest-pilot 的最终模型。

## 本次结果（2026-09-10 14:22）

训练 exit 0，约 6 分钟（~15 it/s）。train L1 0.055，PSNR 21.15，约 395,044 点。夜景、384 像素、20 个全景帧的局部场景，相对尺度。

| 文件 | 位置 |
|---|---|
| 7000 次高斯 | `jobs/demo/results/gaussian-iter7000.ply`（94M），Linux 同源 `/opt/gs/work/demo/pgsr-output/point_cloud/iteration_7000/point_cloud.ply` |
| 2000 次高斯 | `jobs/demo/results/gaussian-iter2000.ply`（52M） |
| 调试拼图 | `jobs/demo/results/debug-iter3000.jpg` |
| 完整输出 | Linux `/opt/gs/work/demo/pgsr-output/` |

未导出网格。`07-export-pgsr.sh` 写的是 shortest-pilot 路径，不能直接套到本目录。
