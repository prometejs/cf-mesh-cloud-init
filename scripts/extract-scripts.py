#!/usr/bin/env python3
"""Extract embedded shell scripts from a rendered cloud-config and write
each to OUT_DIR. Used by lint to bash -n every embedded script.

usage: extract-scripts.py <rendered.cfg> <out-dir>
"""
import sys
import os
import yaml

cfg_path, out_dir = sys.argv[1], sys.argv[2]
os.makedirs(out_dir, exist_ok=True)

with open(cfg_path) as fh:
    cfg = yaml.safe_load(fh)

count = 0
for entry in (cfg.get("write_files") or []):
    content = entry.get("content", "")
    if "#!/" not in content.split("\n", 1)[0] and "bash" not in content[:80]:
        continue
    name = os.path.basename(entry["path"])
    target = os.path.join(out_dir, name)
    with open(target, "w") as out:
        out.write(content)
    count += 1
    print(target)

if count == 0:
    print("no embedded scripts found", file=sys.stderr)
    sys.exit(1)
