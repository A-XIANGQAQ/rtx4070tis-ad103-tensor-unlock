# 解锁后应用到底快了多少（汇总，2026-10-26）

这是第三方的现场报告汇总，不是本仓库的测量。每条都标了来源与条件，原始数据请点链接。
目的只有一个：回答「我这个应用会不会变快」。

## 一、确实变快了的（都有 before/after 秒数）

### 同一台 PNY RTX 4090，Windows，驱动 617.14（手动 R4 解锁）
来源：`luizwidmer/gpu-unlock-4090-windows` 的 `BENCHMARKS.md`（9 个工作负载的中位秒数，越低越快）

| 工作负载 | 解锁前 | 解锁后 | 倍数 |
|---|---:|---:|---:|
| Qwen 语音合成（warm） | 19.38 s | 12.88 s | **1.51×** |
| MOSS，8 步 + 两个 LoRA | 62.42 s | 43.28 s | **1.44×** |
| ACE 音乐生成 | 46.43 s | 33.25 s | **1.40×** |
| YuE 音乐 | 45.54 s | 34.38 s | 1.32× |
| 音乐分析 | 57.40 s | 45.34 s | 1.27× |
| MOSS，50 步 | 98.57 s | 82.36 s | 1.20× |
| EDMFormer | 14.38 s | 12.24 s | 1.17× |
| LTX 视频（warm，非缓存） | 35.50 s | 30.72 s | 1.16× |
| H3 视频 | 54.42 s | 48.32 s | 1.13× |

### 长 prompt 的 prefill
来源：上游 `JustAResearcher/gpu-unlock-ada` 的 `docs/rtx4080-hardware-report.md`
（RTX 4080 32 GB 改装卡，ExLlamaV3 `1.6.2` + Qwen 27B EXL3 6.0 bpw，8-bit KV cache）

| Prompt | 解锁前 | 解锁后 | 变化 |
|---:|---:|---:|---:|
| 4,089 tokens | 1,785.6 t/s | 2,140.8 t/s | **+19.9%** |
| 16,377 | 1,629.6 | 2,002.1 | **+22.9%** |
| 65,529 | 1,284.4 | 1,630.5 | **+27.0%**（51.0 → 40.2 s） |

### ComfyUI 图像生成（INT8 权重也变快了）
来源：上游 `docs/ada-2882-report.md`（RTX 4060，驱动 615.78.08，Fedora 44）

- Z-Image Turbo 文生图，1024×1024，**INT8 权重**：**9.39 s → 8.25 s（−12%）**，五次中位数
- 报告判断：收益来自**仍以 BF16 跑的部分**（例如 attention），而不是 INT8 的 matmul 本身

### H3 视频（被独立复现过，最可信的一条）
来源：上游 `docs/evidence/rtx4090-595.91.07/README.md`（RTX 4090，驱动 595.91.07）

- 冻结的 H3 BF16 生成：**309.6 s → 267.3 s（少 13.66%）**
- 而且**每次前向输出与最终 AVI/WAV 逐字节一致**；与上表 1.13× 互相印证

### 还有两组「GEMM 也能接近 2×」的对照（说明带宽是否成为瓶颈决定一切）

| 来源 | 卡 | 测量 | 结果 |
|---|---|---|---|
| `unitypit71/rtx4070tisuper-tensor-unlock`（`CASE-STUDY.md`） | 4070 Ti SUPER，Linux，66 SM，9 次 | cuBLAS n=8192 BF16/FP32 | **90.5 → 179.3 TFLOPS（1.98×）** |
| `KohakuBlueleaf/KohakUnlock`（`docs/RESULTS.md`） | 3090（370→360 W） | PyTorch FP16→FP32 8192³ | **73.03 → 122.76 TFLOPS（+68.1%）** |

注意这与本仓库记录的 4090 上「8192³ 只有 1.09–1.14×」互相矛盾。两者都是小样本，差异可能来自
SM 数/带宽比、驱动（615.71.09 vs 610.57.04）或 cuBLAS 选核。这里只记录矛盾，不站队。

### 口径未说明、只能当线索的（不要直接引用为预期值）

| 来源 | 内容 | 为什么打问号 |
|---|---|---|
| `Sticzu/nixos-gpu-unlock` | LTX-Video 2.5（22B INT8 DiT）~18.5→~9.1 s/step（**+103%**）；MOSS-Image ~54.2→~31.8 s（**+70%**） | 全文未写是否同一启动、重复次数、功耗上限与时钟；数字带 `~` |
| `guilhermedemelocabral/3090-unlock-undervolt` | QLoRA 训练在 220 W 上限下「只剩 +19–26%」 | 训练表同时改了解锁/频率/功耗/序列长度四个变量，作者也注明基线是更早的运行 |

## 二、明确没有变快的

| 应用 | 结果 | 来源 |
|---|---|---|
| Qwen3.6-27B **prefill 4096** / **decode 128**（4090） | 2869.6→2911.1 t/s、46.42→46.52 t/s，官方写 "No meaningful gain demonstrated" | 上游 `rtx4090-595.91.07` |
| llama.cpp，27B **IQ2_XS**（4070 SUPER） | pp512 1407.12→1407.03、pp2048 1420.1→1423.8、tg128 45.93→45.93，**全无变化** | 上游 `docs/ada-2783-report.md` |
| llama.cpp，Qwen3.5-4B **Q8_0**（4060） | prompt 3276.87→3290.00 t/s、gen 50.42→50.48 t/s，**无变化** | 上游 `docs/ada-2882-report.md` |
| 量化 MoE 服务（IQ3_S，8K prefill） | 8K **0.983×**、32K 0.993×，decode 在噪声内 | 上游 `rtx4090-48g-modded/serving-workload.md` |
| MiniMax H3 + **SageAttention** | 「几乎没改善，瓶颈不在 FP16 发射率」 | `MatchaCake/ad102-windows-unlock` |
| 游戏 / DLSS / 光追 / INT8 / 逐 token decode / 挖矿 | 机制上不沾这条路径 | `wyx1277.../gpu-unlock-4070tis-ad103-win` |

## 三、规律

- 受益：以 FP16/BF16 密集 GEMM 为主、且不是逐 token 的生成类负载，比如语音合成、音乐生成、
  扩散/视频，以及长 prompt 的一次性编码（prefill）。
- 不受益：逐 token decode（同一个 Qwen 27B：prefill 在 4080 上 +27%，decode 在 4090 上 0%）、
  走 INT8/MMQ 路径的量化引擎（llama.cpp 的 IQ2_XS 与 Q8_0 都测了，pp 与 tg 全无变化）、
  注意力已换成专用算子的负载。

### 更准确的判据：看引擎调用哪条 kernel，不是看模型是否量化

同一张 4060（AD107）上，同一份报告里同时出现了三种结果：

| 路径 | 实测 | 说明 |
|---|---|---|
| torch / cuBLAS GEMM | fp16 **+55%**、bf16 **+58%**、tf32 **+63%**、fp16-acc16 +12%、fp32 持平 | 走的正是被解锁的 FP16/BF16 输入 + FP32 累加 |
| ComfyUI（INT8 权重，但 attention 走 BF16） | **−12% 时间** | 吃到了「仍然用 BF16 的那部分」 |
| llama.cpp（IQ2_XS / Q8_0） | pp 与 tg **均无变化** | 量化 matmul 走 INT8/MMQ，INT8 发射率本来就没变 |

所以判断「我的应用会不会快」，看三件事：权重/激活精度是不是 FP16/BF16、引擎是否用 cuBLAS
这类 FP32 累加 GEMM、这段耗时是不是 prefill/编解码这类密集计算（逐 token decode 永远不受益）。

## 四、数据质量分级（引用别人的数字前先过这一关）

| 级别 | 判据 | 例子 |
|---|---|---|
| **一级：可复核的 matched 对** | 同一张卡、同一驱动、明确 stock/unlocked 两次启动、有原始文件或哈希、有数值校验 | 上游各 `docs/evidence/*`；`luizwidmer` 的九负载表（有 trial 数与哈希校验） |
| **二级：有前后但条件不完全对齐** | 有 before/after，但时钟/功耗/序列长度/引擎版本至少一项不同，作者自己承认 | `guilherme` 的训练表；`bjrasmussen` 的 "Strata decode +10%"（after 只有 3 个请求 vs before 205 个） |
| **三级：只有结果表** | 没有方法学、没有重复次数、没有功耗/时钟说明 | `Sticzu` 的 LTX/MOSS 百分比 |

**只有一级能进「预期值」讨论**；二级只能当方向；三级只能当「有人在这么用」的线索。

## 五、读这张表要注意什么

1. 全部是单卡、跨启动、自动频率的测量；`luizwidmer` 自己写「不能把每个增益都归因为解锁」，
   它的原生 FP16/FP32 报了 2.35×（超过理论 2×），说明时钟/功耗条件未完全受控。
2. 秒数的收益通常小于发射率收益（2× → 1.13–1.51×），差在功耗墙与访存；
   上游另一份证据里解锁峰值 346 W vs 313 W、MMA 与 GEMM 都撞 SW Power Cap。
3. 别把这张表当成你自己的预期值：不同板卡/驱动/功耗上限差别很大，先按本仓库 `bench/` 自测再下结论。
