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

本机决定性证据（`bench/probe_f16acc.cu`，同一份数据同一张卡）：

```
float-alpha  (float* as compute16F scales):  4188.85 TF/s   (0.262 ms/gemm)
   nonzero C: 0 / 67108864        <-- all zeros
half-alpha   (correct compute16F scales)  :   143.77 TF/s   (7.648 ms/gemm)
   nonzero C: 67108852 / 67108864
```

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
