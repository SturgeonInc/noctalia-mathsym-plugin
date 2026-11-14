#!/usr/bin/env python3
"""Search data.tsv; print launcher rows as JSON. Usage: search.py DATA_DIR QUERY

Run via noctalia.runAsync from unicode.luau, since Luau callbacks only get a 25 ms CPU budget.
Rank: case-sensitive exact > case-insensitive exact > prefix > substring > description words.
"""
import json
import re
import sys
import unicodedata
from pathlib import Path

LIMIT = 50


def norm(s):
    # `\mathbb{R}`, `mathbb R` and `mathbbR` are the same name.
    return re.sub(r"[\\{}\s]", "", s)


def names_of(latex, lean, limit):
    names = latex.split()
    shown = ["\\" + n for n in names[:limit]]
    return " ".join(shown) + (" …" if len(names) > limit else "")


def main():
    data_dir, query = Path(sys.argv[1]), sys.argv[2]
    token = norm(query)
    tl = token.lower()
    words = query.lower().replace("\\", "").split()
    if not token:
        print("[]")
        return

    rows = []
    for line in (data_dir / "data.tsv").read_text(encoding="utf8").splitlines():
        ch, latex, lean, desc, _cls = line.split("\t")
        best = 0
        for name in {norm(n) for n in latex.split() + lean.split()} - {""}:
            low = name.lower()
            if name == token:
                score = 1000
            elif low == tl:
                score = 900
            elif low.startswith(tl):
                score = 700 - min(len(low) - len(tl), 99)
            else:
                at = low.find(tl)
                score = 500 - min(len(low) - at - len(tl), 99) if at >= 0 else 0
            best = max(best, score)
        if best < 300 and len(tl) >= 2 and words and all(w in desc.lower() for w in words):
            best = 300
        if best:
            rows.append((best, ch, latex, lean, desc))

    rows.sort(key=lambda r: (-r[0], r[1]))
    out = []
    for score, ch, latex, lean, desc in rows[:LIMIT]:
        parts = []
        if latex:
            parts.append(names_of(latex, None, 3))
        if lean:
            parts.append("Lean: " + names_of(lean, None, 3))
        if desc:
            parts.append(desc)
        parts.append("U+%04X" % ord(ch[0]))
        title = "◌" + ch if len(ch) == 1 and unicodedata.combining(ch) else ch
        out.append({"id": "u:" + ch, "title": title, "subtitle": "  ·  ".join(parts), "score": score})
    print(json.dumps(out, ensure_ascii=False))


if __name__ == "__main__":
    main()
