-- @provides
--   [main] Meat-Script_Insert_X_Markers_Every_Y_Seconds.lua
-- @description Insert X markers every Y seconds
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Insert X markers every Y seconds
--   - Prompts user how many markers to place every given number of seconds
--   - Starting from playhead, places markers to specification on user confirmation

local function prompt_params()
  local ok, csv = reaper.GetUserInputs(
    "Insert Markers at Interval",
    2,
    "Spacing (seconds):,How many markers:",
    "1.0,8"
  )
  if not ok then return nil end

  -- Split "a,b" into two fields
  local s, n = csv:match("^%s*([^,]+)%s*,%s*([^,]+)%s*$")
  if not s or not n then
    reaper.ShowMessageBox("Please enter two values separated by a comma.", "Invalid input", 0)
    return nil
  end

  -- Normalize decimal comma ONLY on the spacing field, then convert
  local s_norm = (s:gsub(",", "."))  -- capture only the first return value
  local spacing = tonumber(s_norm)
  local count   = tonumber(n)

  if not spacing or spacing <= 0 or not count or count < 1 then
    reaper.ShowMessageBox("Enter a positive spacing and a marker count >= 1.", "Invalid input", 0)
    return nil
  end

  return spacing, math.floor(count)
end

local function main()
  local spacing, count = prompt_params()
  if not spacing then return end

  local start_pos = reaper.GetCursorPosition()

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for i = 0, count - 1 do
    local pos = start_pos + (i * spacing)
    reaper.AddProjectMarker2(0, false, pos, 0, "", -1, 0)
  end

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock(string.format("Insert %d markers every %.3fs from cursor", count, spacing), -1)
  reaper.UpdateArrange()
end

main()
