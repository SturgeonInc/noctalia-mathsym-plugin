# Develop in this directory; `make install` copies the plugin into Noctalia's plugin dir.
PLUGIN     := unicode-picker
DATA_HOME  ?= $(or $(XDG_DATA_HOME),$(HOME)/.local/share)
DEST       := $(DATA_HOME)/noctalia/plugins/$(PLUGIN)
SOURCES    := tools/sources
UPSTREAM_ABBR := https://raw.githubusercontent.com/leanprover/vscode-lean4/master/lean4-unicode-input/src/abbreviations.json
UNICODE_MATH_TABLE ?= $(shell find /var/home/linuxbrew/.linuxbrew/Cellar/texlive -name unicode-math-table.tex 2>/dev/null | sort | tail -1)

.PHONY: data fetch-sources install uninstall check

# Regenerate the search database from the vendored sources.
data:
	python3 -I tools/build_data.py $(PLUGIN)/data.tsv

# Refresh vendored sources (Lean table from upstream, unicode-math table from the local TeX Live).
fetch-sources:
	curl -fsSL -o $(SOURCES)/abbreviations.json $(UPSTREAM_ABBR)
	cp "$(UNICODE_MATH_TABLE)" $(SOURCES)/unicode-math-table.tex

# Copy (not symlink) the plugin. Files are updated in place (never rm -rf the dir) so Noctalia's
# file watcher on unicode.luau keeps firing; manifest changes still need a config reload.
install:
	mkdir -p "$(DEST)"
	rsync -a --inplace --delete $(PLUGIN)/ "$(DEST)/"
	@echo "installed to $(DEST)"

uninstall:
	rm -rf "$(DEST)"

# Sanity checks: row shapes, and the top search hit for a few known queries (runs search.sh, needs fzf).
check:
	@awk -F'\t' 'NF != 3 { print "bad data.tsv row " NR; bad = 1 } END { exit bad }' $(PLUGIN)/data.tsv
	@awk -F'\t' 'NF != 2 { print "bad names/desc row " NR; bad = 1 } END { exit bad }' $(PLUGIN)/names.tsv $(PLUGIN)/desc.tsv $(PLUGIN)/codes_hex.tsv $(PLUGIN)/codes_dec.tsv
	@printf '%s\n' 'alpha|α' 'leq|≤' 'le|≤' 'mathbb{R}|ℝ' 'Nat|ℕ' 'Rightarrow|⇒' 'rightarrow|→' 'to|→' \
	    'lnot|¬' 'Go|ω' 'go|⊢' '<=|≤' 'greek lambda|λ' 'r|→' \
	    'U+2264|≤' 'u+2264|≤' '0x2264|≤' '\u2264|≤' 'U+226|≠' '2264|≤' '8804|≤' '945|α' | while IFS='|' read -r query want; do \
	  got=$$(sh $(PLUGIN)/search.sh "$(CURDIR)/$(PLUGIN)" "$$query" | head -n 1 | cut -f2); \
	  [ "$$got" = "$$want" ] || { echo "'$$query': want $$want, got $$got"; exit 1; }; \
	done
	@echo "data ok"
