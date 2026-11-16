#!/usr/bin/env python3
"""Create a deflated zip of a directory tree (paths stored with '/').

Used to package the KOReader module and the native launcher as a single
compressed asset each, so the APK stays small while first-run extraction is
one streaming pass instead of ~1000 individual AssetManager opens.

Usage: makezip.py OUTPUT.zip SOURCE_DIR
"""

import os
import sys
import zipfile


def main():
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    out, src = sys.argv[1], sys.argv[2]
    # strict_timestamps=False clamps pre-1980 mtimes (some files pulled from
    # Android have epoch/1970 timestamps) instead of raising ValueError.
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=6,
                         strict_timestamps=False) as zf:
        for root, dirs, files in os.walk(src):
            dirs.sort()
            files.sort()
            for name in files:
                path = os.path.join(root, name)
                rel = os.path.relpath(path, src).replace(os.sep, "/")
                zf.write(path, rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
