#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Patch the AD104-MSMI Windows port to a captured AD103/2705 machine profile.

Consumes `capture-constants.json` produced by gen_profile.py plus separately
supplied ESP/bootmgr values, and rewrites every machine-specific pin in a COPY
of the port tree. Prints a unified diff. Never touches the upstream tree.
"""
from __future__ import annotations

import argparse
import difflib
import json
import re
import shutil
import sys
from pathlib import Path

# (file, needle-regex, replacement-builder, label)
EDITS: list[tuple[str, str, str, str]] = []


def add(fn: str, pattern: str, repl: str, label: str) -> None:
    EDITS.append((fn, pattern, repl, label))


def build(c: dict, esp_guid: str, bootmgr_size: int, bootmgr_sha: str,
          fwsec: dict, cfg: dict) -> list[tuple[str, str, str, str]]:
    EDITS.clear()
    dev = c["device_id"]                      # e.g. '0x2705'
    subsys = c["subsystem"]                   # '10de:1771'
    rev = c["revision"]                       # 0xa1
    bus = c["bus"]
    ss1 = c["ss1"]
    bar0_base = cfg["bar0_base"]              # 0xFB000000
    bar0_max = bar0_base + 0xFFFFFF
    bar0_shift = bar0_base >> 16              # the pin is 0x80ffffff / 0x0000family
    dev_id = int(dev, 16)
    sv, sd = (int(x, 16) for x in subsys.split(":"))
    board_id = (dev_id << 16) | 0x10DE
    board_subsys = (sd << 16) | sv
    dev_mem = c["registers"]["FB_SIZE_MB"]

    p = lambda v, w=8: f"0x{v:0{w}x}"

    # ---- port.h: board identity + BAR0 + device memory size
    add("port.h", r"#define GU_BOARD_ID 0x[0-9a-fA-F]+U",
        f"#define GU_BOARD_ID {p(board_id)}U", "GU_BOARD_ID")
    add("port.h", r"#define GU_BOARD_SUBSYSTEM 0x[0-9a-fA-F]+U",
        f"#define GU_BOARD_SUBSYSTEM {p(board_subsys)}U", "GU_BOARD_SUBSYSTEM")
    add("port.h", r"#define GU_BAR0_BASE 0x[0-9a-fA-F]+ULL",
        f"#define GU_BAR0_BASE {p(bar0_base)}ULL", "GU_BAR0_BASE")
    add("port.h", r"#define GU_DEVICE_MEMORY_SIZE 0x[0-9a-fA-F]+U",
        f"#define GU_DEVICE_MEMORY_SIZE {p(dev_mem,4)}U", "GU_DEVICE_MEMORY_SIZE")

    # ---- port.c: GuTargetConfig bus pin
    add("port.c", r"return C && !S && B==\d+ && !D && !F && C\[0\]==GU_BOARD_ID &&",
        f"return C && !S && B=={bus} && !D && !F && C[0]==GU_BOARD_ID &&",
        "GuTargetConfig bus")

    # ---- checks.c: GuCheckConfig bus pin - this one gates Discover() before
    # ---- anything else runs. Missing it yields "STOP: stage=discover
    # ---- status=0x8000000000000003" and the firmware falls back to setup.
    add("checks.c", r"Segment != 0 \|\| Bus != \d+ \|\|",
        f"Segment != 0 || Bus != {bus} ||", "GuCheckConfig bus")

    # ---- msi_release.c: bus pin, PCI status pin, BAR0 range
    add("msi_release.c", r"if\(s!=EFI_SUCCESS\|\|seg\|\|bus!=\d+\|\|dev\|\|fun\)return EFI_UNSUPPORTED;",
        f"if(s!=EFI_SUCCESS||seg||bus!={bus}||dev||fun)return EFI_UNSUPPORTED;",
        "msi_release bus")
    add("msi_release.c", r"d->AddrRangeMax!=0x[0-9a-fA-F]+",
        f"d->AddrRangeMax!={p(bar0_max)}", "AddrRangeMax")

    # PCI status pin: Plan.config[0x78/4]==<captured value>
    pci_status = cfg["config_c2_9"]  # not the one we need; use explicit
    add("msi_release.c", r"Plan\.config\[0x78/4\]==0x[0-9a-fA-F]+",
        f"Plan.config[0x78/4]=={p(cfg['config_0x78'])}", "config[0x78] pin")

    # ---- boot_io.c: ESP identity + Windows boot manager pin
    add("boot_io.c",
        r"d->PartitionNumber==\d+&&d->PartitionStart==\d+&&\n\s*d->PartitionSize==\d+",
        f"d->PartitionNumber=={cfg['esp_partition']}&&d->PartitionStart=={cfg['esp_lba']}&&\n         d->PartitionSize=={cfg['esp_sectors']}",
        "ESP geometry pins")
    add("boot_io.c",
        r"ReadFile\(root,WindowsName,\d+,&bytes\);",
        f"ReadFile(root,WindowsName,{bootmgr_size},&bytes);", "bootmgr size")
    add("boot_io.c",
        r"GuHashMatches\(bytes,\d+,\"b6f5ff8a5f605840796875259bba555d0642745a7ac8a5b38d16603768b[0-9a-f]*\"\)",
        f'GuHashMatches(bytes,{bootmgr_size},"{bootmgr_sha}")', "bootmgr hash")
    add("boot_io.c",
        r"b->LoadImage\(FALSE,Self,\(VOID \*\)path,bytes,\d+,&Windows\)",
        f"b->LoadImage(FALSE,Self,(VOID *)path,bytes,{bootmgr_size},&Windows)",
        "LoadImage size")

    # ---- ESP partition GUID lives in local/boot_profile.h (written in main),
     # ---- NOT in boot_profile.h: its other branch is a synthetic host-test GUID.

    # ---- extract_private_capture.py: PROM + driver code hashes
    add("tools/extract_private_capture.py",
        r"PROM = '[0-9a-f]{64}'", f"PROM = '{c['prom_sha256']}'", "extract PROM")
    return EDITS


def apply(tree: Path, edits, dry: bool) -> int:
    touched: dict[Path, list[str]] = {}
    for fn, pattern, repl, label in edits:
        path = tree / fn
        if not path.exists():
            print(f"SKIP (missing) {fn}: {label}")
            continue
        text = path.read_text(encoding="utf-8")
        m = re.search(pattern, text)
        if not m:
            print(f"MISS {fn}: {label}  pattern={pattern[:60]}")
            continue
        new = text[:m.start()] + repl + text[m.end():]
        if new == text:
            print(f"SAME {fn}: {label}")
            continue
        touched.setdefault(path, []).append(label)
        if not dry:
            path.write_text(new, encoding="utf-8")
        d = difflib.unified_diff(text.splitlines(True), new.splitlines(True),
                                 fromfile=f"a/{fn}", tofile=f"b/{fn}", n=1)
        sys.stdout.writelines(list(d)[:12])
        print(f"  ^ {label}\n")

    print("\n===== summary =====")
    for path, labels in touched.items():
        print(f"{path.name:<28} {len(labels)} edit(s): {', '.join(labels)}")
    return len(touched)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--constants", type=Path, required=True, help="capture-constants.json")
    ap.add_argument("--src", type=Path,
                    default=Path(__file__).resolve().parents[2] / "gpu-unlock-ada" / "windows" / "ad104-msi")
    ap.add_argument("--out", type=Path,
                    default=Path(__file__).resolve().parents[2] / "gpu-unlock-ada" / "windows" / "ad103-2705")
    ap.add_argument("--esp-guid", required=True,
                    help="C initializer, e.g. {0x45c441a7,...}")
    ap.add_argument("--bootmgr-size", type=int, required=True)
    ap.add_argument("--bootmgr-sha", required=True)
    ap.add_argument("--bar0-base", required=True, help="e.g. 0xFB000000")
    ap.add_argument("--config-0x78", required=True, help="captured config[0x78], e.g. 0x0012b410")
    ap.add_argument("--esp-partition", type=int, required=True)
    ap.add_argument("--esp-lba", type=int, required=True)
    ap.add_argument("--esp-sectors", type=int, required=True)
    ap.add_argument("--keep-existing", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    c = json.loads(a.constants.read_text(encoding="utf-8"))
    cfg = dict(bar0_base=int(a.bar0_base, 16),
               config_0x78=int(a.config_0x78, 16),
               esp_partition=a.esp_partition, esp_lba=a.esp_lba,
               esp_sectors=a.esp_sectors,
               config_c2_9=c["config_c2_9"])
    fwsec = c["fwsec"]

    if not a.keep_existing and not a.dry_run:
        if a.out.exists():
            shutil.rmtree(a.out)
        shutil.copytree(a.src, a.out)
        # profile.c is regenerated by gen_profile.py into build\profile.ad103.c
        gen = Path(__file__).resolve().parents[1] / "build" / "profile.ad103.c"
        if gen.exists():
            shutil.copy2(gen, a.out / "profile.c")
            print(f"profile.c  <- {gen}")
        else:
            print("WARNING: build\\profile.ad103.c not found; profile.c left as upstream")
        # ESP GUID goes in the excluded local header, never in boot_profile.h
        local = a.out / "local"
        local.mkdir(exist_ok=True)
        (local / "boot_profile.h").write_text(
            "/* SPDX-License-Identifier: GPL-2.0-only */\n"
            "/* Local ESP identifier for this machine. Excluded from Git. */\n"
            "#pragma once\n"
            f"#define GU_WINDOWS_PARTITION_INITIALIZER {a.esp_guid}\n",
            encoding="utf-8")
        print(f"local/boot_profile.h  <- {a.esp_guid}")
    tree = a.out if (a.out.exists() and not a.dry_run) else a.src

    edits = build(c, a.esp_guid, a.bootmgr_size, a.bootmgr_sha, fwsec, cfg)
    n = apply(tree, edits, a.dry_run)
    print(f"\npatched {n} file(s) in {tree}")


if __name__ == "__main__":
    main()
