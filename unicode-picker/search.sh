#!/bin/sh
# Search the unicode tables with fzf; print "rank<TAB>char<TAB>title<TAB>subtitle", best first.
# Usage: search.sh DIR QUERY   (DIR holds data.tsv, names.tsv and desc.tsv; see tools/build_data.py)
#
# Run by unicode.luau through noctalia.runAsync, because Luau callbacks only get a 25 ms CPU budget.
#
# Code points: a query like `U+2264`, `u+2264`, `0x2264` or `≤` is a code-point lookup (exact
# match first, then every code point starting with those digits) and skips fzf. Bare numbers are
# ambiguous with names (`ae` is a Lean name, `1` is too), so they are the weakest tier: bare hex of
# 4-6 digits and bare decimal are looked up exactly and appended after the 50 ranked results.
#
# Names and descriptions are three fzf passes whose outputs are concatenated and de-duplicated:
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

# Marks rows that come from a code-point lookup (not counted against the 50-row cap).
code_tag=$(printf '\001')

# Read "key<TAB>row" lines (row = line of data.tsv); print ranked, de-duplicated display rows.
# Lines tagged with $code_tag are appended past the cap of 50.
join_rows() {
    awk -F'\t' -v data="$dir/data.tsv" -v tag="$code_tag" '
        BEGIN {
            while ((getline line < data) > 0) {
                n++
                split(line, f, "\t")
                char[n] = f[1]; title[n] = f[2]; subtitle[n] = f[3]
            }
        }
        !seen[$2]++ {
            if ($1 != tag && rank >= 50) next
            rank++
            print rank "\t" char[$2] "\t" title[$2] "\t" subtitle[$2]
        }'
}

# Print "tag<TAB>row" for data.tsv rows whose hex code point equals HEX, then (when PREFIX is
# non-empty) those starting with PREFIX, then those whose decimal code point equals DEC. Any may
# be empty. data.tsv stores hex as padded uppercase (`0041`), so PREFIX `22` means the 22xx block.
code_rows() {
    awk -F'\t' -v hex="$1" -v dec="$2" -v prefix="$3" -v tag="$code_tag" '
        # Compare as strings: awk would treat 22E2 and 2200 as equal numbers (22 * 10^2).
        hex != "" && ($4 "") == (hex "")           { he[++ne] = NR; next }
        prefix != "" && index($4, prefix) == 1     { hp[++np] = NR; next }
        dec != "" && ($5 "") == (dec "")           { de[++nd] = NR }
        END {
            for (i = 1; i <= ne; i++) print tag "\t" he[i]
            for (i = 1; i <= np; i++) print tag "\t" hp[i]
            for (i = 1; i <= nd; i++) print tag "\t" de[i]
        }' "$dir/data.tsv"
}

# Uppercase hex padded to at least 4 digits, as stored in data.tsv column 4.
canon_hex() {
    printf '%s' "$1" | tr 'a-f' 'A-F' | awk '{ sub(/^0+/, ""); while (length($0) < 4) $0 = "0" $0; print }'
}

# Explicit code-point prefix: `U+`, `u+`, `0x`, `\u` (any case), then hex digits.
compact=$(printf '%s' "$query" | tr -d '[:space:]' | tr 'A-Z' 'a-z')
case $compact in
    u+*)    digits=${compact#u+} ;;
    0x*)    digits=${compact#0x} ;;
    '\u'*)  digits=${compact#'\u'} ;;
    *)      digits= ;;
esac
case $digits in
    '' | *[!0-9a-f]*) ;;
    *)
        # Exact code point first, then the code points that start with these digits.
        code_rows "$(canon_hex "$digits")" "" "$(printf '%s' "$digits" | tr 'a-f' 'A-F')" | join_rows
        exit 0
        ;;
esac

# `\mathbb{R}`, `mathbb R` and `mathbbR` are the same name; descriptions keep their spaces.
name_query=$(printf '%s' "$query" | tr -d '\\{}[:space:]')
desc_query=$(printf '%s' "$query" | tr -d '\\{}')
[ -n "$name_query" ] || exit 0

# Bare numbers, weakest tier: 4-6 hex digits as a code point, and decimal.
bare_hex=
bare_dec=
case $compact in
    '' | *[!0-9a-f]*) ;;
    *)
        [ "${#compact}" -ge 4 ] && [ "${#compact}" -le 6 ] && bare_hex=$(canon_hex "$compact")
        case $compact in
            *[!0-9]*) ;;
            *) [ "${#compact}" -le 7 ] && bare_dec=$(printf '%s' "$compact" | awk '{ sub(/^0+/, ""); print $0 }') ;;
        esac
        ;;
esac

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
    if [ -n "$bare_hex$bare_dec" ]; then
        code_rows "$bare_hex" "$bare_dec" ""
    fi
} | join_rows
