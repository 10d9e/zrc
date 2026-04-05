#!/usr/bin/env python3
"""
End-to-end CLI tests: create test files from 10 MiB to 1 GiB, time encode/decode,
verify SHA-256 of recovered data.

Usage:
  python3 scripts/e2e_cli_test.py [path/to/rs]

If omitted, argv[1] is expected when invoked from `zig build e2e` (passed as the
compiled artifact path).
"""

from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def human_size(n: int) -> str:
    if n >= 1024 * 1024 * 1024:
        return f"{n / (1024 ** 3):.3f} GiB"
    if n >= 1024 * 1024:
        return f"{n / (1024 ** 2):.3f} MiB"
    if n >= 1024:
        return f"{n / 1024:.3f} KiB"
    return f"{n} B"


def sha256_file(path: Path) -> bytes:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            chunk = f.read(8 * 1024 * 1024)
            if not chunk:
                break
            h.update(chunk)
    return h.digest()


def create_zero_file(path: Path, size: int) -> None:
    """Sparse-friendly on most Unix: seek and write one byte at end."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as f:
        if size > 0:
            f.seek(size - 1)
            f.write(b"\x00")


def run_cmd(rs_bin: Path, args: list[str], *, cwd: Path) -> float:
    t0 = time.perf_counter()
    p = subprocess.run(
        [str(rs_bin), *args],
        cwd=cwd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    elapsed = time.perf_counter() - t0
    if p.returncode != 0:
        raise subprocess.CalledProcessError(
            p.returncode, [str(rs_bin), *args], None, None
        )
    return elapsed


def e2e_one(
    rs_bin: Path,
    work: Path,
    size: int,
    k: int,
    m: int,
) -> tuple[float, float]:
    name = f"e2e_{size}.bin"
    src = work / name
    shards_dir = work / f"shards_{size}"
    out_file = work / f"{name}.recovered"

    if src.exists():
        src.unlink()
    create_zero_file(src, size)

    if shards_dir.exists():
        shutil.rmtree(shards_dir)
    shards_dir.mkdir(parents=True)

    enc_s = run_cmd(
        rs_bin,
        [
            "encode",
            name,
            "--data",
            str(k),
            "--parity",
            str(m),
            "--out",
            str(shards_dir.relative_to(work)),
        ],
        cwd=work,
    )

    # Decode using exactly k shards (first k indices).
    shard_paths: list[str] = []
    for i in range(k):
        sp = shards_dir / f"{name}.shard{i:03d}"
        if not sp.is_file():
            raise FileNotFoundError(f"missing shard {sp}")
        shard_paths.append(str(sp.relative_to(work)))

    if out_file.exists():
        out_file.unlink()
    dec_s = run_cmd(
        rs_bin,
        ["decode", str(out_file.relative_to(work)), *shard_paths],
        cwd=work,
    )

    if sha256_file(src) != sha256_file(out_file):
        raise RuntimeError(f"SHA-256 mismatch for size {size}")

    return enc_s, dec_s


def main() -> int:
    ap = argparse.ArgumentParser(description="RS CLI encode/decode e2e timing")
    ap.add_argument(
        "rs_bin",
        nargs="?",
        default=os.environ.get("RS_BIN"),
        help="Path to rs executable (or set RS_BIN)",
    )
    ap.add_argument(
        "--k",
        type=int,
        default=6,
        help="data shards (default 6)",
    )
    ap.add_argument(
        "--m",
        type=int,
        default=4,
        help="parity shards (default 4)",
    )
    ap.add_argument(
        "--quick",
        action="store_true",
        help="only 10 MiB and 100 MiB",
    )
    args = ap.parse_args()

    if not args.rs_bin:
        print("error: pass path to `rs` or set RS_BIN", file=sys.stderr)
        return 2

    rs_bin = Path(args.rs_bin).resolve()
    if not rs_bin.is_file():
        print(f"error: not a file: {rs_bin}", file=sys.stderr)
        return 2

    if args.k < 1 or args.m < 1 or args.k + args.m > 255:
        print("error: need k>=1, m>=1, k+m<=255", file=sys.stderr)
        return 2

    if args.quick:
        sizes = [10 * 1024 * 1024, 100 * 1024 * 1024]
    else:
        sizes = [
            10 * 1024 * 1024,
            50 * 1024 * 1024,
            100 * 1024 * 1024,
            250 * 1024 * 1024,
            500 * 1024 * 1024,
            1024 * 1024 * 1024,
        ]

    print(f"rs: {rs_bin}")
    print(f"scheme: k={args.k} m={args.m} (any {args.k} of {args.k + args.m} shards)")
    print()
    print(f"{'size':>14}  {'encode_s':>12}  {'decode_s':>12}  {'MB/s enc':>12}  {'MB/s dec':>12}")
    print(f"{'':->14}  {'':->12}  {'':->12}  {'':->12}  {'':->12}")

    with tempfile.TemporaryDirectory(prefix="rs_e2e_") as tmp:
        work = Path(tmp)
        for size in sizes:
            enc_s, dec_s = e2e_one(rs_bin, work, size, args.k, args.m)
            mb = size / (1024 * 1024)
            enc_mbps = mb / enc_s if enc_s > 0 else float("inf")
            dec_mbps = mb / dec_s if dec_s > 0 else float("inf")
            print(
                f"{human_size(size):>14}  {enc_s:12.4f}  {dec_s:12.4f}  {enc_mbps:12.2f}  {dec_mbps:12.2f}"
            )

    print()
    print("OK: all sizes verified (SHA-256)")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except subprocess.CalledProcessError as e:
        print(f"error: command failed (exit {e.returncode}): {e.cmd}", file=sys.stderr)
        raise SystemExit(1)
    except (OSError, RuntimeError) as e:
        print(f"error: {e}", file=sys.stderr)
        raise SystemExit(1)
