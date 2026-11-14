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

# Sanity checks on the generated data: row shape and a few known mappings.
check:
	@awk -F'\t' 'NF != 5 { print "bad row " NR; bad = 1 } END { exit bad }' $(PLUGIN)/data.tsv
	@for pair in 'α	alpha' '≤	leq' '≤	le' 'ℝ	mathbb{R}' 'ℕ	Nat' '⇒	Rightarrow' '→	to' '¬	lnot'; do \
	  ch=$${pair%%	*}; name=$${pair##*	}; \
	  grep -qP "^$$ch\t([^\t]* )?\Q$$name\E( [^\t]*)?\t|^$$ch\t[^\t]*\t([^\t]* )?\Q$$name\E( [^\t]*)?\t" $(PLUGIN)/data.tsv \
	    || { echo "missing $$name -> $$ch"; exit 1; }; \
	done
	@echo "data ok"
