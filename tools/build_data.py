#!/usr/bin/env python3
"""Merge the unicode-math table and the Lean 4 abbreviation table into data.tsv.

Usage: python3 -I tools/build_data.py [OUT]   (default: unicode-picker/data.tsv)

Inputs (vendored in tools/sources/, see `make fetch-sources`):
  unicode-math-table.tex   LaTeX names (LPPL)
  abbreviations.json       Lean 4 VS Code input method (Apache-2.0)

Output: one line per output string, tab-separated:
  char <TAB> latex names <TAB> lean names <TAB> description <TAB> class
Names are space-separated and written without the leading backslash.
"""
import json
import re
import sys
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "sources"
DEFAULT_OUT = ROOT.parent / "unicode-picker" / "data.tsv"

SYMBOL_RE = re.compile(r'\\UnicodeMathSymbol\{"([0-9A-Fa-f]+)\}\{\\(\S+?)\s*\}\{\\(\w+)\}\{(.*)\}%')

# unicode-math command prefix -> LaTeX font-command aliases.
FONT_ALIASES = {
    "Bbb": ["mathbb"],
    "mbf": ["mathbf"],
    "mit": ["mathit"],
    "mscr": ["mathscr", "mathcal"],
    "mfrak": ["mathfrak"],
    "msans": ["mathsf"],
    "mtt": ["mathtt"],
}
GREEK_RE = re.compile(r"^mup([A-Za-z]+)$")
ALIAS_RE = re.compile(r"^(%s)([A-Za-z]|[a-z]+)$" % "|".join(FONT_ALIASES))

# Hand-added aliases for names unicode-math defines in its .sty rather than the table.
EXTRA_LATEX = {"hbar": "\u210f", "emptyset": "\u2205"}


def parse_description(desc):
    """Split a unicode-math description into (aliases, text)."""
    if ":" not in desc:
        # Unstructured: leading `/name` tokens are aliases, except spelled-out forms like `/bbb c, open face c`.
        words = desc.split()
        n = 0
        while n < len(words) and words[n].startswith("/"):
            n += 1
        if n and n < len(words) and words[n].endswith(","):
            n = 0
        text = " ".join(words[n:]).lstrip("- ").strip()
        return [w[1:] for w in words[:n]], text or desc.strip()
    head, tail = desc.split(":", 1)
    words = head.split()
    aliases = [w[1:] for w in words if w.startswith("/")]
    rest = [w for w in words if not w.startswith("/")]
    if rest and len(rest[-1]) == 1:
        rest.pop()  # class letter such as `r`, `b`, `p`
    return aliases, tail.strip() or " ".join(rest)


def main():
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_OUT
    rows = {}  # char -> dict

    def row(ch):
        return rows.setdefault(ch, {"latex": [], "lean": [], "desc": "", "cls": ""})

    def add(lst, name):
        if name and name not in lst:
            lst.append(name)

    for line in (SRC / "unicode-math-table.tex").read_text(encoding="utf8").splitlines():
        m = SYMBOL_RE.match(line)
        if not m:
            continue
        cp, cmd, cls, desc = m.groups()
        r = row(chr(int(cp, 16)))
        add(r["latex"], cmd)
        aliases, text = parse_description(desc)
        for a in aliases:
            add(r["latex"], a)
        gm = GREEK_RE.match(cmd)
        if gm:
            add(r["latex"], gm.group(1))  # \mupalpha is spelled \alpha in LaTeX
        am = ALIAS_RE.match(cmd)
        if am:
            letter = am.group(2)
            body = letter if len(letter) == 1 else "\\" + letter
            for font in FONT_ALIASES[am.group(1)]:
                add(r["latex"], "%s{%s}" % (font, body))
        r["desc"] = r["desc"] or text
        r["cls"] = r["cls"] or cls.removeprefix("math")

    for name, ch in EXTRA_LATEX.items():
        add(row(ch)["latex"], name)

    abbr = json.loads((SRC / "abbreviations.json").read_text(encoding="utf8"))
    for key, val in abbr.items():
        if "$CURSOR" in val or not val.strip() or len(val) > 3 or " " in key:
            continue
        add(row(val)["lean"], key)

    for ch, r in rows.items():
        if not r["desc"] and len(ch) == 1:
            r["desc"] = unicodedata.name(ch, "").lower()

    def norm(name):
        return re.sub(r"[\\{}\s]", "", name)

    # data.tsv: display fields. names.txt: normalized, case-sensitive searchable names
    # (tab-delimited, one line per character, same order). desc.txt: lowercase descriptions.
    # The Luau side searches these blobs with plain string.find to stay inside the
    # 25 ms per-callback CPU budget.
    with out.open("w", encoding="utf8", newline="\n") as f, \
            out.with_name("names.txt").open("w", encoding="utf8", newline="\n") as fn, \
            out.with_name("desc.txt").open("w", encoding="utf8", newline="\n") as fd:
        for ch in sorted(rows):
            r = rows[ch]
            f.write("\t".join([ch, " ".join(r["latex"]), " ".join(r["lean"]), r["desc"], r["cls"]]) + "\n")
            names = []
            for n in r["latex"] + r["lean"]:
                n = norm(n)
                if n and n not in names:
                    names.append(n)
            fn.write("\t" + "".join(n + "\t" for n in names) + "\n")
            fd.write(r["desc"].lower() + "\n")
    print("%d characters -> %s" % (len(rows), out))


if __name__ == "__main__":
    main()
