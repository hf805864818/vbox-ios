
import re

with open('vbox/Services/SpiderManager.swift') as fh:
    content = fh.read()

# Find all multi-line strings
print('=== Multi-line strings ===')
for m in re.finditer(r'"""(.+?)"""', content, flags=re.DOTALL):
    s = m.group(1)
    print('  Found multi-line string: {} chars, {} {{, {} }}'.format(len(s), s.count('{'), s.count('}')))

# Find all /* ... */ comments
print('\n=== /* ... */ comments ===')
for m in re.finditer(r'/\*(.+?)\*/', content, flags=re.DOTALL):
    s = m.group(1)
    print('  Found comment: {} chars, {} {{, {} }}'.format(len(s), s.count('{'), s.count('}')))
