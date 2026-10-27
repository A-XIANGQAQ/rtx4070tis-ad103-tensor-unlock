# 把 MSI AD104 端口移植到 ASUS B550-I + AD103 时撞到的东西

上游 `windows/ad104-msi` 是在一台 **MSI Z490 + MSI 4070 Ti (AD104)** 上验证的。
换到 **ASUS B550-I + 4070 Ti SUPER (AD103)** 后，preflight 九步里有五步会失败，
`release` 三个 stage 全部失败。原因基本都是「上游那台机器只有一份，这张卡/这块板有两份」。

每条按「症状 → 原因 → 改法」记，都是本机实测定位的。

---

## 1. 日志突然变空，`fault=1`，后续所有诊断都消失

**症状**：某个 `GuLog` 之后，后续所有日志都没了，末尾出现 `fault=1`。

**原因**：`format.c` 是个受限格式化器，只支持 `%s / %u / %x / %X`（可带 `z`/`ll`/`#`/宽度）。
用了 `%p` 会让 `GuFormatV` 返回 `-1`，`BootWrite` 随后把 `Gu.fault` 置真，**之后的
`GuLog` 全部静默丢弃**。所以崩溃点是「第一个用了不支持格式符的日志」，但看不到的
是它之后的一切。

**改法**：把所有 `%p` 换成 `%#llx` + `(unsigned long long)(UINTN)` 转换。

```c
/* 不要 */
GuLog("mode=%p\n", g->Mode);
/* 要 */
GuLog("mode=%#llx\n", (unsigned long long)(UINTN)g->Mode);
```

这个坑会伪装成「代码逻辑错误」，因为日志停在了错误的位置。

---

## 2. `Gops()` 找到 GOP 但 `Path()` 永远不匹配

**症状**：

```
Gops: count=1 stage=0
Gops[0] PATH MISMATCH actual=02010c00d041030a00000000...02030800700301807fff0400
```

上游给的是 `...0203080040030180...`，实际是 `...0203080070030180...`，只差一个字节。

**原因**：这块板在同一个 GPU root port 下挂了**两个**显示子节点：

```
handle A   ACPI根 -> PCI(fn=1,dev=3) -> PCI(fn=0,dev=0) -> ACPI ADR 0x4003 -> END
handle B   ACPI根 -> PCI(fn=1,dev=3) -> PCI(fn=0,dev=0) -> ACPI ADR 0x7003 -> END
```

`LocateHandleBuffer(GopGuid)` 每次只返回其中一个，但 **TextOut / GOP 协议的 owner 边
可能挂在另一个上**。把 `GopPath` 写死成任一个都会有一半情况失败。

注意：probe 上报的 `path.hex` 是 probe 自己重新序列化的结果，不等于 EFI 运行时
`HandleProtocol(h, DevicePathProtocol)` 拿到的原始字节。抓 capture 时以运行时为准。

**改法**：不 pin 单一路径，改成「前缀匹配 + 结构校验」：

```c
static BOOLEAN GpuChild(EFI_HANDLE h) {
  EFI_DEVICE_PATH_PROTOCOL *p=NULL;
  if(Interface(h,&PathGuid,(VOID **)&p)!=EFI_SUCCESS||!p)return FALSE;
  if(!Equal(p,PciPath,sizeof(PciPath)-4))return FALSE;      /* 24 字节前缀，去掉 END */
  const UINT8 *at=(const UINT8 *)p+sizeof(PciPath)-4;
  for(UINTN n=0;n<8;n++){
    UINTN len=(UINTN)at[2]|((UINTN)at[3]<<8);
    if(len<4||len>64)return FALSE;
    if(at[0]==END_DEVICE_PATH_TYPE)
      return len==4&&at[1]==END_ENTIRE_DEVICE_PATH_SUBTYPE;
    at+=len;
  }
  return FALSE;
}
```

然后把所有 `e->handle==Plan.gop` 的地方换成 `GpuChild(e->handle)`，包括
`Consumers()` 的两个循环、`Removed()`、以及 `DisconnectController` 的目标 handle。

---

## 3. `Consumers()` 报 `text=0 virtual=0 gfx=0` 然后 `ACCESS_DENIED`

**症状**：`Gops()` 过了，但 `Consumers counts: pci=1 child=1 text=0 virtual=0 gfx=0 gfx_agent=0x0`。

**原因**：这是 #2 的下游表现。`Gops()` 选中了 handle B，而 TextOut/GOP 的 owner 边在
handle A 上。`Consumers()` 检查 `e->handle==Plan.gop` 时把这些边全跳过了，计数为 0。

**改法**：

```c
/* 计数放宽：GPU 有两个显示子节点，child 会是 2 */
if(pci!=1||child<1||gfx!=1||text>1||virtual>1||!Plan.nv_agent||!Plan.gfx_agent|| ...)
    return EFI_ACCESS_DENIED;
```

同时记录 owner 边实际所在的 handle，供 `DisconnectController` 用（见 #5）：

```c
if(Guid(&e->protocol,&TextGuid)&&e->attributes==0x10&&GpuChild(e->controller)&&!Plan.out_agent){
    Plan.out_agent=e->agent; Plan.gop_text=e->handle; text++;
}
```

---

## 4. `preflight[8] PointerBaseline` / `[9] UsbBaseline` 失败

**症状**：`PointerBaseline=0x8000000000000003`（`EFI_UNSUPPORTED`）。

**原因**：`PointerBaseline()` 要求指针设备的 device path 以 `UsbHostPath` 开头，
而那个数组写死了 USB 控制器在 PCI `fn=0, dev=0x14`。这块板上两个 xHCI 的真实位置是：

```
ACPI根 -> PCI(fn=2, dev=1) -> PCI(fn=0, dev=0)
ACPI根 -> PCI(fn=1, dev=8) -> PCI(fn=3, dev=0)
```

更硬的问题是 `UsbBaseline()` 里有 `if(Plan.usb_host)return EFI_UNSUPPORTED;`，
只允许存在一个 xHCI 控制器。这块板有两个，必然在找到第二个时失败。

**改法**：这两处本质是「USB 拓扑基线」，和解锁事务无关。改成记录不断言：

```c
/* PointerBaseline */
GuLog("pointer: proto=%08x handle=%#llx agent=%#llx usb_path=%u owner=%u\n", ...);
if(e->count!=1||ProtectedHandle(e->handle)||ProtectedHandle(e->agent))return EFI_UNSUPPORTED;
if(*agent&&e->agent!=*agent)return EFI_UNSUPPORTED;
*agent=e->agent;

/* UsbBaseline */
GuLog("usb host: handle=%#llx agent=%#llx path_pinned=%u\n", ...);
if(!Plan.usb_host){Plan.usb_host=e->handle;Plan.usb_agent=e->agent;}
```

---

## 5. `DisconnectController` 返回 `EFI_NOT_FOUND` 或什么都没发生

**症状**：`GPU driver detach return: stage=1 status=0x800000000000000e`

**原因**：上游写的是

```c
b->DisconnectController(stage==3?Plan.pci:Plan.gop, ...)
```

`Plan.gop` 是 `LocateHandleBuffer(GopGuid)` 挑中的那个 handle，但 **owner 边可能挂在
另一个显示子节点上**。对着没有那条边的 handle 调用 `DisconnectController` 不会断开任何东西。

**改法**：记录 owner 边所在的 handle，断开时用它。

```c
EFI_HANDLE ctrl = stage==3 ? Plan.pci
                : stage==1 ? (Plan.gop_text?Plan.gop_text:Plan.gop)
                :            (Plan.gop_gfx ?Plan.gop_gfx :Plan.gop);
s=b->DisconnectController(ctrl, stage==1?Plan.out_agent:stage==2?Plan.gfx_agent:Plan.nv_agent, NULL);
```

---

## 6. stage 3 断开之后 `Expected(3, FALSE)` 失败，`EFI_NOT_READY`

**症状**：

```
GPU driver detach return: stage=3 status=0
STOP: stage=MSI-release status=0x8000000000000006
```

detach 成功但立刻失败，且 detach 之后没有 `Gops:` 日志，说明断在
`Snapshot` / `Expected` / `Alive` 之间。

**原因**：`DisconnectController(Plan.pci, Plan.nv_agent, NULL)` 会**级联**断开子设备。
handle A / B 上的 EDID 边（由另一个 agent 持有）也一起消失了。而 `Removed()` 的
stage 3 原来只覆盖 `e->handle==Plan.pci && e->agent==Plan.nv_agent` 三条边，
那两条级联消失的边被当成 "missing"。

**改法**：stage 3 代表「释放 GPU 根」，之后 PCI handle 和所有显示子节点上的边都应该消失。

```c
static BOOLEAN Removed(const EDGE *e, UINTN stage) {
  if(stage>=1&&GpuChild(e->handle)&&Plan.out_agent&&e->agent==Plan.out_agent&&Guid(&e->protocol,&TextGuid))return TRUE;
  if(stage>=2&&GpuChild(e->handle)&&Plan.gfx_agent&&e->agent==Plan.gfx_agent&&Guid(&e->protocol,&Guid_Gop))return TRUE;
  /* 级联：PCI handle 或任何显示子节点上的残留边 */
  return stage>=3&&(e->handle==Plan.pci||GpuChild(e->handle));
}
```

离线用 capture 里的 179 条边验证过：stage 3 之后 `PCI handle` 剩 0 条，
`console handle` 保留 2 条，正好是 `Expected(3,FALSE)` 需要的状态。

### 6b. 上面这个改法不够：级联会先把 device path 摘掉

**症状**：`Expected(3,FALSE)` 仍然失败，失败的边指向 GOP handle：

```
GPU graph missing: handle=0xc6b2bb18 agent=0xc8684918 controller=0xc6b2bb18
                   protocol=0x387477c2 attributes=0x10 count=1
```

`0x387477c2` 是 Simple Text Output 的 GUID，`handle` 就是日志里打印的 `gop`。
那条边**正是 stage 3 按计划拆掉的**，却被判成「意外消失」。

**原因**：`GpuChild()` 靠 device path 认身份：
`HandleProtocol(h, &DevicePathGuid)` 拿到路径，再比 24 字节 PCI 前缀。
但 `DisconnectController` 会**先卸载 console/GOP 驱动**，unbind 时把 device path
协议从这些 handle 上摘掉，级联释放 handle 是之后的事。所以在
`Expected(3,FALSE)` 执行的那一刻，`GpuChild()` 对那些 handle 一律返回 FALSE。

这是「用会消失的属性做身份判断」的经典错。路径只在驱动绑着的时候存在，
而 stage 3 的全部目的就是解除绑定。

**改法**：身份要缓存。preflight 里路径还活着的时候记一遍：

```c
/* PLAN 里加 */
EFI_HANDLE gpu_child[8];UINTN gpu_child_count;

/* 在 GuMsiPreflight 的 Snapshot(&Original) 之后、Consumers() 之前调用 */
static EFI_STATUS CacheGpuChildren(VOID) {
  EFI_HANDLE *handles=NULL;UINTN count=0;
  EFI_STATUS s=b->LocateHandleBuffer(AllHandles,NULL,NULL,&count,&handles);
  for(UINTN i=0;s==EFI_SUCCESS&&i<count;i++) {
    if(!PathGpuChild(handles[i]))continue;   /* 旧的路径匹配，改名保留 */
    if(Plan.gpu_child_count==8){s=EFI_BUFFER_TOO_SMALL;break;}
    Plan.gpu_child[Plan.gpu_child_count++]=handles[i];
  }
  b->FreePool(handles);return s;
}
/* GpuChild 先查缓存，未命中再回退到路径匹配 */
static BOOLEAN GpuChild(EFI_HANDLE h) {
  if(!h)return FALSE;
  for(UINTN i=0;i<Plan.gpu_child_count;i++)if(Plan.gpu_child[i]==h)return TRUE;
  return PathGpuChild(h);
}
```

回退那一步不能删：`test_msi_release` 的 `GpuChildPath[]` fixture 不填缓存，
靠路径回退才能过。

**已在本机验证**（`RUN0005`，2026-10-26）：`preflight[6b] CacheGpuChildren=0
children=3`，全文再无 `GPU graph missing`，`Expected(3,FALSE)` 通过。

---

## 7. `GuMsiReadyForWindows()` 里的 `PMC_BOOT_0` pin

**症状**：前面全部通过，最后 Windows 不启动。

**原因**：`msi_release.c` 里写死 `chip==0x194000a1`，那是 MSI 那张 AD104 的值。
AD103 是 `0x193000a1`。

**改法**：改成本卡实测值。

```c
return !Gu.fault && chip==0x193000a1 && (cpu&0x10) && ...
```

`cpu` = `GFW_CPUCTL`（`0x110100`），本卡 `0x10`；
`hi` = `WPR2_HI`（`0x1fa828`），本卡 `0`；
`readout` = `FEAT_READOUT_1`（`0x823818`），解锁后应为 `0`；
`plm` = `FEAT_OVR_PLM`（`0x823804`），解锁后应为 `0xffffffff`。

---

## 8. `Driver()` 的身份 pin 全部不匹配

**症状**：`driver[0] size=30912(ref 24576) hash_match=0`。

**原因**：上游把三个驱动的 `ImageSize` / `Version` / `Stop` 偏移 / 代码段 SHA-256
都写死了。换一台机器这三个驱动必然不同，`Driver()` 会直接 `EFI_UNSUPPORTED`。

**改法**：改成结构性检查，把 pin 值只打印不阻断。

```c
/* 只验证这确实是一个 boot-services 代码映像 */
if(!im->ImageBase||im->ImageCodeType!=EfiBootServicesCode)return EFI_UNSUPPORTED;
/* 其余全部只记录 */
GuLog("driver[%u] size=%zu(ref %zu) ver=%#x(ref %#x) stopoff=%#zx(ref %#zx) hash_match=%u\n", ...);
return EFI_SUCCESS;
```

本卡的三个驱动大小分别是 30912 / 22080 / 162496，和上游的 24576 / 14816 / 162016
完全不同。

---

## 9. 上游要求「必须从 USB 启动」，装到内置盘会被拒

**症状**：把同一份 EFI 放到内置 ESP，`GuBootOpen` 返回 `EFI_ACCESS_DENIED`，
程序什么都不做就退出，连 Windows 都不启动。

**原因**：`boot_io.c` 里

```c
if(s!=EFI_SUCCESS||!Inspect(path,&length,&usb,&windows)||!usb)return EFI_ACCESS_DENIED;
```

文件头注释也写着 `/* USB log/assets only. Windows ESP is opened read-only. */`。
另外 `GuBootLoadWindows` 里有 `volume==OwnVolume → EFI_NOT_FOUND`，而从 ESP 启动时
两者是同一个卷。

**改法**（如果要装 ESP）：

```c
/* 1) 允许内置卷 */
if(s!=EFI_SUCCESS||!Inspect(path,&length,&usb,&windows))return EFI_ACCESS_DENIED;
/* 2) 允许同卷交接 */
if(s!=EFI_SUCCESS||matches!=1)return EFI_NOT_FOUND;
/* 3) 链式目标改名，避免自己启动自己 */
static const CHAR16 WindowsName[]=L"\\EFI\\Microsoft\\Boot\\bootmgfw.orig.efi";
```

**本仓库不用这条路**，见 README 的易失性一节。

---

## 10. 失败之后屏幕冻结，必须断电

**症状**：任何一步判定失败，屏幕停在最后一行，只能强制关机。

**原因**：`app.c` 的失败路径里，只要 `GuMsiMutated()||Gu.started||Gu.retained`
有一个为真就 `GuBootHalt()`。而 `Plan.mutated` 从 stage 1 起就是 TRUE，所以
release 阶段之后的所有失败都会 halt。

**改法**：把「判定失败」和「硬件不安全」分开。硬件安全就照常启动 Windows。

```c
failed:
  if(s==EFI_SUCCESS)s=EFI_DEVICE_ERROR;
  GuLog("STOP: stage=%s status=%#llx mutated=%u retained=%u fault=%u safe=%u\n", ...);
  if(Gu.started||Gu.retained||!GuSafeToReturn()) {
    /* 真的不安全：GPU 卡在 reset 里或 DMA 没释放，交给 Windows 会蓝屏 */
    if(Gu.started||Gu.master_attributes_pending)(VOID)GuClearMaster();
    (VOID)GuBootClose(); GuBootHalt(); return EFI_ABORTED;
  }
  /* 只是某个 gate 拒绝：照常进 Windows，让人能测 */
  (VOID)GuBootClose();
  return GuBootWindows();
```

配套把 `Expected()` / `attrs` / `supported` 这些图相等性检查降级成日志。它们原本是
「证明固件行为符合预期」的断言，在移植阶段会挡住真正的进度。

### 10b. 光「不 halt」还不够：halt 的时候没人看得见

**症状**：屏幕停在一帧，不滚动、不提示，操作者据此判断「卡死」，按重启键。

**原因**：`app.c` 在启动事务前调用 `GuBootSilence()`，因为接下来要把显示驱动
卸掉，控制台随时会消失。这个选择是对的。问题是它没有对应的「恢复」：
`GuBootHalt()` 里那句 `STOPPED.` 走的是 `GuBootSay()`，而 `GuBootSay()` 在
`Silent` 为真时直接 return：

```c
VOID GuBootSay(const CHAR16 *text) {
  if(Silent)return;          /* ← 连 "STOPPED" 一起吞掉 */
  Table->ConOut->OutputString(Table->ConOut,(CHAR16 *)text);
}
```

于是停机时屏幕没有任何输出，操作者只能按重启，重启清掉易失的 `SS0`/`SS1`，把已经
成功的解锁送掉。

**改法**：所有终止路径第一步先撤销静默。

```c
VOID GuBootWake(VOID){Silent=FALSE;}

VOID GuBootHalt(VOID) {
  GuBootWake();                 /* 先恢复输出 */
  GuBootSay(L"\r\nSTOPPED. Power OFF fully; next boot use Windows Boot Manager.\r\n");
  for(;;)__asm__ volatile("pause");
}
```

`GuBootSilence()` 建立的不变量应该是「静默只覆盖事务体，出口一定恢复」。

**已在本机验证**（`RUN0005`）：日志末尾没有 `STOPPED.`，说明这次没走到 halt；
这条改动的价值在「下次真被拒时能看见」，两次成功运行都不构成对它的验证。

### 10c. 关日志被记成硬件故障，把每一道后续门都毒死

**症状**：日志最后一行是 `TRANSACTION OK`，后面没有任何解释，`fault=1`。

**原因**：旧 `GuLog()` 把「日志已经关了」当成故障：

```c
if(n==(size_t)-1||n>=sizeof(buffer)||!Log){Gu.fault=TRUE;return;}
```

而 `app.c` 里所有 `Gu.fault` 检查都排在 `GuBootClose()` 之后。
主动关日志这个正常动作，因此会污染之后每一个 gate。典型顺序：

```c
GuLog("TRANSACTION OK: …");
stage="close-USB-log";s=GuBootClose();if(s!=EFI_SUCCESS||Gu.fault)goto failed;
stage="final-Windows-verification";if(!GuMsiReadyForWindows()){…}  /* 这里已经中毒 */
```

**改法**：区分「按计划关闭」和「写失败」。

```c
static BOOLEAN Silent,Sealed;
VOID GuLog(const char *format,...) {
  if(Sealed||!Log)return;                        /* 按计划关闭：静默 no-op */
  ...
  if(n==(size_t)-1||n>=sizeof(buffer)){Gu.fault=TRUE;return;}
}
EFI_STATUS GuBootClose(VOID) {
  ...
  if(s==EFI_SUCCESS)Sealed=TRUE;                 /* 只有干净关闭才 seal */
  return s;
}
```

失败信息进不了日志的时候，就把它打到屏幕上，也就是 10b 的 `GuBootWake()`。

最后那道门也挪到了关日志之前：

```c
/* 之前：先关日志再检查 → 拒绝的理由写不进日志，日志停在 OK 上 */
/* 之后：先检查再关日志 → 拒绝会留下 stage 名和状态码 */
stage="final-Windows-verification";if(!GuMsiReadyForWindows()){s=EFI_NOT_READY;goto failed;}
GuLog("TRANSACTION OK: … handoff check passed …\n");
stage="close-USB-log";s=GuBootClose();if(s!=EFI_SUCCESS||Gu.fault)goto failed;
```

日志停在 `OK` 上没有下文，说明失败发生在看不到的地方。

**已在本机验证**（`RUN0005`）：末行变为
`TRANSACTION OK: … handoff check passed; benchmark still required`，
`handoff check passed` 这几个字出现在日志里，说明检查确实跑在关日志之前。

### 10d. 把 `%p` 写进日志格式化器会导致整份日志静默

**症状**：日志在某一行之后突然没了，`fault=1`，后面什么都写不进去。

**原因**：`boot_io.c` 里的格式化器是受限实现，只认 `%s %u %x %X`（含 `z`/`ll`/
`#`/宽度）。`%p` 走到 `GuFormatV()` 的 default 分支返回 -1，`GuLog` 据此
`Gu.fault=TRUE` 后返回，于是从那一行开始，每一行日志都被丢掉。

**改法**：指针一律 `%#llx` + `(unsigned long long)(UINTN)`：

```c
GuLog("gop=%#llx\n", (unsigned long long)(UINTN)Plan.gop);
```

同一族的坑：`GuLog` 内部缓冲区固定大小，格式化结果超长（`n>=sizeof(buffer)`）
同样置 fault 并丢弃。写长行之前先算一下。

日志停在某一行时，先查那一行，再查它后面的逻辑有没有跑。

---

## 11. 测量必须在空闲 GPU 上做

**症状**：`f16/f32` 第一次跑 180.5，第二、三次塌到 32.8 / 2.0；`s8/s32` 从 350 掉到 199。

**原因**：后台有游戏占了 100% GPU 和 11 GB 显存。

```
nvidia-smi --query-compute-apps=pid,process_name
```

**改法**：跑 benchmark 前确认 GPU 空闲。`nvidia-smi` 里 `utilization.gpu` 应该是 0，
`power.draw` 应该接近待机功耗。这个坑很容易被误读成「解锁把卡搞坏了」。

留在 `results/cublas-contaminated.txt` 就是因为它是这个坑的原始证据。

## 12. cuBLAS 按**计算类型**的宽度读 `alpha`/`beta`

**症状**：`fp16/fp16acc` 报出 4000–4700 TF/s，比物理峰值高一个数量级以上；
换成别的 `computeType` 就正常。

**原因**：`cublasGemmEx` 的 `alpha`/`beta` 是 `const void *`，cuBLAS 按
`computeType` 的宽度去读，不是按你传的变量类型。传 `float 1.0f`、同时把
`computeType` 设成 `CUBLAS_COMPUTE_16F` 时，cuBLAS 只取低两字节，而 `1.0f` 的
低两字节恰好是 `0x0000`，于是 `alpha` 被读成 `__half 0.0`。结果每个输出元素都是
`0*A*B + 0*C = 0`，**矩阵全零**，kernel 的实际工作量塌掉，计时器被自己的 bug 缩短。

本机决定性证据（`bench\build.cmd f16acc` 编出来的 `probe_f16acc.exe`，
同一份数据同一张卡）：

```
float-alpha  (float* as compute16F scales):  4188.85 TF/s   (0.262 ms/gemm)
   nonzero C: 0 / 67108864        <-- all zeros
half-alpha   (correct compute16F scales)  :   143.77 TF/s   (7.648 ms/gemm)
   nonzero C: 67108852 / 67108864
```

这个探针现在还能跑（`bench\build.cmd f16acc`），在 320 W 的 stock 卡上重跑一次
是 `4668.65 / 152.90 TF/s`，`nonzero C` 仍然是 `0` 与 `67108852`。绝对值随频率和
功耗上限移动，全零与非零这两件事不动——所以判据看 `nonzero C`，不看 TF/s。

**改法**：`alpha`/`beta` 的类型跟着 `computeType` 走。

```c
const float  fAlpha=1.f, fBeta=0.f;
const __half hAlpha=__float2half(1.f), hBeta=__float2half(0.f);
const void *pa=&fAlpha, *pb=&fBeta;
if(c.comp==CUBLAS_COMPUTE_16F){ pa=&hAlpha; pb=&hBeta; }
```

并且每个用例都验证输出非零：一次不计时的 GEMM 加 `count_nz`，

```cuda
template<typename T> __global__ void count_nz(const T *p,long n,int *out){
  long i=(long)blockIdx.x*blockDim.x+threadIdx.x;
  if(i<n&&p[i]!=T(0))atomicAdd(out,1);
}
```

全零时打出 `<-- BROKEN`。这条闸门是必须的：没有它，这个 bug 只会表现为
「数字好得不像话」，很容易被当成解锁效果写进结论。

旧 cuBLAS 采样（`fp16/fp16acc` 4588/4744，`results/cublas-contaminated.txt` 之外）
就是被这个 bug 污染的数据，已重采。

## 13. 加载 VBIOS override 之后，SS0/SS1 读到 0，闸门把整条路拒掉

改功率上限用的是注册表 override（`vbios` 二进制 + `EnableGpuFirmware`），不刷 flash。
装好之后六次冷启动全都停在 `read-only-cold-profile`，日志只有三行、字节完全相同：

```
AD104 MSI EXPERIMENTAL v0.5.4: ...
cold-profile selector mismatch: SS0=0 SS1=0 wantSS1=0x1
STOP: stage=read-only-cold-profile status=0x8000000000000006 mutated=0 retained=0 fault=0
```

六份日志 sha256 都是 `8F61DB14...`，跨 3 小时、跨两种 payload，逐字节相同。

**这两行说明的事，比它看起来多。**

`cold-profile selector mismatch` 是在 `profile.c` 里 19 个 pin **全部匹配之后**
才打印的。如果 pin 有任何一个不符，日志会是
`cold-profile register mismatch: idx=.. off=.. got=.. want=..`。
所以「读到 0」不是身份认错了，是这块卡在这个状态下 `0x82381c` / `0x823820`
真的返回 0，19 个其它寄存器仍是 stock 值。

`fault=0` 也值得注意：`GuRead32` 读失败会置 `Gu.fault`，而
`profile.c` 的循环里每个 pin 后都查 fault。fault 一直是 0，说明读操作本身成功，
0 是被读出来的值。

**根因不是「override 覆盖了 SS0」**。逐字节比对四个 payload 和原厂 ROM：

- `power_default_w` 在窗口 `0xBF89`，`power_max_w` 在 `0xBF8D`，单位 mW
- v2（default 320 / max 320）与 v1（default 285 / max 320）差 **7 字节 / 4 段**：
  `0xBF89 4859->00e2`（285000->320000）、两处输入电流槽 `0xC206` 与 `0xC261` 各
  `546f->d084`（28500->34000 mA）、`0xFBFF` 一个 additive_checksum 字节。只差
  3 字节的是 `v1 -> b320`（默认档加校验和），b320 没动电流槽
- 512 KiB 窗口的校验和规则是 `sum(0..0xFBFF) + b[0xFBFF] ≡ 0 (mod 256)`，
  五个镜像（含原厂 dump）全部符合
- 四个 payload 里搜 `0x0082381c` / `0x00823820` / `0x00823804` / `0x27304036`
  / `0x00410080` / `0x00000233`：**全部 0 命中**

所以 override 镜像里根本没有 SM 寄存器初值。冲突来自固件初始化路径被改变，
不是某个字段被覆盖。

`RUN0006`（10-27 20:54:40）那次冷启动读到
`entry: plm=0xffffff8f ss0=0x27104036 ss1=0x1`，`SS1=1` 正常，事务全程通过；
此后六次全部读 0。但**那次开机挂着哪一份 override 没有直接证据**：
`load-v2.log`（21:06:32）的 `before.vbios` 是 v1 的窗口哈希，证明那一刻注册表里
是 v1；`loader-payload.bin` 的 mtime 是 20:44，20:44 到 21:06 之间没有任何 load
日志；唯一的注册表快照 `classkey-0001-before-coldboot.reg` 是 23:21:37 取的，
里面已经是 v2。所以「v1 能过、v2 不能过」只有时间顺序的旁证，没有直接证据。

**改法**：让解锁侧接受两种入口态，不去动 override 那边。

```c
BOOLEAN stock=(*Ss1==0x1U),blank=(*Ss0==0U&&*Ss1==0U);
if(*Ss0==0xffffffff||(*Ss0&0xffff0000)==0xbadf0000||*Ss0==0x88888888||(!stock&&!blank)){
```

同时 `unlock_610.c` 主闸门的 `ss1!=1` 改成 `!(ss1==1 || (ss0==0 && ss1==0))`。

**只放开这一条就够了**。主闸门剩下那五个合取项，在六份失败日志里已经被证明成立：
`profile.c` 先过 19 个 pin、再读 SS0/SS1，日志里既然没有
`cold-profile register mismatch`，说明那 19 个都是 stock 值，而主闸门比的正是其中五个：

| 主闸门条件 | 来源寄存器 | `profile.c` 的 pin |
|---|---|---|
| `plm_entry == 0xffffff8f` | `0x00823804` | `0xffffff8f` |
| `sample.plm == 0x8b8f` | `0x00118128` | `0x8b8f` |
| `sample.boot == 0x3ff` | `0x00118234` | `0x3ff` |
| `sample.cpuctl == 0x10` | `0x00110100` | `0x10` |
| `wpr_hi == 0` | `0x001fa828` | `0x0` |

`inaccessible(ss0)` 对 `ss0=0` 也不成立（它只拒 `~0` 和 `0xbadf0000` 段）。

所以 `ss1!=1` 是当时唯一挡住路的合取项，不是「第一道」。六份失败日志里既没有
`register mismatch` 也没有 `config mismatch`，与此一致。

能这么改是因为全链路本来就不写死 SS1 的值：

- `port.c` 的 `GuEntrySelectorsMatch` 比对的是 `Ss1==EntrySs1`，不是字面量 1
- `GuLatchEntrySelectors` 的闸门是 `Ss1>0xfU`，blank 态本来就能过
- `GuSelectorPhase` 状态机在 `SS0_WRITTEN` / `SS1_WRITE` 阶段要求
  `ss1==entry1`，blank 态下 `entry1=0`，自洽
- `check_entry_selectors` 用 `b!=work->ss1_entry`，同样自洽
- pre-FLR / post-FLR 要求的是写入后的目标值 `0x88888888` / `0x8`，与入口态无关

验证方式不是看日志（成功的 permutation 静默通过，`GuLog` 只在失败时打），
而是数场景条数：`test_efi_transaction` 的 30 个 scenario 各跑 4 次
（3 个 stock SS0 变体 + 1 个 blank），日志里 `EFI integration` 恰好 120 条。

**顺带修掉的三处上游夹具残留**。`test_efi_transaction` 在这个端口上从来跑不起来，
一层层挖下去全是上游 AD104 卡的常量：

| 位置 | 上游值 | 这台机器 |
|---|---|---|
| `tests/captured_config.h` | device `0x2782`，bus 1 | `0x2705`，bus 8（来自 `CAP0002.JSON` 的 `config256`） |
| `location` 桩 | `*b=1` | `*b=8` |
| `setup()` 寄存器 | `registers[0]=0x194000a1`、`0x1183a4=0x2800`、`0x1fa830=0x2ef9ff0` | `0x193000a1` / `0x3ff8` / `0x3cf7ff0` |
| `gpu_unlock_610_load_shared` 的 device | 测试写 `.device=0x2782` | `.device=0x2705` |
| `tests/test_guards.c` | 两处 `0x2782` | 一为 `0x2705`，case 8 保留 `0x2782`（它的作用就是测「认错卡要拒」） |
| FWSEC 几何 | `image_off=0x45488`、`image_size=0x10300` | `0x45b48` / `0x10500` |
| WPR2 桩 | `0x2ff8000` / `0x2ff8ff0` | `0x3ff6000` / `0x3ff6e00` |
| booter 发布地址 | `delta=0x7fa00000` 偏移法 | 直接写本机布局真值 |
| 失败路径断言 | `registers[SS1/4]==1` | `==test_entry_ss1` |

`0x5053000` 那两个硬编码**不是残留**：`gsp_ga10x.bin` 的 `.fwimage` 段就是
`0x5053000`，radix 计划 `[1,1,41,20563]` 由此推出。

修完之后 `test_efi_transaction` 第一次返回 0：30 scenario / 120 条 integration 行
（当时计数器还写着 `SCENARIO_COUNT*3`，所以打印的 90 是错的，见 #15 那次的修正）。
`test_guards` 的 17 个 admission case 也全过。

**顺序教训**：不要一次把可疑常量全改掉。跑一次、看一条断言、改一条。
上面那张表里 `0x5053000` 差一点被当成上游残留改掉，是「只改当前断言指的那一条」
这个纪律把它挡住的。

## 14. `Sealed` 是会话级状态，但只在关日志时置位、从不复位

`test_boot_io` 在这个端口上也从来跑不起来：它 pin 了上游的 bootmgr 长度
`3086728`，这台机器是 `3086680`，case 循环在第一次长度检查就中止，
后面的 case 一个都没执行过。

把夹具改成读实际长度之后，case 0 通过，case 3 之后开始出现
`Gu.fault` 为真但日志里什么都没有的现象。原因是 `boot_io.c` 的两个静态量：

```c
static BOOLEAN Silent,Sealed;
...
VOID GuLog(...) { if(Sealed||!Log)return; ... }
...
EFI_STATUS GuBootClose(VOID) { ...; if(s==EFI_SUCCESS)Sealed=TRUE; return s; }
```

`GuBootOpen` 从前不复位 `Sealed`。固件只调用一次，所以出货的路径**
没有暴露过**这个问题，但任何「关掉再打开」的用法都会在第二次静默丢弃
全部日志，而且 `GuLog` 是静默返回的，调用方看不出是日志没写还是代码没跑。

改法是在会话开始处复位，与 `Log=NULL` 的语义对齐：

```c
EFI_STATUS GuBootOpen(...) {
  if(Table)return EFI_ALREADY_STARTED;
  ...
  Sealed=FALSE;
  Table=t;Self=image;
```

这类状态位的通病：置位点写得清清楚楚，复位点依靠「只会用一次」这个
未写下来的假设。判据不是读代码，是让第二个会话真的发生一次。

**同时修掉的夹具问题**（`tests/test_boot_io.c`）：

| 项 | 原样 | 改法 |
|---|---|---|
| bootmgr 长度 | pin `3086728` | `FileAuto()` 读实际大小（Windows 更新会换掉它） |
| `BAD_WINDOWS_HASH` | 改一字节后要求 `LoadWindows` 失败 | 这个端口故意不 pin 摘要，改成 `CHANGED_WINDOWS_IMAGE`：改了也必须能交棒 |
| 日志桩 | 只保留最后一次 `Write` 的内容 | 逐次追加，因为 `GuLog` 一行一次 `Write` |
| ESP 几何 | 已在用这台机器的真值 | 保留（disk 3 / 分区 1 / sector 2048 / 614400 扇区） |

修完 `test_boot_io` 第一次返回 0：615 checks / 8 cases。当时四个套件同时变绿
（`app_flow` 272 checks / 15 scenarios、`guards` 17 cases、
`efi_transaction` 120 scenarios、`boot_io` 615 checks）；第五个
`test_msi_release` 随后靠 #15 那次修复才跑起来。

## 15. 为了绕过 `GpuChild()` 而放宽的图检查，修好匹配器之后变成了「检查没跑就宣告成功」

`GpuChild()` 的匹配 bug（见 #2、#3）当年是这么绕过的：把 `msi_release.c` 里九处
图比较从硬失败改成「记一行日志然后继续」。

```c
if(s==EFI_SUCCESS&&!Expected(stage-1,FALSE)){GuLog("stage %zu pre-graph drifted; continuing\n",(size_t)stage);}
if(s==EFI_SUCCESS&&Alive()!=EFI_SUCCESS){GuLog("stage %zu console changed; continuing\n",(size_t)stage);}
if(s==EFI_SUCCESS&&Gops(FALSE)!=EFI_SUCCESS){GuLog("stage %zu gop enumeration failed; continuing\n",(size_t)stage);}
```

`GpuChild()` 修好之后这批分支再没被触发过。硬件日志能证明：真正解锁成功的
`RUN0005` 与 `RUN0006` 里一行 drift 都没有，它们只出现在 `GpuChild()` 修好之前的
`RUN0001`/`RUN0002`/`RUN0004`。

其中两处比死代码更糟：

```c
else if(!ConfigStable(c))GuLog("release: pci config drifted (tolerated)\n");
else if(...attrs!=Plan.attributes)GuLog("release: attributes ... (tolerated)\n");
```

它们是 `else if` 链的末段，命中后 `failed` 仍然是 `NULL`，于是 `GuMsiReleased()`
返回 `TRUE`：**配置检查和属性检查根本没跑，却被当成通过**。

判断这批代码该不该在，不要读注释，查两个东西：上游同名文件对应行是不是硬失败
（`origin/main:windows/ad104-msi/msi_release.c` 是 `s=EFI_NOT_READY` 与
`failed="config-drift"`），以及真实成功日志里有没有这些行。两个都对上之后
恢复硬失败，`test_msi_release` 也随之第一次跑通（763156 checks / 47 cases）。

保留的一条是上游自带的 `PCI status drift tolerated`（`ConfigStable()` 里），
它的条件很窄：`Gu.flrs==1`、只允许在 `0x80` 这一个 dword 上、
`Plan.config[0x78/4]==0x0012b410`、且漂移位必须在 `0x00090000` 之内。

**这类「放宽」的共同点**：当时是为了让某次运行过掉，事后没人记得它的存在理由。
它的保质期只到被绕过的那个 bug 修好为止。

## 16. `profile.c` 是生成文件，手改会丢

`windows/ad103-2705/profile.c` 第一行就写着：

```c
/* GENERATED by rtx2705/tools/gen_profile.py -- do not hand-edit.
```

它由 `G:\workspace\rtx2705\tools\gen_profile.py` 从探针的
`captures\CAP0002.JSON` 生成。改闸门（#13 那个 `stock` / `blank` 分支）、
改 19 个寄存器 pin、改 PROM 哈希，都要改**生成器的模板**
（当前在 `gen_profile.py` 的 `:330-344`），否则下一次重新生成会静默覆盖掉。

生成器本身在本仓库里有一份跟踪的副本 `tools/gen_profile.py`，与
`rtx2705` 下那份逐字节相同（都是 18587 B / `928832CC...`）。改模板时两份都要改。

那份副本带 `GPL-2.0-only` 标识不是笔误：它内嵌了上游 `profile.c` 的函数体，按 GPL
算衍生作品。其余脚本与 `bench/` 下的探针都是 MIT。

判断仓库里这份和生成器有没有漂移，不要读代码，直接重生成再比哈希：

```
python G:\workspace\rtx2705\tools\gen_profile.py G:\workspace\rtx2705\captures\CAP0002.JSON ^
    --out %TEMP%\genprof\profile.c --json-out %TEMP%\genprof\consts.json
Get-FileHash %TEMP%\genprof\profile.c
Get-FileHash G:\workspace\gpu-unlock-ada\windows\ad103-2705\profile.c
```

两边相等（本机实测都是 `FDD0C589...`）才说明模板和源码一致。

生成器同时会把本机的几项事实打进注释里，可以直接当核对用：

```
PROM sha256 : 89097b6342061cc98277542476869eea222e20a62dce386d1fdb0f587f208f36
device      : 0x2705 subsys 0x1771:0x10de rev 0xa1
PCI location: bus 8
SS0/SS1 stock : 0x27304036 / 0x1
FWSEC       : image_off=0x45b48 imem=0xf700 dmem=0xd80 ucode=9 engines=0x400
```

## 17. `vbios-loader.exe` 只有在 `G:\workspace` 下面才解得开自己

它是个 PyInstaller onefile。用默认 `TEMP` 直接跑会这样：

```
> G:\workspace\vbios-4070tis\vbios-loader.exe verify --json
Error, failed to open 'C:\Users\ctxia\AppData\Local\Temp\onefile_17184_996458_mFL5Bi7-Mvs\entry.dll' for writing.
exit code: 2
```

报错说「打不开 `entry.dll` 来写」。onefile 启动时必须把自身解包到 `TEMP` 里，
所以这条错误真正说的是：**这个进程写不了 `TEMP`**。

真正起作用的不是 `TEMP` 的位置，是**可执行文件自己的位置**。用一段只做
`fopen` 的探针（同一份二进制换地方放）测出来的是这条规则：

> 从 `G:\workspace` 下面启动的进程，写不了 `G:\workspace` 之外的任何地方。
> 从其它目录启动的同一个进程，哪里都能写。

探针四格全对：

| 探针位置 | 写 `%LOCALAPPDATA%\Temp` | 写工作区内 |
|---|---|---|
| `G:\workspace\...\tmp\wprobe.exe` | `OPEN FAIL` | `OPEN OK` |
| `G:\wsOut\w.exe` | `OPEN OK` | `OPEN OK` |

按目录扫一遍同一个探针，只有工作区那一个失败：
`C:\wsOut` OK / **`G:\workspace` FAIL** / `G:\workspacex` OK / `G:\workspace2x` OK /
`G:\wsOut2` OK。名字相近但不在其下的目录都不受影响，所以这不是前缀字符串匹配。
写工作区内部时五个位置**全部** OK。与路径长度也无关：
`G:\wsOut\vbios-loader.exe`（43 字符）OK，`G:\workspace\inside\v.exe`（25 字符）FAIL。

把 `vbios-loader.exe` 代进这条规则，就是开头那个现象：exe 在工作区里、`TEMP` 在
工作区外 → 解包 `entry.dll` 被拒。

**排除掉的四个原因**：

- 磁盘满：`C:` 还有 52.97 GB
- 权限：手写同一个文件名同一个大小完全成功（4 B / 300 KB / 3 MB 都试过），
  `C:\Temp\vbtest` 与 `%LOCALAPPDATA%\Temp` 的 ACL 里 `Authenticated Users`
  有 `Modify`
- Defender ASR：`Get-MpPreference` 直接报 `0x800106ba`（Defender 服务没在跑），
  这台机器装的是 360 安全卫士
- 子目录不存在 / 残留 `onefile_*`：每次都是清空后新建的目录，失败后目录里
  **一个文件都不剩**（连解一半的都没有）

`G:\workspace` 的 ACL 和根目录下新建的目录不一样，多两条：

```
Everyone                     Deny  DeleteSubdirectoriesAndFiles
A-XIANG_HOME\ctxia          Allow FullControl
```

这两条不是原因：`G:\workspacex` 与 `G:\wsOut2` 上同样加这两条也不受限，
而受限的那个探针只要放在工作区外就能写。**这是进程级的位置限制，
不是目录权限。**

**规避**：两条路，任选一条即可（两件同时满足时也成立）。

```powershell
# 一、把 TEMP 也放进工作区（进程和它的临时目录在同一侧）
$env:TMP = 'G:\workspace\vbios-4070tis\tmp'
$env:TEMP = $env:TMP
& G:\workspace\vbios-4070tis\vbios-loader.exe verify --json
```

```powershell
# 二、把 exe 复制到工作区外再跑（进程和它的临时目录都在外面）
Copy-Item G:\workspace\vbios-4070tis\vbios-loader.exe "$env:TEMP\v.exe" -Force
& "$env:TEMP\v.exe" verify --json
```

第二种写法拿真的 loader 跑过一次，`TMP`/`TEMP` 用的是系统默认值：
拿到完整 JSON，`state` 是 `override-not-active`，`exit=4`（这个退出码是
「override 还没被驱动接管」的正常值，不是失败）。同一个 exe 留在工作区里、
`TEMP` 用默认值，就是开头那行 `failed to open ... entry.dll`。

仓库里的 `rollback.ps1` 与 `do-load.ps1` 开头本来就有第一种写法的两行
（`$env:TMP = "$d\tmp"`），所以它们一直没撞上；只有在终端里手敲
`vbios-loader.exe` 时才会遇到。

同一条规则会影响工作区里**任何**需要写外部临时目录的程序，不只这一个 exe。
这次是在查它为什么起不来时才发现的，判据就是「同一个二进制换个位置就正常」。

## 18. 改一行注释也会改变 EFI 的哈希，因为 `__LINE__` 进了目标文件

**症状**：把一段注释的措辞改掉，重新编译，`build/AD104-EXPERIMENTAL.EFI`
的 sha256 变了，**大小一个字节都没变**（还是 104448）。第一反应是构建不可复现。

**实际不是**。`vendor/unlock_610.c:180` 是

```c
#define GU_RESULT(result) unlock_transaction_result(work, (result), __func__, __LINE__)
```

`__LINE__` 展开成调用点的行号，作为实参传进去，所以它落在代码段里，不是调试信息。
在那段注释**下面**还有 47 处 `GU_RESULT`，注释多写两行，这 47 个行号全变，
目标文件跟着变。

**实测**（同一份源码，只改注释行数）：

| 注释写成 | 行数 | 产物 sha256 前 8 |
|---|---|---|
| 七行（自然换行） | 7 | `C1AF0E57` |
| 五行（重新折行，意思不变） | 5 | `AFB6524A` |

`AFB6524A` 从 `6adb3ee` 一直用到 `a96c26a`（U 盘上挂过一阵）。把改动 stash 掉
重编也是 `AFB6524A`，所以构建本身是确定性的，不是随机。这张表不是「当前哪一版」
的答案：`app.c` 一改，产物照样会变，那一版是 `BFC70FF1`（`dcda05c`）。

**判据**：遇到「纯文本改动却换了哈希」，先数一下改动位置到文件末尾之间有多少
`GU_RESULT`（或任何带 `__LINE__` / `__FILE__` 的宏，`diagnostic.h:23` 的
`GU_DIAG` 同样带），数出来不是 0 就不用再怀疑构建环境。

**改法**：改注释时保持行数不变（重新折行而不是增删行），或者接受哈希变化并在
`rebuild-efi.ps1` 的 `$Known` 表里登记新值。不要为了「让哈希回到原值」去删注释内容。

**副作用**：`rebuild-efi.ps1` 的表里 `6adb3ee` 与 `e2e99c2` 是同一份二进制
（`AFB6524A`），因为后者只动了注释且保持五行。反过来，`dcda05c` 只改了几行 `stage`
名字，产物却变了——因为 `app.c` 是编进镜像的，不是注释。分辨方法是看改的是注释还是
代码，不是看改动大小。
