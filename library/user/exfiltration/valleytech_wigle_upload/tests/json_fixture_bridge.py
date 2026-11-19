"""OFFLINE ONLY: jshn-interface fixture bridge using Python's JSON decoder.

Tests exercise native_adapter's decisions, not libubox's own implementation.
All emitted scalar strings are shell quoted; the device does not use this file.
"""
import json
import shlex
import sys

try:
    document = json.load(sys.stdin)
except (ValueError, UnicodeError):
    raise SystemExit(1)

counter = 0

def assignment(array, key, value):
    print(f'{array}[{shlex.quote(str(key))}]={shlex.quote(str(value))}')

def walk(value, parent=''):
    global counter
    node = f'n{counter}'
    counter += 1
    assignment('MOCK_PARENT', node, parent)
    entries = value.items() if isinstance(value, dict) else enumerate(value, 1) if isinstance(value, list) else []
    keys = []
    for key, child in entries:
        key = str(key)
        keys.append(key)
        slot = f'{node}:{key}'
        if isinstance(child, dict): kind = 'object'
        elif isinstance(child, list): kind = 'array'
        elif isinstance(child, bool): kind = 'boolean'
        elif isinstance(child, str): kind = 'string'
        elif child is None: kind = 'null'
        elif isinstance(child, int): kind = 'int'
        else: kind = 'double'
        assignment('MOCK_TYPE', slot, kind)
        if kind in ('object', 'array'):
            assignment('MOCK_CHILD', slot, walk(child, node))
        else:
            val = int(child) if kind == 'boolean' else '' if child is None else child
            assignment('MOCK_VALUE', slot, val)
    assignment('MOCK_KEYS', node, ' '.join(keys))
    return node

walk(document)
print('MOCK_NODE=n0')
