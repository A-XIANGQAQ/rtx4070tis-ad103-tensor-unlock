#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Decode the pinned AD102 V67 four-write payload into its register table.

The payload `v67-ad102-610.43.03-four-plm.bin` is a 64,000-byte SEC2 image. Its
write chain is a flat table of (value word, address word) pairs at known offsets.
This script reads those words, prints the four target registers, and checks the
marker and the offsets against the pinned build.

Read-only: reads the payload, writes nothing unless --json is given. No GPU access.
Exit codes: 0 every check passed, 1 a check failed, 2 payload missing or wrong size.
"""
import argparse
import hashlib
import json
import os
import struct
import sys

DEFAULT_PAYLOAD = r"H:\AD104-ASSETS\v67-ad102-610.43.03-four-plm.bin"

EXPECTED_SIZE = 64000
EXPECTED_SHA256 = "44c36b2d6b3424e53e18f3e55db85c833655de071ce66ce42749588a4a7dc8cb"

# (value offset, address offset, register name, expected address, expected value)
WRITES = [
    (0xF948, 0xF960, "WPR_CFG", 0x1FA7CC, 0xFFFFF0FF),
    (0xF974, 0xF984, "FBPA", 0x9A0148, 0xFFFFFFFF),
    (0xF998, 0xF9A8, "WPR", 0x1FA7C4, 0xFFFFFFFF),
    (0xF9BC, 0xF9CC, "FEAT_OVR_PLM", 0x823804, 0xFFFFFFFF),
]

CANARY_OFFSET = 0xF94C
CANARY_VALUE = 0x0000019C
RETURN_OFFSET = 0xF950
MARKER_OFFSET = 0xF9E0
MARKER_VALUE = 0x67B00001
CLEANUP_OFFSET = 0xF9FC


def word(blob, offset):
    return struct.unpack_from("<I", blob, offset)[0]


def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Decode the AD102 four-write V67 payload into a register table.",
    )
    ap.add_argument(
        "--payload",
        default=DEFAULT_PAYLOAD,
        help="payload path (default: %(default)s)",
    )
    ap.add_argument("--json", metavar="PATH", help="also write the decoded table as JSON")
    args = ap.parse_args(argv)

    path = os.path.abspath(os.path.expanduser(args.payload))
    if not os.path.isfile(path):
        print(f"payload not found: {path}", file=sys.stderr)
        return 2

    with open(path, "rb") as handle:
        blob = handle.read()

    if len(blob) != EXPECTED_SIZE:
        print(
            f"payload size {len(blob)} != {EXPECTED_SIZE}: not the pinned AD102 image ({path})",
            file=sys.stderr,
        )
        return 2

    digest = hashlib.sha256(blob).hexdigest()
    rows = []
    for value_off, addr_off, name, want_addr, want_value in WRITES:
        addr = word(blob, addr_off)
        value = word(blob, value_off)
        rows.append(
            {
                "name": name,
                "value_offset": value_off,
                "value": value,
                "address_offset": addr_off,
                "address": addr,
                "expected_value": want_value,
                "expected_address": want_addr,
                "value_ok": value == want_value,
                "address_ok": addr == want_addr,
            }
        )

    marker = word(blob, MARKER_OFFSET)
    canary = word(blob, CANARY_OFFSET)
    return_slot = word(blob, RETURN_OFFSET)
    cleanup = word(blob, CLEANUP_OFFSET)

    checks = [
        ("size == {:,}".format(EXPECTED_SIZE), True, "{:,}".format(len(blob))),
        ("sha256", digest == EXPECTED_SHA256, digest[:16] + "..."),
        ("canary @0x%x" % CANARY_OFFSET, canary == CANARY_VALUE, "0x%08x" % canary),
        (
            "marker @0x%x == 0x%08x" % (MARKER_OFFSET, MARKER_VALUE),
            marker == MARKER_VALUE,
            "0x%08x" % marker,
        ),
    ]
    for row in rows:
        checks.append(
            (
                "%s address @0x%x" % (row["name"], row["address_offset"]),
                row["address_ok"],
                "0x%08x" % row["address"],
            )
        )
        checks.append(
            (
                "%s value @0x%x" % (row["name"], row["value_offset"]),
                row["value_ok"],
                "0x%08x" % row["value"],
            )
        )

    print(f"payload: {path}")
    print(f"  size {len(blob):,}  sha256 {digest}")
    print()
    print("| # | payload offset (value / address) | value | target register |")
    print("|---|---|---|---|")
    for index, row in enumerate(rows, 1):
        print(
            "| {} | `0x{:x}` / `0x{:x}` | `0x{:08x}` | {} `0x{:x}` |".format(
                index,
                row["value_offset"],
                row["address_offset"],
                row["value"],
                row["name"],
                row["address"],
            )
        )
    print()
    print(
        "canary `0x{:x}` = 0x{:08x}   return slot `0x{:x}` = 0x{:08x}   "
        "cleanup `0x{:x}` = 0x{:x}".format(
            CANARY_OFFSET, canary, RETURN_OFFSET, return_slot, CLEANUP_OFFSET, cleanup
        )
    )
    print()

    failed = 0
    for label, ok, observed in checks:
        print("{:4s} {:34s} {}".format("PASS" if ok else "FAIL", label, observed))
        if not ok:
            failed += 1

    if args.json:
        payload = {
            "payload": path,
            "size": len(blob),
            "sha256": digest,
            "writes": [
                {
                    "name": row["name"],
                    "value_offset": "0x%x" % row["value_offset"],
                    "value": "0x%08x" % row["value"],
                    "address_offset": "0x%x" % row["address_offset"],
                    "address": "0x%08x" % row["address"],
                }
                for row in rows
            ],
            "canary": "0x%08x" % canary,
            "return_slot": "0x%08x" % return_slot,
            "marker": "0x%08x" % marker,
            "cleanup": "0x%x" % cleanup,
            "checks_failed": failed,
        }
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        print()
        print(f"json: {os.path.abspath(args.json)}")

    print()
    if failed:
        print(f"{failed} check(s) failed")
        return 1
    print("all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
