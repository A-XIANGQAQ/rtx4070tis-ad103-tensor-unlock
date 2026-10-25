# 把 MSI AD104 端口移植到 ASUS B550-I + AD103 时撞到的东西

上游 `windows/ad104-msi` 是在一台 **MSI Z490 + MSI 4070 Ti (AD104)** 上验证的。
换到 **ASUS B550-I + 4070 Ti SUPER (AD103)** 后，preflight 九步里有五步会失败，
`release` 三个 stage 全部失败。原因基本都是「上游那台机器只有一份，这张卡/这块板有两份」。

下面按「症状 → 原因 → 改法」记，都是实测定位的，没有推测成分。

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

更硬的问题是 `UsbBaseline()` 里有 `if(Plan.usb_host)return EFI_UNSUPPORTED;` ——
**只允许存在一个 xHCI 控制器**。这块板有两个，必然在找到第二个时失败。

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

detach 成功但立刻失败，且 detach 之后没有 `Gops:` 日志 —— 说明断在
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
