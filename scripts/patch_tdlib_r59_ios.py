#!/usr/bin/env python3
"""Patch iOS/macOS libtdjson: download_session_count = 1 (R59).

Stock TDLib: `download_session_count = is_premium ? 8 : 2` (same for
download_small). Under FakeTLS the 2nd session ClientHello never reaches
mtg and the live session is dropped — photos stay 0B after Home.

Android jniLibs already ship this. This script patches every
`libtdjson.a` under ios/tdjson/libtdjson-static.xcframework.

Idempotent. Creates `*.a.pre_r59` backup once per file.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
XC = ROOT / "ios" / "tdjson" / "libtdjson-static.xcframework"


def _movz_w(imm: int, rd: int) -> int:
    return 0x52800000 | ((imm & 0xFFFF) << 5) | (rd & 0x1F)


def _is_movz_w(word: int, imm: int | None = None) -> tuple[bool, int, int]:
    """Returns (ok, imm, rd)."""
    if (word & 0xFF800000) != 0x52800000:
        return False, 0, 0
    if ((word >> 21) & 3) != 0:
        return False, 0, 0
    got = (word >> 5) & 0xFFFF
    rd = word & 0x1F
    if imm is not None and got != imm:
        return False, got, rd
    return True, got, rd


def _patch_arm64_text(buf: bytearray, label: str) -> int:
    """Replace consecutive `mov Wx,#2; mov Wy,#8` with `#1;#1` (any regs)."""
    n = 0
    i = 0
    end = len(buf) - 7
    while i <= end:
        w1 = struct.unpack_from("<I", buf, i)[0]
        ok1, imm1, rd1 = _is_movz_w(w1, 2)
        if not ok1:
            i += 4
            continue
        w2 = struct.unpack_from("<I", buf, i + 4)[0]
        ok2, imm2, rd2 = _is_movz_w(w2, 8)
        if not ok2:
            i += 4
            continue
        # Already patched pair would be #1,#1 — skip.
        struct.pack_into("<I", buf, i, _movz_w(1, rd1))
        struct.pack_into("<I", buf, i + 4, _movz_w(1, rd2))
        n += 1
        print(
            f"  [{label}] arm64 mov w{rd1},#2 + mov w{rd2},#8 → #1,#1 @ {i}"
        )
        i += 8
    return n


def _patch_arm64_macho_obj(obj: bytearray, label: str) -> int:
    magic = struct.unpack_from("<I", obj, 0)[0]
    if magic != 0xFEEDFACF:
        return 0
    ncmds = struct.unpack_from("<I", obj, 16)[0]
    offset = 32
    total = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", obj, offset)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsects = struct.unpack_from("<I", obj, offset + 64)[0]
            soff = offset + 72
            for _s in range(nsects):
                secname = obj[soff : soff + 16].split(b"\x00", 1)[0]
                if secname == b"__text":
                    fo = struct.unpack_from("<I", obj, soff + 48)[0]
                    sz = struct.unpack_from("<Q", obj, soff + 40)[0]
                    chunk = bytearray(obj[fo : fo + sz])
                    c = _patch_arm64_text(chunk, label)
                    if c:
                        obj[fo : fo + sz] = chunk
                        total += c
                soff += 80
        offset += cmdsize
    if total == 0:
        # Fallback: scan whole object (headers rarely contain the pair).
        total = _patch_arm64_text(obj, label + "/raw")
    return total


def _iter_ar_members(data: bytes):
    if not data.startswith(b"!<arch>\n"):
        return
    off = 8
    n = len(data)
    while off + 60 <= n:
        if data[off : off + 1] == b"\n":
            off += 1
            continue
        hdr = data[off : off + 60]
        name = hdr[0:16].decode("ascii", "replace").strip()
        try:
            size = int(hdr[48:58].decode().strip())
        except ValueError:
            break
        off += 60
        if name.startswith("#1/"):
            nlen = int(name[3:])
            real = data[off : off + nlen].split(b"\x00", 1)[0].decode(
                "ascii", "replace"
            )
            file_off = off + nlen
            file_size = size - nlen
            name = real
        else:
            file_off = off
            file_size = size
        yield name, file_off, file_size
        off = file_off + file_size
        if off % 2:
            off += 1


def _patch_ar(data: bytearray, label: str) -> int:
    total = 0
    for name, fo, fs in _iter_ar_members(data):
        if "NetQueryDispatcher.cpp.o" not in name:
            continue
        obj = bytearray(data[fo : fo + fs])
        c = _patch_arm64_macho_obj(obj, f"{label}/{name.split(chr(0))[0]}")
        if c:
            data[fo : fo + fs] = obj
            total += c
    return total


def _u32(data: bytes, o: int, be: bool) -> int:
    return struct.unpack_from(">I" if be else "<I", data, o)[0]


def _patch_file_bytes(data: bytearray, label: str) -> int:
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic in (0xCAFEBABE, 0xBEBAFECA):
        be = magic == 0xBEBAFECA
        nfat = _u32(data, 4, be)
        total = 0
        for i in range(nfat):
            base = 8 + i * 20
            offset = _u32(data, base + 8, be)
            size = _u32(data, base + 12, be)
            sl = bytearray(data[offset : offset + size])
            if sl.startswith(b"!<arch>\n"):
                c = _patch_ar(sl, f"{label}/fat[{i}]")
            else:
                c = _patch_arm64_macho_obj(sl, f"{label}/fat[{i}]")
            if c:
                data[offset : offset + size] = sl
                total += c
        return total
    if data.startswith(b"!<arch>\n"):
        return _patch_ar(data, label)
    return _patch_arm64_macho_obj(data, label)


def main() -> int:
    if not XC.is_dir():
        print(f"missing {XC} — run scripts/fetch_tdlib_ios.ps1 first", file=sys.stderr)
        return 1
    libs = sorted(XC.rglob("libtdjson.a"))
    # Ignore backups
    libs = [p for p in libs if not p.name.endswith(".pre_r59")]
    if not libs:
        print(f"no libtdjson.a under {XC}", file=sys.stderr)
        return 1
    changed = 0
    for lib in libs:
        rel = lib.relative_to(XC)
        raw = bytearray(lib.read_bytes())
        n = _patch_file_bytes(raw, str(rel))
        if n:
            bak = Path(str(lib) + ".pre_r59")
            if not bak.exists():
                bak.write_bytes(lib.read_bytes())
                print(f"  backup {bak.name}")
            lib.write_bytes(raw)
            changed += n
            print(f"wrote {rel} (+{n})")
        else:
            print(f"ok {rel} (already patched or no arm64 site)")
    marker = XC / "R59_DOWNLOAD_SESSION_COUNT_1"
    marker.write_text(
        "Patched download(+small)_session_count immediates to 1 "
        "(FamilyChat FakeTLS R59).\n"
        "Re-run scripts/patch_tdlib_r59_ios.py after every stock "
        "scripts/fetch_tdlib_ios.ps1 / .sh fetch.\n",
        encoding="utf-8",
    )
    print(f"done sites={changed} marker={marker.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
