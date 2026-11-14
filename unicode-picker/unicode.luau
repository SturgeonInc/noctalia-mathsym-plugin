--!nonstrict
-- Unicode picker launcher provider.
--
-- Type `/uni` followed by a LaTeX command name (`\alpha`, `leq`, `mathbb{R}`) or a
-- Lean 4 VS Code abbreviation (`Rightarrow`, `nat`, `<=`) to find the character;
-- anything else is matched against the character's description ("integral").
-- Enter copies the character to the clipboard.
--
-- Script callbacks only get a 25 ms CPU budget, which parsing the ~3000-row
-- data.tsv blows through. So the search runs in search.py via noctalia.runAsync
-- (the same approach as the community file-search plugin) and this script only
-- relays its JSON rows to the launcher.

local NOTIFY = noctalia.getConfig("notify_on_copy")
NOTIFY = if type(NOTIFY) == "boolean" then NOTIFY else true

local function hint(query, title, subtitle, glyph)
  launcher.setResults(query, { { id = "", title = title, subtitle = subtitle, glyph = glyph } })
end

-- `query` is the launcher text after the `/uni` prefix.
function onQuery(query)
  local text = noctalia.string.trim(query)
  if text == "" then
    hint(
      query,
      "Search unicode characters",
      "LaTeX name (\\alpha, mathbb{R}), Lean abbreviation (Rightarrow), or description",
      "math-symbols"
    )
    return
  end

  local dir = noctalia.pluginDir()
  local ok = noctalia.runAsync({ "python3", "-I", dir .. "/search.py", dir, text }, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      noctalia.log(result.stderr)
      hint(query, "Search failed", "Is python3 installed? See the noctalia log", "alert-triangle")
      return
    end
    local rows = noctalia.json.decode(result.stdout)
    if type(rows) ~= "table" or #rows == 0 then
      hint(query, "No matches", "Try a different name", "mood-empty")
      return
    end
    for _, r in rows do
      r.glyph = "math-symbols"
      -- The launcher keeps the highlight on the same result id across result updates, so a
      -- stale highlight from an earlier keystroke would survive reordering. A per-query
      -- suffix makes ids new each query, so the highlight resets to the top row.
      r.id = r.id .. "\t" .. query
    end
    launcher.setResults(query, rows)
  end, 5000)
  if not ok then
    hint(query, "Search failed", "Could not start python3", "alert-triangle")
  end
end

function onActivate(id)
  -- The payload is an arbitrary character followed by a tab and the query (see onQuery).
  if id:sub(1, 2) ~= "u:" then
    return
  end
  local ch = id:sub(3):match("^[^\t]*")
  if ch == "" then
    return
  end
  noctalia.copyToClipboard(ch, "text/plain")
  if NOTIFY then
    noctalia.notify("Unicode", ch .. " copied to clipboard")
  end
end
