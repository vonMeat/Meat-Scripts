-- @provides
--   [main] Meat-Script_Render_MarkerSections_Within_Timeline_Selection.lua
-- @description Render Marker Sections Within Timeline Selection
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Render Marker Sections Within Timeline Selection
--   - 1. Finds all normal markers in the current time selection.
--   - 2. Prompts user to open Render Settings and save them (bounding=Project regions, filename=$region, etc.).
--   - 3. Upon confirmation, creates a region for each chunk from marker i to marker i+1 (or sel_end if it’s the last marker).
--   - 4. Calls "Render project, using the most recent render settings" (which the user just saved).
--   - 5. Deletes the newly-created regions, leaving your project as it was.

--------------------------------------------------
-- 0) Helpers
--------------------------------------------------
local function sanitize_filename(str)
  if not str or str == "" then
    return "Unnamed_Marker"
  end
  return str
    :gsub('[\\/:*?"<>|]', "_")  -- Replace illegal filename chars
    :gsub("^%s+", "")           -- Trim leading spaces
    :gsub("%s+$", "")           -- Trim trailing spaces
end

--------------------------------------------------
-- 1) Collect Markers in Current Time Selection
--------------------------------------------------
local sel_start, sel_end = reaper.GetSet_LoopTimeRange(false, false, 0, 0, false)
if (sel_end - sel_start) <= 0 then
  reaper.ShowMessageBox(
    "No time selection found! Please define a time selection and re-run.",
    "Error",
    0
  )
  return
end

local _, num_markers, num_regions = reaper.CountProjectMarkers(0)
local total = num_markers + num_regions
local markers = {}

for i = 0, total - 1 do
  local _, is_region, pos, rgn_end, name, _ = reaper.EnumProjectMarkers(i)
  -- We only want normal markers (not regions):
  if (not is_region) and (pos >= sel_start) and (pos <= sel_end) then
    markers[#markers + 1] = { position = pos, name = name or "" }
  end
end

if #markers == 0 then
  reaper.ShowMessageBox("No normal markers found in the current time selection.", "Error", 0)
  return
end

-- Sort markers by their position (just to be safe):
table.sort(markers, function(a,b) return a.position < b.position end)

--------------------------------------------------
-- 2) Prompt User to Open Render Dialog (BUT do NOT create regions yet)
--------------------------------------------------

-- local config_msg = 
--   "The Render Settings window will now open.\n\n" ..
--   "Temporary regions will be created for each section of markers *after* you save " ..
--   "and close the Render Settings.\n\n" ..
--   "Press OK to proceed, or Cancel to abort the process."
-- local proceed_config = reaper.ShowMessageBox(config_msg, "Configure Render Settings", 1)
-- if proceed_config ~= 1 then
--   -- User pressed Cancel
--   return
-- end


-- Open the Render to File window:
-- reaper.ShowMessageBox(config_msg, "Configure Render Settings", 1)
reaper.Main_OnCommand(40015, 0)  -- "File: Render project..."

--------------------------------------------------
-- 3) Final Confirmation Before Rendering & Region Creation
--------------------------------------------------
local ready_msg =
  "DO NOT RENDER FROM THE 'RENDER TO FILE' WINDOW.\n\n" ..
  "Please verify your render settings:\n\n" ..
  "  - Bounds: Project regions\n" ..
  "  - Source: Master mix OR Selected tracks via master\n" ..
  "  - File name: $region OR $region_$track\n" ..
  "  - Set directory, sample rate, channels etc.\n\n" ..
  "Click 'Save settings' and then CLOSE the Render options window.\n\n" ..
  "Press OK here to proceed with rendering, or Cancel to abort."
local proceed_ready = reaper.ShowMessageBox(ready_msg, "Configure & Confirm Render Settings", 1)
if proceed_ready ~= 1 then
  -- User pressed Cancel
  return
end

--------------------------------------------------
-- 4) Create Temporary Regions Based on Markers, Render, then Remove
--------------------------------------------------
reaper.Undo_BeginBlock()

-- 4a) Create regions
local new_region_ids = {}
for i = 1, #markers do
  local m = markers[i]
  local start_time = m.position
  local end_time = (i < #markers) and markers[i + 1].position or sel_end
  local region_name = sanitize_filename(m.name)

  -- Create region from start_time to end_time (returns a region "ID")
  local new_id = reaper.AddProjectMarker2(0, true, start_time, end_time, region_name, -1, 0)
  new_region_ids[#new_region_ids + 1] = new_id
end

-- 4b) Render using the "most recent render settings"
reaper.Main_OnCommand(41824, 0)  -- "File: Render project, using the most recent render settings, auto-close"

-- 4c) Remove newly-created regions
for i = #new_region_ids, 1, -1 do
  reaper.DeleteProjectMarker(0, new_region_ids[i], true)
end

reaper.Undo_EndBlock("Markers -> Temporary Regions -> Render", -1)

--------------------------------------------------
-- 5) Done
--------------------------------------------------
reaper.ShowMessageBox(
  "Rendering complete!\n\nCheck your output folder to retrieve the files.",
  "Info",
  0
)
