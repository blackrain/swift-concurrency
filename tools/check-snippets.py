#!/usr/bin/env python3
"""Compile-check every ```swift block in a Markdown guide.

Directives (HTML comments on the line(s) directly above a block):
  <!-- check: skip -->                 not checked (signatures, pseudo-code)
  <!-- check: continue -->             append to the previous block in the same file
  <!-- check: flags ... -->            extra swiftc flags
  <!-- check: error "text" -->         compile must FAIL with a diagnostic containing text
  <!-- check: warning "text" -->       compile must emit a warning containing text
  <!-- check: run -->                  compile and run (must exit 0)
  <!-- check: output "text" -->        run, stdout must contain text (implies run)
  <!-- check: lib -->                  compile as a library file (no top-level code)
Default: typecheck in Swift 6 language mode; any error or warning fails.
"""
import os, re, subprocess, sys, tempfile, shlex

DIRECTIVE = re.compile(r'<!--\s*check:\s*(\w+)\s*(.*?)\s*-->')
BASE = ['xcrun', 'swiftc', '-swift-version', '6', '-target', 'arm64-apple-macos27.0']

def blocks(path):
    lines = open(path).read().split('\n')
    i, pending = 0, []
    while i < len(lines):
        m = DIRECTIVE.search(lines[i])
        if m and lines[i].strip().startswith('<!--'):
            pending.append((m.group(1), m.group(2))); i += 1; continue
        if lines[i].strip() == '```swift':
            start = i + 1; j = start
            while lines[j].strip() != '```': j += 1
            yield start, '\n'.join(lines[start:j]), pending
            pending = []; i = j + 1; continue
        if lines[i].strip(): pending = []
        i += 1

def check(path, start, code, d, tmp):
    kinds = {k for k, _ in d}
    if 'skip' in kinds: return None
    flags = sum((shlex.split(v) for k, v in d if k == 'flags'), [])
    errs = [shlex.split(v)[0] for k, v in d if k == 'error']
    warns = [shlex.split(v)[0] for k, v in d if k == 'warning']
    outs = [shlex.split(v)[0] for k, v in d if k == 'output']
    run = 'run' in kinds or outs
    if not re.search(r'^\s*(@\w+\s+)*import ', code, re.M):
        code = 'import Foundation\n' + code
    fname = 'lib.swift' if 'lib' in kinds else 'main.swift'
    src = os.path.join(tmp, fname); open(src, 'w').write(code)
    exe = os.path.join(tmp, 'a.out')
    cmd = BASE + flags + ([src, '-o', exe] if run else ['-emit-sil', '-o', os.devnull, src])
    if 'lib' in kinds: cmd += ['-parse-as-library']
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=tmp)
    diag = p.stderr
    where = f'{path}:{start}'
    if errs:
        if p.returncode == 0: return f'{where}: expected error, compiled OK'
        miss = [e for e in errs if e not in diag]
        return f'{where}: missing expected error(s) {miss}\n{diag}' if miss else None
    if p.returncode != 0: return f'{where}: compile failed\n{diag}'
    if warns:
        miss = [w for w in warns if w not in diag]
        if miss: return f'{where}: missing expected warning(s) {miss}\n{diag}'
    elif 'warning:' in diag: return f'{where}: unexpected warning\n{diag}'
    if run:
        r = subprocess.run([exe], capture_output=True, text=True, timeout=60)
        if r.returncode != 0: return f'{where}: run exited {r.returncode}\n{r.stdout}{r.stderr}'
        miss = [o for o in outs if o not in r.stdout]
        if miss: return f'{where}: missing output {miss}\n--- got:\n{r.stdout}'
    return None

def main(paths):
    fails = n = 0
    files = []
    for p in paths:
        if os.path.isdir(p):
            for root, _, fs in os.walk(p):
                files += [os.path.join(root, f) for f in fs if f.endswith('.md')]
        else: files.append(p)
    for f in sorted(files):
        prev = None
        items = []
        for start, code, d in blocks(f):
            if any(k == 'continue' for k, _ in d) and items:
                ps, pc, pd = items[-1]
                items[-1] = (ps, pc + '\n' + code, pd + [x for x in d if x[0] != 'continue'])
                items[-1] = (ps, items[-1][1], [x for x in items[-1][2]])
            else: items.append((start, code, d))
        for start, code, d in items:
            with tempfile.TemporaryDirectory() as tmp:
                r = check(f, start, code, d, tmp)
            if any(k == 'skip' for k, _ in d): continue
            n += 1
            if r: fails += 1; print('FAIL', r, '\n')
    print(f'{n} blocks checked, {fails} failed')
    sys.exit(1 if fails else 0)

if __name__ == '__main__': main(sys.argv[1:])
