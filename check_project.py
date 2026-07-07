
#!/usr/bin/env python3
"""Comprehensive vbox-ios project check (fixed for Swift raw strings)."""
import re, os, sys

errors = []
BASE = sys.argv[1] if len(sys.argv) > 1 else '.'

def clean_swift_code(content):
    """Clean Swift code by removing strings and comments."""
    result = []
    i = 0
    n = len(content)
    
    while i < n:
        # Check for // comment
        if i+1 < n and content[i] == '/' and content[i+1] == '/':
            while i < n and content[i] != '\n':
                i += 1
            continue
        
        # Check for /* comment
        if i+1 < n and content[i] == '/' and content[i+1] == '*':
            i += 2
            while i+1 < n and not (content[i] == '*' and content[i+1] == '/'):
                i += 1
            i += 2
            continue
        
        # Check for Swift raw string: #"..."# or ##"..."## etc.
        if content[i] == '#':
            hash_start = i
            while i < n and content[i] == '#':
                i += 1
            if i < n and content[i] == '"':
                i += 1
                hash_count = i - hash_start - 1
                while i < n:
                    if content[i] == '"':
                        ok = True
                        for j in range(hash_count):
                            if i+1+j >= n or content[i+1+j] != '#':
                                ok = False
                                break
                        if ok:
                            i += 1 + hash_count
                            break
                    i += 1
                continue
            else:
                i = hash_start
        
        # Check for regular string "..."
        if content[i] == '"':
            i += 1
            while i < n:
                if content[i] == '\\':
                    i += 2
                elif content[i] == '"':
                    i += 1
                    break
                else:
                    i += 1
            continue
        
        result.append(content[i])
        i += 1
    
    return ''.join(result)

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
    clean = clean_swift_code(content)
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
        errors.append(f"Duplicate type '{name}' in: {', '.join(files)}")

if errors:
    print(f"{len(errors)} issue(s) found:\n")
    for e in errors:
        print(f"  ❌ {e}")
    sys.exit(1)
else:
    print("✅ All checks passed")
