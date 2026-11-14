#!/usr/bin/env python3
"""Merge the unicode-math table and the Lean 4 abbreviation table into data.tsv.

Usage: python3 -I tools/build_data.py [OUT]   (default: unicode-picker/data.tsv)

Inputs (vendored in tools/sources/, see `make fetch-sources`):
  unicode-math-table.tex   LaTeX names (LPPL)
  abbreviations.json       Lean 4 VS Code input method (Apache-2.0)

Outputs (next to OUT, tab-separated, rows sorted by codepoint; "row" is the 1-based line of data.tsv):
  data.tsv       char, title, subtitle (title/subtitle are ready to show)
  names.tsv      name, row   one line per normalized (no backslash/braces/spaces), case-sensitive
                             LaTeX or Lean name
  desc.tsv       lowercase description, row
  codes_hex.tsv  first code point as padded uppercase hex (U+XXXX style), row
  codes_dec.tsv  first code point as decimal, row
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


def norm(name):
    """`\\mathbb{R}`, `mathbb R` and `mathbbR` are the same name."""
    return re.sub(r"[\\{}\s]", "", name)


def searchable_names(r):
    names = []
    for n in r["latex"] + r["lean"]:
        n = norm(n)
        if n and n not in names:
            names.append(n)
    return " ".join(names)


def title(ch):
    # Combining marks render badly alone; put them on a dotted circle.
    return "\u25cc" + ch if len(ch) == 1 and unicodedata.combining(ch) else ch


def name_list(names, limit=3):
    shown = ["\\" + n for n in names[:limit]]
    return " ".join(shown) + (" \u2026" if len(names) > limit else "")


def subtitle(ch, r):
    parts = []
    if r["latex"]:
        parts.append(name_list(r["latex"]))
    if r["lean"]:
        parts.append("Lean: " + name_list(r["lean"]))
    if r["desc"]:
        parts.append(r["desc"])
    parts.append("U+%04X" % ord(ch[0]))
    return "  \u00b7  ".join(parts)


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

    # data.tsv: char, title, subtitle (display). names.tsv: name, row number (one line per name).
    # desc.tsv: lowercase description, row number. codes_hex.tsv / codes_dec.tsv: the first code
    # point as padded uppercase hex (`0229`) / decimal, row number. Row numbers are 1-based lines
    # of data.tsv. search.sh feeds these to fzf and joins the hits back to data.tsv.
    def writer(name):
        return out.with_name(name).open("w", encoding="utf8", newline="\n")

    with out.open("w", encoding="utf8", newline="\n") as f, \
            writer("names.tsv") as fn, writer("desc.tsv") as fd, \
            writer("codes_hex.tsv") as fh, writer("codes_dec.tsv") as fc:
        for row_no, ch in enumerate(sorted(rows), 1):
            r = rows[ch]
            f.write("\t".join([ch, title(ch), subtitle(ch, r)]) + "\n")
            for name in searchable_names(r).split():
                fn.write("%s\t%d\n" % (name, row_no))
            if r["desc"]:
                fd.write("%s\t%d\n" % (r["desc"].lower(), row_no))
            fh.write("%04X\t%d\n" % (ord(ch[0]), row_no))
            fc.write("%d\t%d\n" % (ord(ch[0]), row_no))
    print("%d characters -> %s" % (len(rows), out))


if __name__ == "__main__":
    main()
