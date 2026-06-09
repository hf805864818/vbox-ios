#!/usr/bin/env python3
"""Comprehensive vbox-ios project check."""
import re, os, sys

errors = []
BASE = sys.argv[1] if len(sys.argv) > 1 else '.'

def all_swift_files():
    for root, dirs, files in os.walk(BASE + '/vbox'):
        for f in files:
            if f.endswith('.swift'):
                yield os.path.join(root, f)
    for root, dirs, files in os.walk(BASE + '/vbox'):
        for f in files:
            if f.endswith('.m') or f.endswith('.h'):
                yield os.path.join(root, f)

# 1. Brace balance for all swift files
for fpath in all_swift_files():
    if not fpath.endswith('.swift'): continue
    with open(fpath) as fh:
        content = fh.read()
    clean = content
    clean = re.sub(r'"[^"\\]*(?:\\.[^"\\]*)*"', '""', clean)
    clean = re.sub(r'//[^\n]*', '', clean)
    clean = re.sub(r'/\*.*?\*/', '', clean, flags=re.DOTALL)
    diff = clean.count('{') - clean.count('}')
    if diff != 0:
        errors.append(f"{fpath}: brace imbalance ({diff:+d})")

# 2. Check #import paths in .m and Bridging-Header
for fpath in list(all_swift_files()) + [BASE + '/vbox/vbox-Bridging-Header.h']:
    if not fpath.endswith('.m') and not fpath.endswith('.h'):
        continue
    if not os.path.exists(fpath): continue
    with open(fpath) as fh:
        for i, line in enumerate(fh, 1):
            m = re.match(r'#import\s+"([^"]+)"', line)
            if not m: continue
            target = m.group(1)
            file_dir = os.path.dirname(fpath)
            from_file = os.path.join(file_dir, target)
            from_libs = os.path.join(BASE, 'vbox/Libraries', target)
            if not os.path.exists(from_file) and not os.path.exists(from_libs):
                errors.append(f"{fpath}:{i}: #import \"{target}\" not found")

# 3. Check for duplicate type names across files
all_types = {}
for fpath in all_swift_files():
    if not fpath.endswith('.swift'): continue
    with open(fpath) as fh:
        content = fh.read()
    for m in re.finditer(r'(?:struct|class|enum)\s+(\w+)', content):
        name = m.group(1)
        if name in ['View', 'PreviewProvider', 'CodingKeys']: continue
        if name not in all_types: all_types[name] = []
        all_types[name].append(fpath)

for name, files in all_types.items():
    if len(files) > 1:
        # Check if genuinely duplicate (not nested inside other types)
        errors.append(f"Duplicate type '{name}' in: {', '.join(files)}")

if errors:
    print(f"{len(errors)} issue(s) found:\n")
    for e in errors:
        print(f"  ❌ {e}")
    sys.exit(1)
else:
    print("✅ All checks passed")
