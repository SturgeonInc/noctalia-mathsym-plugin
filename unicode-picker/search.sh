#!/bin/sh
# Search the unicode tables with fzf; print "rank<TAB>char<TAB>title<TAB>subtitle", best first.
# Usage: search.sh DIR QUERY   (DIR holds the .tsv files written by tools/build_data.py)
#
# Run by unicode.luau through noctalia.runAsync, because Luau callbacks only get a 25 ms CPU budget.
#
# A query containing a non-ASCII character (a pasted `∀`) is a reverse lookup: names are ASCII, so
# it is unambiguous and goes first. Exact character, then entries that start with it (`∀ᵐ`).
# ASCII characters (`<`) stay ordinary name queries.
#
# Then four fzf passes, all concatenated and de-duplicated by character (first 50 kept):
#   1. names, case-sensitive exact substring. Lean's input method is case-sensitive (`\Go` is
#      omega, `\go` is not), so a hit that differs only in case must not beat e.g. `goal`.
#   2. names, case-insensitive fuzzy (typos, and the case-only matches).
#   3. descriptions, case-insensitive fuzzy; spaces mean AND ("greek lambda").
#   4. code points, exact substring of the hex (`2264`, `U+2264`) or decimal (`8804`) code point.
#      Weakest on purpose: bare numbers are ambiguous with names (`ae` and `1` are Lean names).
#      A leading `U+`, `u+`, `0x` or `\u` is stripped for this pass and means hex only; without
#      one, hex and decimal are searched together.
# Within a pass fzf orders by its score, then shorter text first.
#
# Speed: the passes run in parallel and the shell forks as little as possible (about 13 ms total,
# mostly process startup), so query parsing is one awk call rather than a tr per value.

dir=$1
query=$2

# A user's fzf defaults (--height, --tiebreak, ...) must not change how we rank.
FZF_DEFAULT_OPTS=
export FZF_DEFAULT_OPTS
unset FZF_DEFAULT_COMMAND
# Small inputs: Go's default of one scheduler thread per core only adds startup cost.
GOMAXPROCS=1
export GOMAXPROCS

# Interpret the query in one awk call (ASCII only, hence LC_ALL=C). Prints six lines:
#   name_query  `\mathbb{R}`, `mathbb R` and `mathbbR` are the same name: no backslash, braces, spaces
#   desc_query  descriptions keep their spaces (fzf reads them as AND)
#   code_query  hex digits for the code-point pass, with an explicit prefix removed, or empty
#   hex_only    1 when an explicit prefix (`U+`, `u+`, `0x`, `\u`) was given
#   non_ascii   1 when the query contains a non-ASCII byte
#   char_query  the query without whitespace, for the reverse lookup
parsed=$(Q=$query LC_ALL=C awk '
    BEGIN {
        q = ENVIRON["Q"]
        name = q; gsub(/[\\{}[:space:]]/, "", name)
        desc = q; gsub(/[\\{}]/, "", desc)
        chr = q;  gsub(/[[:space:]]/, "", chr)
        low = tolower(name)
        hex = 0
        # The backslash of `≤` is already gone from `name`; the u-hex form needs two digits
        # so that a name like `ud` is not read as a prefix.
        if (low ~ /^u\+/)                     { code = substr(low, 3); hex = 1 }
        else if (low ~ /^0x/)                 { code = substr(low, 3); hex = 1 }
        else if (low ~ /^u[0-9a-f][0-9a-f]/)  { code = substr(low, 2); hex = 1 }
        else                                  code = low
        if (code !~ /^[0-9a-f]+$/) code = ""
        print name; print desc; print code; print hex
        print (q ~ /[^\001-\177]/) ? 1 : 0
        print chr
    }')
{
    IFS= read -r name_query
    IFS= read -r desc_query
    IFS= read -r code_query
    IFS= read -r hex_only
    IFS= read -r non_ascii
    IFS= read -r char_query
} <<EOF
$parsed
EOF
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

# Reverse lookup: "x<TAB>row" lines for data.tsv rows equal to / starting with the query. The query
# goes through the environment because awk -v would process backslash escapes.
char_rows() {
    Q=$char_query awk -F'\t' '
        BEGIN { q = ENVIRON["Q"] }
        ($1 "") == (q "") { e[++ne] = NR; next }
        index($1, q) == 1  { p[++np] = NR }
        END {
            for (i = 1; i <= ne; i++) print "x\t" e[i]
            for (i = 1; i <= np; i++) print "x\t" p[i]
        }' "$dir/data.tsv"
}

# Prefix every line of stdin with pass number $1. One write() per line (fflush) keeps lines whole
# when several passes share the pipe: writes up to PIPE_BUF bytes are atomic.
tag() {
    awk -v t="$1" '{ print t "\t" $0; fflush() }'
}

# The passes are independent, so they run in parallel (about 5 ms each, mostly process startup);
# the final awk orders their output by pass number. No temp files: the shared pipe is the join.
# Its input is "pass<TAB>key<TAB>row" lines, each pass in fzf order, passes interleaved. It ranks
# them first and only then reads data.tsv, keeping just the (at most 50) rows it will print.
{
    [ "$non_ascii" = 1 ] && { char_rows | tag 0 & }
    # +x: the query is literal text, not fzf operators, so names like `<=`, `^alpha`, `|-` work.
    fz "$name_query" +x -e +i < "$dir/names.tsv" | tag 1 &
    fz "$name_query" +x -i < "$dir/names.tsv" | tag 2 &
    fz "$desc_query" -i < "$dir/desc.tsv" | tag 3 &
    if [ -n "$code_query" ]; then
        if [ "$hex_only" = 1 ]; then
            fz "$code_query" -e -i < "$dir/codes_hex.tsv" | tag 4 &
        else
            cat "$dir/codes_hex.tsv" "$dir/codes_dec.tsv" | fz "$code_query" -e -i | tag 4 &
        fi
    fi
    wait
} | DATA=$dir/data.tsv awk -F'\t' '
    function rank_hits(   pass, i, r) {
        for (pass = 0; pass <= 4; pass++)
            for (i = 1; i <= count[pass]; i++) {
                r = row[pass, i]
                if (seen[r]++) continue
                order[++n] = r
                want[r] = 1
                if (n == 50) return
            }
    }
    FILENAME != ENVIRON["DATA"] { count[$1]++; row[$1, count[$1]] = $3; next }
    FNR == 1 { rank_hits() }
    FNR in want { line[FNR] = $0 }
    END {
        if (!n) rank_hits()   # data.tsv was never read (no hits)
        for (i = 1; i <= n; i++) {
            split(line[order[i]], f, "\t")
            print i "\t" f[1] "\t" f[2] "\t" f[3]
        }
    }' - "$dir/data.tsv"
