
#!/usr/bin/env python3
"""Robust Swift code cleaner to check brace balance."""
import re

def clean_swift_code(content):
    """Clean Swift code by removing strings and comments."""
    result = []
    i = 0
    n = len(content)
    
    while i < n:
        # Check for // comment
        if i+1 < n and content[i] == '/' and content[i+1] == '/':
            # Skip to end of line
            while i < n and content[i] != '\n':
                i += 1
            continue
        
        # Check for /* comment
        if i+1 < n and content[i] == '/' and content[i+1] == '*':
            i += 2
            # Skip to */
            while i+1 < n and not (content[i] == '*' and content[i+1] == '/'):
                i += 1
            i += 2
            continue
        
        # Check for Swift raw string: #"..."# or ##"..."## etc.
        if content[i] == '#':
            # Count number of #
            hash_start = i
            while i < n and content[i] == '#':
                i += 1
            if i < n and content[i] == '"':
                # This is a raw string
                i += 1
                # Find closing " followed by same number of #
                hash_count = i - hash_start - 1  # -1 because we just passed "
                while i < n:
                    if content[i] == '"':
                        # Check if followed by hash_count #
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
                # Not a raw string, backtrack
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
        
        # Otherwise, keep the character
        result.append(content[i])
        i += 1
    
    return ''.join(result)

# Now check all Swift files
import os
errors = []

for root, dirs, files in os.walk('vbox'):
    for f in files:
        if f.endswith('.swift'):
            fpath = os.path.join(root, f)
            with open(fpath, 'r') as fh:
                content = fh.read()
            clean = clean_swift_code(content)
            diff = clean.count('{') - clean.count('}')
            if diff != 0:
                errors.append((fpath, diff))

if errors:
    print(f"{len(errors)} issue(s) found:")
    for fpath, diff in errors:
        print(f"  ❌ {fpath}: brace imbalance ({diff:+d})")
else:
    print("✅ All brace balances check out!")

# Now check SpiderManager.swift specifically
if os.path.exists('vbox/Services/SpiderManager.swift'):
    with open('vbox/Services/SpiderManager.swift', 'r') as fh:
        content = fh.read()
    clean = clean_swift_code(content)
    print("\nSpiderManager.swift: {} {{, {} }}".format(clean.count('{'), clean.count('}')))
