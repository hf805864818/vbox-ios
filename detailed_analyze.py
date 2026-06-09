
import re

def detailed_analyze(fpath, start_line=1, end_line=200):
    with open(fpath) as fh:
        lines = fh.readlines()
    
    balance = 0
    in_string = False
    in_comment_single = False
    in_comment_multi = False
    escape_next = False
    
    print(f"=== {fpath} ===\n")
    for line_num, line in enumerate(lines, 1):
        if line_num < start_line:
            continue
        if line_num > end_line:
            break
        
        line_balance_change = 0
        col = 1
        i = 0
        while i < len(line):
            c = line[i]
            
            if escape_next:
                escape_next = False
                i += 1
                col += 1
                continue
            
            if in_comment_single:
                i += 1
                col +=1
                continue
            
            if in_comment_multi:
                if c == '*' and i+1 < len(line) and line[i+1] == '/':
                    in_comment_multi = False
                    i +=2
                    col +=2
                else:
                    i +=1
                    col +=1
                continue
            
            if in_string:
                if c == '\\':
                    escape_next = True
                elif c == '"':
                    in_string = False
                i +=1
                col +=1
                continue
            
            # Not in string or comment
            if c == '"':
                in_string = True
            elif c == '/' and i+1 < len(line) and line[i+1] == '/':
                in_comment_single = True
            elif c == '/' and i+1 < len(line) and line[i+1] == '*':
                in_comment_multi = True
            elif c == '{':
                balance +=1
                line_balance_change +=1
            elif c == '}':
                balance -=1
                line_balance_change -=1
            
            i +=1
            col +=1
        
        if line_balance_change != 0:
            print(f"L{line_num}: bal={balance} ({'+' if line_balance_change>0 else ''}{line_balance_change}) | {line.rstrip()}")
        else:
            print(f"L{line_num}: bal={balance} | {line.rstrip()}")
    
    print(f"\nFinal balance: {balance}")
    return balance

print("=== LogVarDanmakuService.swift ===")
detailed_analyze("vbox/Services/LogVarDanmakuService.swift")
