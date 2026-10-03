#!/usr/bin/env python3
"""Pre-splice VASM includes into a single translation unit for VASM 1.8f kick1hunks."""
import re, sys, pathlib

def splice(rel, seen=None):
    if seen is None: seen = set()
    if rel in seen:
        return []
    seen.add(rel)
    out = []
    for line in pathlib.Path(rel).read_text().splitlines():
        m = re.match(r'\s*include\s+"([^"]+)"', line)
        if m:
            base = str(pathlib.Path(rel).parent)
            out.extend(splice(f"{base}/{m.group(1)}", seen))
        else:
            out.append(line)
    return out

if __name__ == '__main__':
    src, dst = sys.argv[1], sys.argv[2]
    lines = splice(src)
    pathlib.Path(dst).write_text('\n'.join(lines) + '\n')
    print(f"spliced {src} -> {dst} ({len(lines)} lines)")
