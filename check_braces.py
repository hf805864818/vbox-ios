
#!/usr/bin/env python3
"""Detailed brace balance check with line numbers."""
import re, sys

def check_file(fpath):
    print(f"Checking {fpath}...")
    with open(fpath) as fh:
        lines = fh.readlines()
    
    balance = 0
    min_balance = 0
    max_balance = 0
    line_balances = []
    
    for i, line in enumerate(lines, 1):
        # Clean line: remove strings and comments
        clean = line
        clean = re.sub(r'"[^"\\]*(?:\\.[^"\\]*)*"', '""', clean)
        clean = re.sub(r'//[^\n]*', '', clean)
        clean = re.sub(r'/\*.*?\*/', '', clean, flags=re.DOTALL)
        
        # Count braces on this line
        opens = clean.count('{')
        closes = clean.count('}')
        balance += opens - closes
        line_balances.append((i, balance, opens, closes, line.rstrip()))
        
        if balance < min_balance: min_balance = balance
        if balance > max_balance: max_balance = balance
    
    print(f"  Final balance: {balance} (min: {min_balance}, max: {max_balance})")
    
    # Show context around balance changes
    if balance != 0:
        print("\n  Balance history (last 20 lines):")
        for entry in line_balances[-20:]:
            print(f"    L{entry[0]}: bal={entry[1]}, +{entry[2]}/-{entry[3]} | {entry[4][:80]}")
    
    return balance

if __name__ == "__main__":
    if len(sys.argv) > 1:
        check_file(sys.argv[1])
    else:
        import os
        for root, dirs, files in os.walk('vbox'):
            for f in files:
                if f.endswith('.swift'):
                    check_file(os.path.join(root, f))
