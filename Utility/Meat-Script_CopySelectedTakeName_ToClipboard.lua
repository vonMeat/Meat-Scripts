-- @provides
--   [main] Meat-Script_CopySelectedTakeName_ToClipboard.lua
-- @description Copy Selected Take Name to Clipboard
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Copy Selected Take Name to Clipboard
--   - Copies the active take name of a single selected media item to the system clipboard.
--   - If no item is selected, or more than one item is selected, the script aborts with an error.

--------------------------------------------------------------------------------
-- 1) Simple wrapper for clipboard access (SWS or JS‑ReaScriptAPI)
--------------------------------------------------------------------------------
local function copy_to_clipboard(text)
  if reaper.CF_SetClipboard then                -- SWS
    reaper.CF_SetClipboard(tostring(text))
    return true
  elseif reaper.JS_CopyToClipboard then         -- JS extension
    reaper.JS_CopyToClipboard(tostring(text))
    return true
  else
    reaper.ShowMessageBox(
      "No clipboard function found.\n\nInstall either the SWS Extension or the JS‑ReaScriptAPI extension.",
      "Error: Clipboard unavailable",
      0
    )
    return false
  end
end

--------------------------------------------------------------------------------
-- 2) Main Logic
--------------------------------------------------------------------------------
local function main()
  local sel_count = reaper.CountSelectedMediaItems(0)

  if sel_count == 0 then
    reaper.ShowMessageBox("Please select one media item.", "Nothing selected", 0)
    return
  elseif sel_count > 1 then
    reaper.ShowMessageBox("More than one media item is selected.\nPlease select exactly one.", "Error", 0)
    return
  end

  -- Exactly one item is selected → get its active take
  local item = reaper.GetSelectedMediaItem(0, 0)
  local take = reaper.GetActiveTake(item)
  if not take then
    reaper.ShowMessageBox("The selected item has no active take.", "Error", 0)
    return
  end

  -- Obtain the take name
  local retval, take_name = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  if not retval then take_name = "" end

  -- Copy to clipboard
  copy_to_clipboard(take_name)
end

--------------------------------------------------------------------------------
-- 3) Run
--------------------------------------------------------------------------------
main()
