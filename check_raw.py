
#!/usr/bin/env python3
import re

def check_file_alt(fpath):
    with open(fpath, 'rb') as fh:
        raw = fh.read()
    print(f"File: {fpath}")
    print(f"  Size: {len(raw)} bytes")
    
    # Try decoding with different encodings
    try:
        content = raw.decode('utf-8')
    except:
        content = raw.decode('latin-1')
    
    # Clean content
    clean = content
    clean = re.sub(r'"[^"\\]*(?:\\.[^"\\]*)*"', '""', clean)
    clean = re.sub(r'//[^\n]*', '', clean)
    clean = re.sub(r'/\*.*?\*/', '', clean, flags=re.DOTALL)
    
    opens = clean.count('{')
    closes = clean.count('}')
    print(f"  {{ count: {opens}")
    print(f"  }} count: {closes}")
    print(f"  Diff: {opens - closes}")
    
    # Also count in raw content (without cleaning)
    print(f"\n  Raw counts:")
    print(f"  {{ count: {content.count('{')}")
    print(f"  }} count: {content.count('}')}")
    
    return opens - closes

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1:
        check_file_alt(sys.argv[1])
