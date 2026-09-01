#!/usr/bin/env python3
"""Roles that pass CONTEXT= to the shared runner must be declared to the client
with that window divided by the slot count. Prints one line per mismatch and
nothing when they agree."""
import json, re, sys

yaml_path, client_path, slots = sys.argv[1], sys.argv[2], int(sys.argv[3])

roles, current = {}, None
for line in open(yaml_path):
    m = re.match(r'^  ([A-Za-z0-9_-]+):\s*$', line)
    if m:
        current = m.group(1)
    m = re.search(r'-e CONTEXT=(\d+)', line)
    if m and current:
        roles[current] = int(m.group(1))

if not roles:
    print('no role passes CONTEXT= -- the discovery is broken, not the config')
    sys.exit(1)

client = json.loads(re.sub(r'^\s*//.*$', '', open(client_path).read(), flags=re.M))
models = client['provider']['contract']['models']

bad = []
for role, ctx in sorted(roles.items()):
    want = ctx // slots
    if role not in models:
        bad.append(f'{role}: served but not declared to the client')
    elif models[role]['limit']['context'] != want:
        got = models[role]['limit']['context']
        bad.append(f'{role}: client says {got}, server gives {want}')
print('; '.join(bad), end='')
