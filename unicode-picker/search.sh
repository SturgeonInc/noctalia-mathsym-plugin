#!/bin/sh
# Search the unicode tables with fzf; print "rank<TAB>char<TAB>title<TAB>subtitle", best first.
# Usage: search.sh DIR QUERY   (DIR holds data.tsv, names.tsv and desc.tsv; see tools/build_data.py)
#
# Run by unicode.luau through noctalia.runAsync, because Luau callbacks only get a 25 ms CPU budget.
# Ranking is three fzf passes whose outputs are concatenated and de-duplicated by character:
#   1. names, case-sensitive exact substring. Lean's input method is case-sensitive (`\Go` is
#      omega, `\go` is not), so a hit that differs only in case must not beat e.g. `goal`.
#   2. names, case-insensitive fuzzy (typos, and the case-only matches).
#   3. descriptions, case-insensitive fuzzy; spaces mean AND ("greek lambda").
# Within a pass fzf orders by its score, then shorter names first.

dir=$1
query=$2

# A user's fzf defaults (--height, --tiebreak, ...) must not change how we rank.
FZF_DEFAULT_OPTS=
export FZF_DEFAULT_OPTS
unset FZF_DEFAULT_COMMAND

# `\mathbb{R}`, `mathbb R` and `mathbbR` are the same name; descriptions keep their spaces.
name_query=$(printf '%s' "$query" | tr -d '\\{}[:space:]')
desc_query=$(printf '%s' "$query" | tr -d '\\{}')
[ -n "$name_query" ] || exit 0

# fzf in filter mode over "text<TAB>row" lines, matching the text field only.
# --with-nth (not --nth): the length tiebreak must measure just the text, otherwise the digits
# of the row number decide ties and `r!` (row 26) beats the exact name `r` (row 582).
# Usage: fz QUERY [fzf options...] < file
fz() {
    q=$1
    shift
    fzf -f "$q" -d '\t' --with-nth 1 --tiebreak=length,index "$@"
}

{
    # +x: the query is literal text, not fzf operators, so names like `<=`, `^alpha`, `|-` work.
    fz "$name_query" +x -e +i < "$dir/names.tsv"
    fz "$name_query" +x -i < "$dir/names.tsv"
    fz "$desc_query" -i < "$dir/desc.tsv"
} | awk -F'\t' -v data="$dir/data.tsv" '
    BEGIN {
        while ((getline line < data) > 0) {
            n++
            split(line, f, "\t")
            char[n] = f[1]; title[n] = f[2]; subtitle[n] = f[3]
        }
    }
    !seen[$2]++ {
        if (++rank > 50) exit
        print rank "\t" char[$2] "\t" title[$2] "\t" subtitle[$2]
    }'
