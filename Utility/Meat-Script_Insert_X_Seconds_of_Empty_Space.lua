-- @provides
--   [main] Meat-Script_Insert_X_Seconds_of_Empty_Space.lua
-- @description Insert X Seconds of Empty Space
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Insert X Seconds of Empty Space
--   - Prompts user for amount of empty space to insert
--   - Inserts that amount of empty space at the playhead; effectively shifting project to the right.
--   - Recommended to add to 'Ruler/arrange' menu

local ACTION_INSERT_EMPTY_SPACE = 40200 -- Time selection: Insert empty space at time selection (moving later items)

local function prompt_seconds()
  local ok, s = reaper.GetUserInputs("Insert Time at Playhead", 1, "Seconds to insert:", "10.0")
  if not ok then return nil end
  local v = tonumber(s)
  if not v or v <= 0 then
    reaper.ShowMessageBox("Enter a positive number of seconds.", "Invalid input", 0)
    return nil
  end
  return v
end

local function main()
  local delta = prompt_seconds()
  if not delta then return end

  -- Save selection and loop state
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
  local loop_start, loop_end = reaper.GetSet_LoopTimeRange(false, true, 0, 0, false)
  local is_loop_linked = reaper.GetToggleCommandState(40385) == 1 -- Options: Loop points linked to time selection

  local cur = reaper.GetCursorPosition()

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  -- Make a temporary time selection [cur, cur+delta]
  if is_loop_linked then reaper.Main_OnCommand(40385, 0) end -- temporarily unlink
  reaper.GetSet_LoopTimeRange(true, false, cur, cur + delta, false)

  -- Native insert (preserves ordering, tempo map, automation, etc.)
  reaper.Main_OnCommand(ACTION_INSERT_EMPTY_SPACE, 0)

  -- Restore previous time selection and loop points
  reaper.GetSet_LoopTimeRange(true, false, ts_start, ts_end, false)
  reaper.GetSet_LoopTimeRange(true, true, loop_start, loop_end, false)
  if is_loop_linked then reaper.Main_OnCommand(40385, 0) end -- relink

  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.Undo_EndBlock(string.format("Insert %.3fs at playhead", delta), -1)
end

main()