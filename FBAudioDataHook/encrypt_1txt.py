#!/usr/bin/env python3
"""Encrypt FBAudioDataHook 1.txt with RC4 (format FBRC4:<base64>)."""

from __future__ import annotations

import base64
import sys

KEY = b"TG:@Rfcode888"
PREFIX = "FBRC4:"


def rc4(data: bytes, key: bytes) -> bytes:
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) & 0xFF
        s[i], s[j] = s[j], s[i]

    out = bytearray(len(data))
    i = 0
    j = 0
    for n, byte in enumerate(data):
        i = (i + 1) & 0xFF
        j = (j + s[i]) & 0xFF
        s[i], s[j] = s[j], s[i]
        k = s[(s[i] + s[j]) & 0xFF]
        out[n] = byte ^ k
    return bytes(out)


def encrypt_bytes(plain: bytes) -> str:
    return PREFIX + base64.b64encode(rc4(plain, KEY)).decode("ascii")


def main() -> None:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <plain.txt> <encrypted.txt>", file=sys.stderr)
        raise SystemExit(2)

    src, dst = sys.argv[1], sys.argv[2]
    with open(src, "rb") as fh:
        plain = fh.read()
    if not plain.strip():
        raise SystemExit(f"Empty input: {src}")

    encrypted = encrypt_bytes(plain)
    with open(dst, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(encrypted)
        fh.write("\n")
    print(f"Wrote encrypted config: {dst}")


if __name__ == "__main__":
    main()
