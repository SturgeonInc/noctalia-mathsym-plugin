#!/usr/bin/env python3
"""Search the unicode tables; print "rank<TAB>char<TAB>title<TAB>subtitle", best first.

Usage: search.py DIR QUERY   (DIR holds the .tsv files written by tools/build_data.py)

Run by unicode.luau through noctalia.runAsync, because Luau callbacks only get a 25 ms CPU budget.

A query containing a non-ASCII character (a pasted `∀`) is a reverse lookup: names are ASCII, so it is
unambiguous and goes first. Exact character, then entries that start with it (`∀ᵐ`). ASCII characters
(`<`) stay ordinary name queries.

Then four passes, concatenated and de-duplicated by character (first 50 kept):
  1. names, case-sensitive exact substring. Lean's input method is case-sensitive (`\\Go` is omega,
     `\\go` is not), so a hit that differs only in case must not beat e.g. `goal`.
  2. names, case-insensitive fuzzy (typos, and the case-only matches).
  3. descriptions, case-insensitive fuzzy; spaces mean AND ("greek lambda").
  4. code points, exact substring of the hex (`2264`, `U+2264`) or decimal (`8804`) code point.
     Weakest on purpose: bare numbers are ambiguous with names (`ae` and `1` are Lean names).
     A leading `U+`, `u+`, `0x` or `\\u` is stripped for this pass and means hex only; without one,
     hex and decimal are searched together.
Within a pass, hits are ordered by score, then shorter text, then file order.

The matcher follows fzf's scoring (fzf was this plugin's engine before; see the `fzf-search` tag), so
rankings carry over: 16 per matched character, bonuses at word boundaries and for consecutive runs,
and gap penalties.
"""
import sys

# Imports are kept to `sys`: `re` and `pathlib` alone cost about 8 ms of a ~25 ms query, and the
# script is run as `python3 -I -S` (no site import) for the same reason.

LIMIT = 50
HEX_DIGITS = "0123456789abcdef"

# fzf's default scheme.
SCORE_MATCH = 16
GAP_START = -3
GAP_EXTENSION = -1
BONUS_BOUNDARY = SCORE_MATCH // 2
BONUS_NON_WORD = BONUS_BOUNDARY
BONUS_CAMEL = BONUS_BOUNDARY + GAP_EXTENSION
BONUS_CONSECUTIVE = -(GAP_START + GAP_EXTENSION)
BONUS_FIRST_CHAR_MULTIPLIER = 2
BONUS_BOUNDARY_WHITE = BONUS_BOUNDARY + 2
BONUS_BOUNDARY_DELIMITER = BONUS_BOUNDARY + 1

WHITE, NON_WORD, DELIMITER, LOWER, UPPER, NUMBER = range(6)


def char_class(ch):
    if ch.isspace():
        return WHITE
    if ch in "/,:;|":
        return DELIMITER
    if ch.isdigit():
        return NUMBER
    if ch.isalpha():
        return UPPER if ch.isupper() else LOWER
    return NON_WORD


def bonus_at(prev, cls):
    # Measured against fzf: symbols like `-` get the same previous-character bonuses as letters
    # (`->n` and `|->` outrank `<->` for the query `->`), not a flat non-word bonus.
    if cls != WHITE:
        if prev == WHITE:
            return BONUS_BOUNDARY_WHITE
        if prev == DELIMITER:
            return BONUS_BOUNDARY_DELIMITER
        if prev == NON_WORD:
            return BONUS_BOUNDARY
        if (prev == LOWER and cls == UPPER) or (prev != NUMBER and cls == NUMBER):
            return BONUS_CAMEL
        return BONUS_NON_WORD if cls in (NON_WORD, DELIMITER) else 0
    return BONUS_BOUNDARY_WHITE


def bonuses(text):
    prev = WHITE  # the start of the text counts as a word boundary
    out = []
    for ch in text:
        cls = char_class(ch)
        out.append(bonus_at(prev, cls))
        prev = cls
    return out


def run_score(bonus, start, length):
    """Score `length` consecutive matched characters starting at `start`."""
    score = 0
    first = 0  # bonus of the first character of the current consecutive chunk
    consecutive = 0
    for k in range(length):
        b = bonus[start + k]
        consecutive += 1
        if consecutive > 1:
            first = bonus[start + k - consecutive + 1]
            if b >= BONUS_BOUNDARY and b > first:
                consecutive = 1  # a new word starts here: the run restarts
            else:
                b = max(b, BONUS_CONSECUTIVE, first)
        score += SCORE_MATCH + (b * BONUS_FIRST_CHAR_MULTIPLIER if k == 0 else b)
    return score


def exact_score(pattern, text):
    """Best score of `pattern` as a substring of `text`, or None."""
    at = text.find(pattern)
    if at < 0:
        return None
    bonus = bonuses(text)
    best = run_score(bonus, at, len(pattern))
    while True:
        at = text.find(pattern, at + 1)
        if at < 0:
            return best
        best = max(best, run_score(bonus, at, len(pattern)))


def fuzzy_score(pattern, text):
    """Best score of `pattern` as a subsequence of `text` (both already case-folded), or None."""
    # Cheap rejection: all pattern characters must appear in order.
    pos = -1
    for ch in pattern:
        pos = text.find(ch, pos + 1)
        if pos < 0:
            return None
    bonus = bonuses(text)
    n = len(text)
    neg = float("-inf")
    # Row i: best score with pattern[i] matched at text[j], and the length of its consecutive run.
    score = [neg] * n
    run = [0] * n
    for j in range(n):
        if text[j] == pattern[0]:
            score[j] = SCORE_MATCH + bonus[j] * BONUS_FIRST_CHAR_MULTIPLIER
            run[j] = 1
    for i in range(1, len(pattern)):
        new_score = [neg] * n
        new_run = [0] * n
        best_gap = neg  # max of score[k] + k over k <= j - 2
        for j in range(1, n):
            if j >= 2 and score[j - 2] + (j - 2) > best_gap:
                best_gap = score[j - 2] + (j - 2)
            if text[j] != pattern[i]:
                continue
            b = bonus[j]
            candidate = neg
            c_run = 1
            if score[j - 1] > neg:  # continue a consecutive run
                length = run[j - 1] + 1
                first = bonus[j - length + 1]
                if b >= BONUS_BOUNDARY and b > first:
                    bb, c_run = b, 1
                else:
                    bb, c_run = max(b, BONUS_CONSECUTIVE, first), length
                candidate = score[j - 1] + SCORE_MATCH + bb
            if best_gap > neg:  # start a new run after a gap: GAP_START, then GAP_EXTENSION per extra
                gap_candidate = best_gap - j - 1 + SCORE_MATCH + b
                if gap_candidate > candidate:
                    candidate, c_run = gap_candidate, 1
            new_score[j] = candidate
            new_run[j] = c_run
        score, run = new_score, new_run
    best = max(score)
    return None if best == neg else int(best)


def read_lines(path):
    with open(path, encoding="utf8") as f:
        return f.read().split("\n")[:-1]


def read_pairs(path):
    """(text, row) for each "text<TAB>row" line."""
    pairs = []
    for line in read_lines(path):
        text, _, row = line.rpartition("\t")
        pairs.append((text, int(row)))
    return pairs


def ranked(hits):
    """hits: (score, text, index, row). Best first: score, shorter text, file order."""
    hits.sort(key=lambda h: (-h[0], len(h[1]), h[2]))
    return [h[3] for h in hits]


def exact_pass(pairs, pattern, fold):
    hits = []
    for index, (text, row) in enumerate(pairs):
        t = text.lower() if fold else text
        s = exact_score(pattern, t) if pattern in t else None
        if s is not None:
            hits.append((s, text, index, row))
    return ranked(hits)


def names_fuzzy_pass(pairs, pattern):
    hits = []
    for index, (text, row) in enumerate(pairs):
        s = fuzzy_score(pattern, text.lower())
        if s is not None:
            hits.append((s, text, index, row))
    return ranked(hits)


def desc_pass(pairs, query):
    terms = query.lower().split()
    hits = []
    for index, (text, row) in enumerate(pairs):
        total = 0
        for term in terms:
            s = fuzzy_score(term, text)
            if s is None:
                break
            total += s
        else:
            hits.append((total, text, index, row))
    return ranked(hits)


def parse_code_query(name_query):
    """(digits, hex_only): hex digits for the code-point pass, with an explicit prefix removed."""
    low = name_query.lower()
    hex_only = True
    if low.startswith("u+") or low.startswith("0x"):
        digits = low[2:]
    elif low.startswith("u") and len(low) >= 3 and low[1] in HEX_DIGITS and low[2] in HEX_DIGITS:
        digits = low[1:]  # `\u2264`: the backslash was already stripped
    else:
        digits, hex_only = low, False
    return (digits if digits and all(c in HEX_DIGITS for c in digits) else ""), hex_only


def main():
    directory, query = sys.argv[1], sys.argv[2]
    # `\mathbb{R}`, `mathbb R` and `mathbbR` are one name; descriptions keep their spaces (AND).
    name_query = "".join(c for c in query if c not in "\\{}" and not c.isspace())
    desc_query = "".join(c for c in query if c not in "\\{}")
    if not name_query:
        return
    data = read_lines(directory + "/data.tsv")

    order = []
    seen = set()

    def add(rows):
        for row in rows:
            if row not in seen:
                seen.add(row)
                order.append(row)

    if any(ord(c) > 127 for c in query):  # reverse lookup by pasted character
        char = "".join(query.split())
        heads = [line.split("\t", 1)[0] for line in data]
        add([i + 1 for i, h in enumerate(heads) if h == char])
        add([i + 1 for i, h in enumerate(heads) if h.startswith(char)])

    names = read_pairs(directory + "/names.tsv")
    add(exact_pass(names, name_query, fold=False))
    add(names_fuzzy_pass(names, name_query.lower()))
    if len(order) < LIMIT:
        add(desc_pass(read_pairs(directory + "/desc.tsv"), desc_query))
    digits, hex_only = parse_code_query(name_query)
    if digits and len(order) < LIMIT:
        codes = read_pairs(directory + "/codes_hex.tsv")
        if not hex_only:
            codes += read_pairs(directory + "/codes_dec.tsv")
        add(exact_pass(codes, digits, fold=True))

    for rank, row in enumerate(order[:LIMIT], 1):
        char, title, subtitle = data[row - 1].split("\t")
        print("%d\t%s\t%s\t%s" % (rank, char, title, subtitle))


if __name__ == "__main__":
    main()
