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

local PASTE_MODE = noctalia.getConfig("paste_mode")
PASTE_MODE = if type(PASTE_MODE) == "string" then PASTE_MODE else "off"
local PASTE_DELAY_MS = noctalia.getConfig("paste_delay_ms")
PASTE_DELAY_MS = if type(PASTE_DELAY_MS) == "number" then PASTE_DELAY_MS else 150

-- wtype arguments per paste mode; "type" types the character itself.
local PASTE_KEYS = {
  ctrl_v = { "-M", "ctrl", "-k", "v", "-m", "ctrl" },
  ctrl_shift_v = { "-M", "ctrl", "-M", "shift", "-k", "v", "-m", "shift", "-m", "ctrl" },
  shift_insert = { "-M", "shift", "-k", "Insert", "-m", "shift" },
}

-- The launcher closes after onActivate returns and only then hands focus back, and
-- plugins have no native auto-paste hook (the built-in emoji provider uses one), so
-- wait a moment in a helper process and then send keys with wtype.
local function pasteAfterClose(ch)
  local keys = if PASTE_MODE == "type" then { "--", ch } else PASTE_KEYS[PASTE_MODE]
  if not keys then
    return
  end
  local argv = { "sh", "-c", 'sleep "$0"; exec wtype "$@"', string.format("%.3f", PASTE_DELAY_MS / 1000) }
  for _, k in keys do
    table.insert(argv, k)
  end
  noctalia.runAsync(argv, function(result)
    if result.exitCode ~= 0 then
      noctalia.log("paste failed: " .. (result.stderr or ""))
    end
  end, 5000)
end

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
  if PASTE_MODE ~= "off" then
    pasteAfterClose(ch)
  end
end
