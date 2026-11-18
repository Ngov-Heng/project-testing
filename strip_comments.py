"""Remove comments from Dart sources, keeping // ignore: directives.

Self-checking: the code token stream (string literals + every non-comment
character) must be identical before and after. If it isn't, the file is
skipped and reported.
"""
import sys, pathlib

def lex(src):
    """Walk Dart source once. Returns (stripped_text, code_tokens, keep_tokens)."""
    out, code, keep = [], [], []
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        # ---- string literals (incl. raw and triple-quoted)
        if c in '\'"' or (c in 'rR' and i + 1 < n and src[i + 1] in '\'"'):
            start = i
            raw = c in 'rR'
            if raw:
                i += 1
                c = src[i]
            triple = src.startswith(c * 3, i)
            i += 3 if triple else 1
            while i < n:
                if not raw and src[i] == '\\':
                    i += 2
                    continue
                if triple and src.startswith(c * 3, i):
                    i += 3
                    break
                if not triple and src[i] == c:
                    i += 1
                    break
                if not triple and src[i] == '\n':
                    break
                i += 1
            lit = src[start:i]
            code.append(lit)
            out.append(lit)
            continue
        # ---- line comment
        if src.startswith('//', i):
            j = src.find('\n', i)
            j = n if j == -1 else j
            com = src[i:j]
            if com.lstrip().startswith('// ignore'):
                keep.append(com)
                out.append(com)
            i = j
            continue
        # ---- block comment
        if src.startswith('/*', i):
            j = src.find('*/', i)
            i = n if j == -1 else j + 2
            continue
        code.append(c)
        out.append(c)
        i += 1
    text = ''.join(out)
    lines = [ln.rstrip() for ln in text.split('\n')]
    res = []
    for idx, ln in enumerate(lines):
        if ln.strip() == '':
            prev = next((l for l in reversed(res) if l.strip()), '')
            nxt = next((l for l in lines[idx + 1:] if l.strip()), '')
            if not prev or not nxt:
                continue
            if prev.rstrip().endswith(('{', '(')) or nxt.lstrip().startswith(('}', ')')):
                continue
            if res and res[-1].strip() == '':
                continue
            if (
                prev.rstrip().endswith(';')
                and nxt.rstrip().endswith(';')
                and not prev.lstrip().startswith(('import ', 'export ', 'part '))
            ):
                continue
            res.append('')
        else:
            res.append(ln)
    text = '\n'.join(res).strip('\n') + '\n'
    return text, code, keep

def main(root):
    root = pathlib.Path(root)
    ok = skipped = 0
    touched = 0
    removed_lines = 0
    for path in sorted(root.rglob('*.dart')):
        parts = set(path.parts)
        if '.dart_tool' in parts or 'build' in parts:
            continue
        src = path.read_text(encoding='utf-8')
        text, code_before, keep_before = lex(src)
        _, code_after, keep_after = lex(text)
        # whitespace moves when comments disappear, code must not change
        before = [t for t in code_before if not t.isspace()]
        after = [t for t in code_after if not t.isspace()]
        if before != after or keep_before != keep_after:
            print(f'SKIP (token mismatch): {path}')
            skipped += 1
            continue
        ok += 1
        if text != src:
            touched += 1
            removed_lines += src.count('\n') - text.count('\n')
            path.write_text(text, encoding='utf-8')
    print(f'files scanned: {ok} ok, {skipped} skipped')
    print(f'files rewritten: {touched}')
    print(f'comment lines removed: ~{removed_lines}')

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else '.')
