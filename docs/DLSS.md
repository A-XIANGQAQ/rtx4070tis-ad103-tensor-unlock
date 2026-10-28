# DLSS 与帧生成：这次解锁对它们没有可测量的收益

结论很短：解锁只开 FP32-累加那条 tensor 路径，DLSS 超分走 FP16 累加、帧生成走 OFA，
两条都不在这条线上。

| 路径 | 用什么硬件 | 受这次解锁影响吗 |
|---|---|---|
| **帧生成 (Frame Generation)** | Optical Flow Accelerator，独立单元 | **否** |
| **DLSS 超分** | tensor core `HMMA.16816.F16`（FP16 累加） | **否** |
| 本次解锁 | `HMMA.16816.F32` / `BF16.F32` / `FP8.F32`（FP32 累加） | 是 |

## 实测

3DMark（Steam app 223850），DLSS 开与关各测解锁前后一次：

```
DLSS off:  33.72 FPS  ->  33.75 FPS     +0.09%
DLSS on : 126.22 FPS  -> 126.48 FPS     +0.21%
```

两个差值都在噪声内。原始结果文件没有留存，只有这四个数。

## 为什么

- `f16/f16` 解锁前后都是 176–188 TF/s，已是 sm_89 的 FP16 tensor 峰值；解锁后它和
  `f16/f32` 同速，说明这条路径没有余量。DLSS 超分走的是 FP16 累加那条。
- 帧生成用 OFA，不碰 tensor core。`s8/s32` 解锁前后不动，INT8 也满速。

所以这条路不提升 DLSS 和帧生成。DLSS 的某个版本是否走 FP8、走哪条 tensor 路径、要不要
额外的模型文件，本仓库没有测过。

会变快的是 FP32 累加的 tensor 路径：`f16/f32`、`bf16/f32` 各 2.00×，`e4m3/f32` 的
指令发射率 1.87–2.19×。最后这个是发射率不是 GEMM，上游那张卡上真实的 FP8 GEMM 只有
0.3%（见 [EVIDENCE.md](EVIDENCE.md)）。FP8 推理实际能快多少，取决于 kernel 卡在哪一环。

## 想自己测帧率的话

1. **两组数据分开开机测。** 解锁在断电后就没了，所以 stock 那组必须先测、测完再解锁；
   或者先测解锁组、断电、再测 stock。两组之间只允许解锁这一项不同：同驱动、同 VBIOS、
   同分辨率、同测试项、同一张表。
2. **每组开测前先记解锁状态。** 跑 [`tools\verify-unlock.ps1`](../tools/verify-unlock.ps1)
   （不带 `-RunNumber`，它取最新那份日志），看 `f16/f32 / f16/f16` 这个比值：0.50 附近是
   stock，1.00 附近是解锁。这个比值是自比的，所以不受绝对频率影响；但如果它落在两档中间，
   说明那一轮的频率不稳，重测。
3. **跑测试的时候把结果存下来。** 3DMark 的 `Results` 目录
   （`C:\ProgramData\UL\3DMark\Results`）跑完会有 `.3dmark-result`，把它连同当时的
   `nvidia-smi --query-gpu=clocks.sm,power.draw,temperature.gpu --format=csv`
   一起留着。没有这两个文件，数字就还是「记下来的」。
4. **只用同一个测试项的同一张表比。** 25 个 DLC 里只有 `nvidia-dlss-test` 是 DLSS
   专项；`port-royal-test` 是光线追踪，跟 DLSS 无关。
