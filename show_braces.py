
#!/usr/bin/env python3
"""Show file with line numbers and highlight brace changes."""
import re, sys

def show_file(fpath, context=5):
    with open(fpath) as fh:
        lines = fh.readlines()
    
    balance = 0
    print(f"File: {fpath} (total {len(lines)} lines)\n")
    
    for i, line in enumerate(lines, 1):
        # Clean line
        clean = line
        clean = re.sub(r'"[^"\\]*(?:\\.[^"\\]*)*"', '""', clean)
        clean = re.sub(r'//[^\n]*', '', clean)
        clean = re.sub(r'/\*.*?\*/', '', clean, flags=re.DOTALL)
        
        opens = clean.count('{')
        closes = clean.count('}')
        old_balance = balance
        balance += opens - closes
        
        mark = ""
        if opens > 0 or closes > 0:
            mark = f"  (+{opens}/-{closes}) bal: {old_balance}->{balance}"
        
        print(f"{i:5}: {line.rstrip()}{mark}")

if __name__ == "__main__":
    if len(sys.argv) > 1:
        show_file(sys.argv[1])
