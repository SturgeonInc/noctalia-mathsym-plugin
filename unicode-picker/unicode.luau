--!nonstrict
-- Unicode picker launcher provider.
--
-- Type `/uni` followed by a LaTeX command name (`\alpha`, `leq`, `mathbb{R}`) or a
-- Lean 4 VS Code abbreviation (`Rightarrow`, `nat`, `<=`) to find the character;
-- anything else is matched against the character's description ("integral").
-- Enter copies the character to the clipboard.
--
-- Script callbacks only get a 25 ms CPU budget, which parsing the ~3000-row
-- data.tsv blows through. So the search runs in search.awk via noctalia.runAsync
-- (the same approach as the community file-search plugin) and this script only
-- relays its tab-separated rows to the launcher.

local NOTIFY = noctalia.getConfig("notify_on_copy")
NOTIFY = if type(NOTIFY) == "boolean" then NOTIFY else true

local RESULT_LIMIT = 50

local PASTE = noctalia.getConfig("paste_after_copy")
PASTE = if type(PASTE) == "boolean" then PASTE else false
local PASTE_DELAY_MS = noctalia.getConfig("paste_delay_ms")
PASTE_DELAY_MS = if type(PASTE_DELAY_MS) == "number" then PASTE_DELAY_MS else 150

-- Plugin providers have no native auto-paste hook (the built-in emoji provider uses one),
-- and the launcher only hands focus back after onActivate returns. So wait a moment in a
-- helper process, then type the character into the focused window with wtype.
local function pasteAfterClose(ch)
  local script = 'sleep "$0"; exec wtype -- "$1"'
  local argv = { "sh", "-c", script, string.format("%.3f", PASTE_DELAY_MS / 1000), ch }
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

  -- Score with awk, rank with sort (C locale: ties fall back to byte order of the line,
  -- i.e. codepoint order), keep the top rows. The query goes in via the environment.
  local dir = noctalia.pluginDir()
  local script = 'Q="$1" awk -f "$0/search.awk" "$0/data.tsv"'
    .. ' | LC_ALL=C sort -t "$(printf \'\\t\')" -k1,1nr | head -n ' .. RESULT_LIMIT
  local ok = noctalia.runAsync({ "sh", "-c", script, dir, text }, function(result)
    if result.exitCode ~= 0 or result.timedOut then
      noctalia.log(result.stderr)
      hint(query, "Search failed", "See the noctalia log", "alert-triangle")
      return
    end
    local rows = {}
    for line in result.stdout:gmatch("[^\n]+") do
      local score, ch, title, subtitle = line:match("^(%d+)\t([^\t]*)\t([^\t]*)\t(.*)$")
      if score then
        table.insert(rows, {
          -- The launcher keeps the highlight on the same result id across result updates, so a
          -- stale highlight from an earlier keystroke would survive reordering. A per-query
          -- suffix makes ids new each query, so the highlight resets to the top row.
          id = "u:" .. ch .. "\t" .. query,
          title = title,
          subtitle = subtitle,
          glyph = "math-symbols",
          score = tonumber(score),
        })
      end
    end
    if #rows == 0 then
      hint(query, "No matches", "Try a different name", "mood-empty")
      return
    end
    launcher.setResults(query, rows)
  end, 5000)
  if not ok then
    hint(query, "Search failed", "Could not start awk", "alert-triangle")
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
  if PASTE then
    pasteAfterClose(ch)
  end
end
