#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
#
# This file embeds the C body of profile.c, which comes from gpu-unlock-ada
# (GPL-2.0-only). The embedded template is a derivative work, so this file
# carries the upstream licence even though everything around it is ours.
"""Generate an AD103/2705 profile.c from a schema-4 AD104-PROBE capture.

Mirrors vendor/vbios_610.c (gpu_unlock_vbios_fwsec) byte-for-byte in Python so the
same FWSEC geometry can be derived from the PROM hex in the capture JSON.
Read-only: consumes a capture file, writes source text. No GPU access.
"""
import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

# ---- register map, identical to vendor/sample.c (order preserved) -----------
REGISTERS = [
    ("PMC_BOOT_0", 0x00000000), ("GFW_PLM", 0x00118128), ("GFW_BOOT", 0x00118234),
    ("GFW_CPUCTL", 0x00110100), ("WPR2_LO", 0x001FA824), ("WPR2_HI", 0x001FA828),
    ("WPR_CFG_PLM", 0x001FA7CC), ("WPR_PLM", 0x001FA7C4), ("FBPA_PLM", 0x009A0148),
    ("FEAT_PLM", 0x00823804), ("FEAT_READOUT_0", 0x00823814),
    ("FEAT_READOUT_1", 0x00823818), ("SS0", 0x0082381C), ("SS1", 0x00823820),
    ("FB_SIZE_MB", 0x001183A4), ("VGA_BASE", 0x00625F04), ("MMU_PLM", 0x001FA7C8),
    ("MMU_LO", 0x001FA82C), ("MMU_HI", 0x001FA830),
    ("BOOTER_UCODE_FUSE", 0x00824148), ("FWSEC_UCODE_FUSE", 0x008241E0),
    ("SEC2_CPUCTL", 0x00840100),
]
# profile.c Registers() checks these 19 and reads SS0/SS1 separately.
CHECKED = [n for n, _ in REGISTERS if n not in ("SS0", "SS1", "SEC2_CPUCTL")]


def r16(b, o): return struct.unpack_from("<H", b, o)[0]
def r32(b, o): return struct.unpack_from("<I", b, o)[0]


def _rom_signature(s): return s in (0xAA55, 0x4E56, 0xBB77)
def _data_signature(s): return s in (0x52494350, 0x5344504E, 0x53494752)


def expansion(rom):
    """Port of expansion() from vendor/vbios_610.c. Returns adjust."""
    n = len(rom)
    if not _rom_signature(r16(rom, 0)):
        raise ValueError("ROM does not start with a signature")
    pos = base = ext = 0
    images = 0
    while True:
        images += 1
        if images > 8 or pos + 0x1A > n or not _rom_signature(r16(rom, pos)):
            raise ValueError("ROM chain invalid")
        pcir = pos + r16(rom, pos + 0x18)
        if pcir + 0x16 > n:
            raise ValueError("PCIR out of range")
        if not _data_signature(r32(rom, pcir)):
            raise ValueError("bad data signature")
        octets = r16(rom, pcir + 0x10) * 512
        last = rom[pcir + 0x15] & 0x80
        npde = (pcir + r16(rom, pcir + 0x0A) + 15) & ~15
        if npde + 4 <= n and r32(rom, npde) == 0x4544504E:
            if npde + 10 > n:
                raise ValueError("NPDE out of range")
            ext_rev, ext_len = r16(rom, npde + 4), r16(rom, npde + 6)
            if ext_rev in (0x100, 0x101):
                sub = r16(rom, npde + 8) * 512
                if ext_len < 10 or npde + ext_len > n:
                    raise ValueError("NPDE length invalid")
                if ext_len > 10:
                    last = rom[npde + 10] & 0x80
                elif sub < octets:
                    last = 0
                octets = sub
        if not octets or pos + octets > n:
            raise ValueError("image length invalid")
        if not base and rom[pcir + 0x14] == 0:
            base = octets
        if not ext and rom[pcir + 0x14] == 0xE0:
            ext = pos
        if last:
            break
        pos += octets
    if ext and base and ext < base:
        raise ValueError("phantom image before base")
    return (ext - base) if (ext and base) else 0


def descriptor(rom, off):
    """Port of descriptor() from vendor/vbios_610.c."""
    n = len(rom)
    if off + 44 > n:
        raise ValueError("FWSEC descriptor out of range")
    hdr = r32(rom, off)
    size = hdr >> 16
    if not (hdr & 1) or ((hdr >> 8) & 0xFF) != 3 or size < 44:
        raise ValueError("FWSEC descriptor header unsupported")
    if off + size > n:
        raise ValueError("FWSEC descriptor size out of range")
    stored = r32(rom, off + 4)
    if not stored or stored > 0xFFFFFFFF - 255:
        raise ValueError("stored size invalid")
    image_size = (stored + 255) & ~255
    if off + size + image_size > n:
        raise ValueError("FWSEC image out of range")
    fw = {
        "image_size": image_size, "image_off": off + size,
        "pkc_off": r32(rom, off + 8), "interface_off": r32(rom, off + 12),
        "imem_pa": r32(rom, off + 16), "imem_size": r32(rom, off + 20),
        "imem_va": r32(rom, off + 24), "dmem_pa": r32(rom, off + 28),
        "dmem_size": r32(rom, off + 32),
        "engine_mask": r16(rom, off + 36), "ucode_id": rom[off + 38],
        "sig_count": rom[off + 39], "sig_versions": r16(rom, off + 40),
        "sig_off": off + 44, "sig_bytes": size - 44,
    }
    fw["data_off"] = fw["imem_size"]
    bits, count = fw["sig_versions"], 0
    while bits:
        count += bits & 1
        bits >>= 1
    if not (1 <= fw["ucode_id"] <= 16) or not fw["engine_mask"] or not count:
        raise ValueError("FWSEC geometry rejected")
    if count != fw["sig_count"] or fw["sig_bytes"] != count * 384:
        raise ValueError("FWSEC signature geometry mismatch")
    if not fw["imem_size"] or not fw["dmem_size"]:
        raise ValueError("FWSEC empty region")
    if fw["data_off"] + fw["dmem_size"] > fw["image_size"]:
        raise ValueError("FWSEC dmem exceeds image")
    if fw["pkc_off"] + 384 > fw["dmem_size"]:
        raise ValueError("FWSEC pkc exceeds dmem")
    if fw["interface_off"] + 4 > fw["dmem_size"]:
        raise ValueError("FWSEC interface exceeds dmem")
    return fw


def fwsec(rom):
    """Port of gpu_unlock_vbios_fwsec()."""
    if len(rom) > 1024 * 1024:
        raise ValueError("ROM larger than 1 MiB")
    adjust = expansion(rom)
    n = len(rom)
    for bit in range(0, n - 12 + 1):
        if r16(rom, bit) != 0xB8FF or r32(rom, bit + 2) != 0x00544942:
            continue
        size, stride, tokens = rom[bit + 8], rom[bit + 9], rom[bit + 10]
        if size < 12 or stride < 6 or bit + size > n:
            raise ValueError("BIT record invalid")
        if sum(rom[bit:bit + size]) & 0xFF:
            continue
        if bit + size + tokens * stride > n:
            raise ValueError("BIT tokens out of range")
        for i in range(tokens):
            tok = bit + size + i * stride
            if rom[tok] != 0x70 or rom[tok + 1] != 2 or r16(rom, tok + 2) < 4:
                continue
            ptr = r32(rom, tok + 4) if stride >= 8 else r16(rom, tok + 4)
            if ptr + r16(rom, tok + 2) > n:
                raise ValueError("ucode pointer out of range")
            table = adjust + r32(rom, ptr)
            if table + 6 > n:
                raise ValueError("ucode table out of range")
            if rom[table] != 1 or rom[table + 1] < 6 or rom[table + 2] < 6:
                raise ValueError("ucode table header unsupported")
            hdr, ent, cnt = rom[table + 1], rom[table + 2], rom[table + 3]
            if table + hdr + cnt * ent > n:
                raise ValueError("ucode entries out of range")
            for j in range(cnt):
                e = table + hdr + j * ent
                if rom[e] == 0x85:
                    return descriptor(rom, adjust + r32(rom, e + 2))
    raise ValueError("no FWSEC descriptor found")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("capture", type=Path)
    ap.add_argument("--out", type=Path, default=Path("profile.ad103.c"))
    ap.add_argument("--json-out", type=Path, default=Path("capture-constants.json"))
    ap.add_argument("--self-check", action="store_true",
                    help="assert extracted FWSEC matches the upstream 2782 profile")
    a = ap.parse_args()

    j = json.loads(a.capture.read_text(encoding="utf-8-sig"))
    if j.get("schema") != 4:
        sys.exit("capture schema is not 4")
    prom = j.get("physical_prom") or {}
    if not prom.get("complete") or not prom.get("hex"):
        sys.exit("capture has no complete physical PROM")
    rom = bytes.fromhex(prom["hex"])
    if len(rom) != 1048576:
        sys.exit(f"PROM is {len(rom)} bytes, expected 1048576")
    prom_sha = hashlib.sha256(rom).hexdigest()

    # ---- registers -----------------------------------------------------------
    samples = (j.get("register_snapshot") or {}).get("samples") or []
    by_offset = {}
    for s in samples:
        if s.get("value") is None:
            sys.exit(f"register {s.get('name')} has no value")
        by_offset[int(s["offset"], 16)] = int(s["value"], 16)
    vals = []
    for name, off in REGISTERS:
        if name in ("SS0", "SS1", "SEC2_CPUCTL"):
            continue
        if off not in by_offset:
            sys.exit(f"capture lacks register {name} @ {off:#x}")
        vals.append((name, off, by_offset[off]))
    ss0 = by_offset.get(0x0082381C)
    ss1 = by_offset.get(0x00823820)

    # ---- PCI config ----------------------------------------------------------
    devs = [d for d in j.get("display_devices") or []
            if int(d["vendor"], 16) == 0x10DE and d.get("exact_expected_identity")]
    if len(devs) != 1:
        sys.exit(f"expected exactly one exact-identity display device, got {len(devs)}")
    dev = devs[0]
    cfg = bytes.fromhex(dev["config64"])
    if len(cfg) < 64:
        sys.exit("config64 too short")
    cwords = list(struct.unpack_from("<16I", cfg, 0))

    # ---- FWSEC ---------------------------------------------------------------
    fw = fwsec(rom)

    if a.self_check:
        upstream = dict(image_off=0x45488, image_size=0x10300, imem_pa=0,
                        imem_size=0xF500, imem_va=0, dmem_pa=0, data_off=0xF500,
                        dmem_size=0xD80, pkc_off=0xB24, interface_off=0x1C,
                        ucode_id=9, engine_mask=0x400, sig_count=2,
                        sig_versions=3, sig_off=0x45188, sig_bytes=768)
        bad = {k: (fw[k], v) for k, v in upstream.items() if fw[k] != v}
        if bad:
            sys.exit(f"self-check FAILED, parser disagrees with upstream profile: {bad}")
        print("self-check PASS: parser reproduces the upstream 2782 FWSEC geometry")

    a.out.parent.mkdir(parents=True, exist_ok=True)
    a.json_out.parent.mkdir(parents=True, exist_ok=True)

    consts = dict(prom_sha256=prom_sha, device_id=dev["device_id"],
                  subsystem=f'{dev["subsystem_vendor"]}:{dev["subsystem_device"]}',
                  revision=dev["revision"], bus=dev["location"]["bus"],
                  ss0=ss0, ss1=ss1, fwsec=fw,
                  registers={n: v for n, _, v in vals},
                  config_c2_9=[hex(x) for x in cwords[2:10]])
    a.json_out.write_text(json.dumps(consts, indent=2) + "\n", encoding="utf-8")

    # ---- emit profile.c ------------------------------------------------------
    off_str = ",\n    ".join(f"0x{o:x}" for _, o, _ in vals)
    val_str = ",\n    ".join(f"0x{v:x}" for _, _, v in vals)
    fwc = ("    f->image_off==0x{image_off:x} && f->image_size==0x{image_size:x} &&\n"
           "    f->imem_pa==0x{imem_pa:x} && f->imem_size==0x{imem_size:x} && "
           "f->imem_va==0x{imem_va:x} &&\n"
           "    f->dmem_pa==0x{dmem_pa:x} && f->data_off==0x{data_off:x} && "
           "f->dmem_size==0x{dmem_size:x} &&\n"
           "    f->pkc_off==0x{pkc_off:x} && f->interface_off==0x{interface_off:x} && "
           "f->ucode_id=={ucode_id} &&\n"
           "    f->engine_mask==0x{engine_mask:x} && f->sig_count=={sig_count} && "
           "f->sig_versions==0x{sig_versions:x} &&\n"
           "    f->sig_off==0x{sig_off:x} && f->sig_bytes=={sig_bytes};").format(**fw)

    src = f'''/* SPDX-License-Identifier: GPL-2.0-only */
/* GENERATED by rtx2705/tools/gen_profile.py -- do not hand-edit.
 * Source capture : {a.capture.name}
 * PROM SHA-256   : {prom_sha}
 * Device         : {dev["vendor"]}:{dev["device_id"]} subsystem {dev["subsystem_vendor"]}:{dev["subsystem_device"]} rev {dev["revision"]:#x}
 * PCI location   : bus {dev["location"]["bus"]} dev {dev["location"]["device"]} fn {dev["location"]["function"]}
 * A matched profile is not hardware qualification.
 */
#include "profile.h"
#include "checks.h"
#include "sha256.h"
#include "compat/compat.h"

static const struct {{
  const char *name,*hash;
  UINTN bytes;
}} Pins[5]={{
 {{"gpu-unlock/610.43.03/booter_load_ad102.bin","6ee05b20e1dc244c08c052f36ef28469b8d09f4955d1fe33e48a179e11a7fd49",57672}},
 {{"gpu-unlock/610.43.03/v67-ad102-610.43.03-four-plm.bin","44c36b2d6b3424e53e18f3e55db85c833655de071ce66ce42749588a4a7dc8cb",64000}},
 {{"gpu-unlock/610.43.03/gsp_ga10x.bin","572373620a37418f24dc16b5031c39338778c3257e48e8408de9a57291b24f3a",84277400}},
 {{"gpu-unlock/610.43.03/gsp_boot_ad102.bin","45d6335a8185d6ff13e8d1484cea73f68d3d13aa1c19dc080ed1c3482dd5bac0",36864}},
 {{"gpu-unlock/610.43.03/gsp_boot_desc_ad102.bin","83f8f3f1f5f9496e0ea8fc7103c2beb64d0b6de2f5ffe725f13514de5a95fa42",84}}
}};
BOOLEAN GuAd104AssetsValid(VOID) {{
  for(UINTN i=0;i<5;i++)
    if(!GuAssets[i].name || strcmp(GuAssets[i].name,Pins[i].name) ||
       GuAssets[i].firmware.size!=Pins[i].bytes ||
       !GuHashMatches(GuAssets[i].firmware.data,Pins[i].bytes,Pins[i].hash))return FALSE;
  return TRUE;
}}
BOOLEAN GuAd104PromMatches(const VOID *Data,UINTN Bytes) {{
  return Bytes==1048576 && GuHashMatches(Data,Bytes,
    "{prom_sha}");
}}
BOOLEAN GuAd104FwsecMatches(const struct gpu_unlock_fwsec *f) {{
  return f &&
{fwc}
}}
static BOOLEAN Config(VOID) {{
  UINT32 c[64];UINTN s,b,d,f;GU_CAPS caps;
  if(!Gu.pci || !Gu.pci->GetLocation || !Gu.pci->Pci.Read ||
     Gu.bar_base!=GU_BAR0_BASE || Gu.bar_size!=0x1000000 ||
     EFI_ERROR(Gu.pci->GetLocation(Gu.pci,&s,&b,&d,&f)))return FALSE;
  for(UINTN i=0;i<64;i++)
    if(EFI_ERROR(GuConfigRead(EfiPciIoWidthUint32,(UINT32)i*4,&c[i])))return FALSE;
  if(!GuCheckConfig(c,s,b,d,f,&caps) || c[2]!=0x{cwords[2]:08x} ||
     c[4]!=GU_BAR0_BASE || c[5]!=0x{cwords[5]:x} || c[6]!=0x{cwords[6]:x} || c[7]!=0x{cwords[7]:x} ||
     c[8]!=0x{cwords[8]:x} || c[9]!=0x{cwords[9]:x}){{
    GuLog("cold-profile config mismatch: check=%u seg=%zu bus=%zu dev=%zu fun=%zu c2=%#x c4=%#x c5=%#x c6=%#x c7=%#x c8=%#x c9=%#x\\n",
      (unsigned)(GuCheckConfig(c,s,b,d,f,&caps)?1u:0u),(size_t)s,(size_t)b,(size_t)d,(size_t)f,
      c[2],c[4],c[5],c[6],c[7],c[8],c[9]);
    return FALSE;
  }}
  if(!(caps.pm==Gu.pm_cap && caps.pcie==Gu.pcie_cap &&
       caps.pcie_version==Gu.pcie_version && caps.msi==Gu.msi_cap && caps.msix==Gu.msix_cap)){{
    GuLog("cold-profile caps drift: pm %#x/%#x pcie %#x/%#x ver %#x/%#x msi %#x/%#x msix %#x/%#x\\n",
      caps.pm,Gu.pm_cap,caps.pcie,Gu.pcie_cap,caps.pcie_version,Gu.pcie_version,
      caps.msi,Gu.msi_cap,caps.msix,Gu.msix_cap);
    return FALSE;
  }}
  return TRUE;
}}
static BOOLEAN Registers(UINT32 *Ss0,UINT32 *Ss1) {{
  static const UINT32 offsets[]={{
    {off_str}}};
  static const UINT32 values[]={{
    {val_str}}};
  for(UINTN i=0;i<sizeof(offsets)/sizeof(offsets[0]);i++) {{
    UINT32 v=GuRead32(offsets[i]);
    if(Gu.fault){{GuLog("cold-profile read fault at idx=%zu off=%#x\\n",(size_t)i,offsets[i]);return FALSE;}}
    if(v!=values[i]){{
      GuLog("cold-profile register mismatch: idx=%zu off=%#x got=%#x want=%#x\\n",
        (size_t)i,offsets[i],v,values[i]);
      return FALSE;
    }}
  }}
  *Ss0=GuRead32(0x82381c);*Ss1=GuRead32(0x823820);
  if(Gu.fault){{GuLog("cold-profile selector read fault\\n");return FALSE;}}
  /* Two entry states are accepted, both observed on this card. stock: SS1
   * carries {ss1:x}, which is every boot from RUN0001 to RUN0006, including the
   * one that ran with a loaded VBIOS override. blank: both read 0, seen on six
   * consecutive boots with the 320 W default override loaded (RUN0007-RUN0012,
   * byte-identical logs). In both states the nineteen pins above still match
   * stock, so the selectors are the only part of the profile that differs. The
   * blank state is recorded here as observed; nothing in these logs says which
   * side causes it. Anything else stays a mismatch. */
  BOOLEAN stock=(*Ss1==0x{ss1:x}U),blank=(*Ss0==0U&&*Ss1==0U);
  if(*Ss0==0xffffffff||(*Ss0&0xffff0000)==0xbadf0000||*Ss0==0x88888888||(!stock&&!blank)){{
    GuLog("cold-profile selector mismatch: SS0=%#x SS1=%#x stockSS1=%#x\\n",*Ss0,*Ss1,0x{ss1:x});
    return FALSE;
  }}
  if(blank)GuLog("cold-profile blank selectors: SS0=0 SS1=0, accepted as a second legal entry state\\n");
  return TRUE;
}}
BOOLEAN GuAd104ColdEntry(VOID) {{
  UINT32 ss0,ss1;
  if(Gu.started||Gu.fault||Gu.retained){{
    GuLog("cold-entry blocked: started=%u fault=%u retained=%u\\n",
      Gu.started?1u:0u,Gu.fault?1u:0u,Gu.retained?1u:0u);
    return FALSE;
  }}
  if(!Config()){{GuLog("cold-entry: Config() failed\\n");return FALSE;}}
  if(!Registers(&ss0,&ss1)){{GuLog("cold-entry: Registers() failed\\n");return FALSE;}}
  if(!GuEntrySelectorsMatch(ss0,ss1)){{
    GuLog("cold-entry: GuEntrySelectorsMatch failed SS0=%#x SS1=%#x\\n",ss0,ss1);
    return FALSE;
  }}
  return TRUE;
}}
EFI_STATUS GuAd104Prepare(VOID) {{
  UINT32 ss0,ss1,after0,after1;VOID *prom=NULL;struct gpu_unlock_fwsec fw;
  /* Six of these eight used to collapse into one silent EFI_NOT_READY. The last
   * two report themselves from inside Config() and Registers(); the rest said
   * nothing, which is why a refused cold entry was indistinguishable from a
   * stale Gu flag at the console. */
  if(Gu.started){{GuLog("cold-prepare: the transaction already started\\n");return EFI_NOT_READY;}}
  if(Gu.fault){{GuLog("cold-prepare: an earlier read faulted\\n");return EFI_NOT_READY;}}
  if(Gu.retained){{GuLog("cold-prepare: buffers are still retained from an earlier run\\n");return EFI_NOT_READY;}}
  if(Gu.allocations){{GuLog("cold-prepare: allocations are still outstanding\\n");return EFI_NOT_READY;}}
  if(Gu.profile_verified){{GuLog("cold-prepare: the profile was already verified\\n");return EFI_NOT_READY;}}
  if(Gu.prom_verified){{GuLog("cold-prepare: the PROM was already verified\\n");return EFI_NOT_READY;}}
  if(!Config() || !Registers(&ss0,&ss1))return EFI_NOT_READY;
  if(!GuAd104AssetsValid()){{GuLog("cold-prepare: an asset is missing or its hash differs\\n");return EFI_CRC_ERROR;}}
  prom=GuAlloc(1048576);if(!prom)return EFI_OUT_OF_RESOURCES;
  GuCopyFromIo(prom,(VOID *)(UINTN)(Gu.bar_base+0x300000),1048576);
  /* One boolean used to fold seven checks into EFI_COMPROMISED_DATA with no
   * message, so a refused PROM and a refused FWSEC looked identical at the
   * console. Name the one that gave way; they need different fixes. */
  BOOLEAN io_ok=!Gu.fault;
  BOOLEAN prom_ok=io_ok && GuAd104PromMatches(prom,1048576);
  BOOLEAN fwsec_ok=prom_ok && !gpu_unlock_vbios_fwsec(prom,1048576,&fw) && GuAd104FwsecMatches(&fw);
  BOOLEAN again_ok=fwsec_ok && Config() && Registers(&after0,&after1) && ss0==after0 && ss1==after1;
  GuFree(prom);
  if(!io_ok){{GuLog("cold-prepare: reading the 1 MiB PROM at BAR0+0x300000 faulted\\n");return EFI_COMPROMISED_DATA;}}
  if(!prom_ok){{GuLog("cold-prepare: the PROM is not the one this build was pinned to\\n");return EFI_COMPROMISED_DATA;}}
  if(!fwsec_ok){{GuLog("cold-prepare: gpu_unlock_vbios_fwsec or GuAd104FwsecMatches rejected the descriptor\\n");return EFI_COMPROMISED_DATA;}}
  if(!again_ok){{GuLog("cold-prepare: config or selectors changed during the read (after=%#x %#x before=%#x %#x)\\n",after0,after1,ss0,ss1);return EFI_COMPROMISED_DATA;}}
  Gu.prom_verified=TRUE;
  /* Eleven refusals above now name themselves. This one still did not, and it
   * is the one an inaccessible BAR0 produces: GuLatchEntrySelectors() rejects
   * 0xffffffff, 0xbadf0000.., an already-unlocked pair and any SS1 above 0xf
   * without saying which. Name the pair it refused. */
  if(!GuLatchEntrySelectors(ss0,ss1)){{
    GuLog("cold-prepare: GuLatchEntrySelectors refused SS0=%#x SS1=%#x\\n",ss0,ss1);
    Gu.prom_verified=FALSE;return EFI_NOT_READY;
  }}
  Gu.profile_verified=TRUE;return EFI_SUCCESS;
}}
'''

    a.out.write_text(src, encoding="utf-8", newline="\n")
    print(f"PROM sha256    : {prom_sha}")
    print(f"device         : {dev['device_id']} subsys {consts['subsystem']} rev {dev['revision']:#x}")
    print(f"PCI location   : bus {consts['bus']}")
    print(f"SS0/SS1 stock  : {ss0:#x} / {ss1:#x}")
    print(f"FWSEC          : image_off={fw['image_off']:#x} imem={fw['imem_size']:#x} dmem={fw['dmem_size']:#x} ucode={fw['ucode_id']} engines={fw['engine_mask']:#x}")
    print(f"wrote {a.out} ({a.out.stat().st_size} bytes)")
    print(f"wrote {a.json_out}")


if __name__ == "__main__":
    main()
