
import re

def locate_brace_issue(fpath):
    with open(fpath) as fh:
        content = fh.read()
    
    i = 0
    balance = 0
    in_string = False
    in_comment_single = False
    in_comment_multi = False
    escape_next = False
    
    line = 1
    col = 1
    
    while i < len(content):
        c = content[i]
        
        if c == '\n':
            line += 1
            col = 1
            i += 1
            continue
        
        if escape_next:
            escape_next = False
            i += 1
            col += 1
            continue
        
        if in_comment_single:
            if c == '\n':
                in_comment_single = False
            i += 1
            col += 1
            continue
        
        if in_comment_multi:
            if c == '*' and i+1 < len(content) and content[i+1] == '/':
                in_comment_multi = False
                i += 2
                col += 2
            else:
                i += 1
                col += 1
            continue
        
        if in_string:
            if c == '\\':
                escape_next = True
            elif c == '"':
                in_string = False
            i += 1
            col += 1
            continue
        
        # Not in string or comment
        if c == '"':
            in_string = True
        elif c == '/' and i+1 < len(content) and content[i+1] == '/':
            in_comment_single = True
            i += 1
            col += 1
        elif c == '/' and i+1 < len(content) and content[i+1] == '*':
            in_comment_multi = True
            i += 1
            col += 1
        elif c == '{':
            balance += 1
        elif c == '}':
            balance -= 1
            # Check if we go negative or if this is the issue
            if balance < 0:
                print(f'⚠️ Balance went negative at line {line}, col {col}')
        
        i += 1
        col += 1
    
    print(f'Final balance for {fpath}: {balance}')
    return balance

print('Checking SpiderManager.swift...')
locate_brace_issue('vbox/Services/SpiderManager.swift')
print('\nChecking LogVarDanmakuService.swift...')
locate_brace_issue('vbox/Services/LogVarDanmakuService.swift')
