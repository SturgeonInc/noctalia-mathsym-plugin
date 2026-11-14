# Score every row of data.tsv against the query in $Q; print "score<TAB>char<TAB>title<TAB>subtitle".
# POSIX awk only. The query comes through the environment (not -v, which would process
# backslash escapes such as the `\a` in `\alpha`). The caller sorts and truncates.
#
# data.tsv columns: 1 char, 2 title, 3 subtitle, 4 names (normalized, case-sensitive,
# space-separated), 5 lowercase description.
#
# Rank: case-sensitive exact (1000) > short prefix (<=700) > case-insensitive exact (650) >
# longer prefix > substring (<=500) > description words (300). Lean's input method is
# case-sensitive (`\Go` is omega, `\go` is not), so a match differing only in case is a
# fallback and must not beat e.g. `goal`.

function min(a, b) { return a < b ? a : b }

BEGIN {
    FS = "\t"
    q = ENVIRON["Q"]
    token = q
    gsub(/[\\{} \t]/, "", token)          # `\mathbb{R}`, `mathbb R` and `mathbbR` are one name
    tl = tolower(token)
    tlen = length(tl)
    if (tlen == 0) exit
    lq = tolower(q)
    gsub(/\\/, "", lq)
    nw = split(lq, words, " ")
}

{
    best = 0
    n = split($4, names, " ")
    for (i = 1; i <= n; i++) {
        name = names[i] ""                 # force string comparison (names like `1` are numeric-looking)
        low = tolower(name)
        len = length(low)
        if (name == (token "")) s = 1000
        else if (low == tl) s = 650
        else {
            at = index(low, tl)
            if (at == 1) s = 700 - min(len - tlen, 99)
            else if (at > 1) s = 500 - min(len - (at - 1) - tlen, 99)
            else s = 0
        }
        if (s > best) best = s
    }
    if (best < 300 && tlen >= 2 && nw > 0) {
        ok = 1
        for (i = 1; i <= nw; i++) if (index($5, words[i]) == 0) { ok = 0; break }
        if (ok) best = 300
    }
    if (best > 0) print best "\t" $1 "\t" $2 "\t" $3
}
