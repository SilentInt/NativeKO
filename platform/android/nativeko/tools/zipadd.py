#!/usr/bin/env python3
"""Append files/directories to an existing APK (or any zip) with forward-slash
paths. Used instead of the `zip` CLI, which is not installed everywhere.

Usage: zipadd.py TARGET.zip SRC[:ARCPATH] ...
  - if SRC is a directory, its contents are added under ARCPATH (default: .)
  - if SRC is a file, it is stored at ARCPATH
"""

import os
import sys
import zipfile


def add_tree(zf, src, arcroot):
    for root, dirs, files in os.walk(src):
        dirs.sort()
        files.sort()
        for name in files:
            path = os.path.join(root, name)
            rel = os.path.relpath(path, src)
            arc = os.path.normpath(os.path.join(arcroot, rel)).replace(os.sep, "/")
            zf.write(path, arc)


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    target = sys.argv[1]
    # Store entries uncompressed: AssetManager can then open/extract them
    # without inflating on the device's slow single-core CPU (first-run
    # extraction is I/O bound instead of CPU bound).
    with zipfile.ZipFile(target, "a", zipfile.ZIP_STORED) as zf:
        for arg in sys.argv[2:]:
            src, _, arcroot = arg.partition(":")
            arcroot = arcroot or os.path.basename(src.rstrip("/"))
            if os.path.isdir(src):
                add_tree(zf, src, arcroot)
            else:
                zf.write(src, arcroot)
    return 0


if __name__ == "__main__":
    sys.exit(main())
