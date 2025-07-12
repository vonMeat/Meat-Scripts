-- @provides
--   [main] Meat-Script_Explorer_Item_SourceFolder.lua
-- @description Explorer Item Source Folder
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Explorer Item Source Folder
--   - Opens the OS file explorer for the folder(s) containing the source file(s).

local DEBUG = false
local function debug(msg)
  if DEBUG then
    reaper.ShowConsoleMsg(msg .. "\n")
  end
end

function OpenItemSourceFolders()
  reaper.ClearConsole()
  debug("=== Script Started ===")
  reaper.Undo_BeginBlock()

  local num_items = reaper.CountSelectedMediaItems(0)
  debug("Selected items: " .. num_items)
  if num_items == 0 then
    reaper.ShowMessageBox("No items selected!", "Open Source Folders", 0)
    return
  end

  -- Keep track of unique directories we've encountered
  local opened_dirs = {}

  for i = 0, num_items - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    debug("Processing item index: " .. i)
    local take = reaper.GetActiveTake(item)
    if take then
      debug("  Active take found.")
      local source = reaper.GetMediaItemTake_Source(take)
      if source then
        debug("  Media source found.")
        local src_type = reaper.GetMediaSourceType(source, "")
        debug("  Media source type: " .. tostring(src_type))
        
        -- If the source is a section, get its parent source
        if src_type == "SECTION" then
          debug("  This is a SECTION type. Trying to get parent media source.")
          local parent = reaper.GetMediaSourceParent(source)
          if parent then
            source = parent
            src_type = reaper.GetMediaSourceType(source, "")
            debug("  Parent media source obtained. New media source type: " .. tostring(src_type))
          else
            debug("  Could not retrieve parent media source for SECTION.")
          end
        end

        local filepath = reaper.GetMediaSourceFileName(source, "")
        debug("  Filepath: " .. tostring(filepath))
        if filepath and filepath ~= "" then
          -- Extract the directory from the path (keeps trailing slash)
          local dir = filepath:match("^(.+[/\\])") or ""
          debug("  Extracted directory: " .. tostring(dir))
          if dir ~= "" then
            if not opened_dirs[dir] then
              opened_dirs[dir] = true
              debug("  Opening folder: " .. dir)
              local result = reaper.CF_ShellExecute(dir)
              debug("  CF_ShellExecute result: " .. tostring(result))
            else
              debug("  Folder already opened: " .. dir)
            end
          else
            debug("  No directory extracted from filepath for item index " .. i)
          end
        else
          debug("  Invalid or empty filepath for item index " .. i)
        end
      else
        debug("  No media source for item index " .. i)
      end
    else
      debug("  No active take for item index " .. i)
    end
  end

  reaper.Undo_EndBlock("Open Source Folders for Selected Items", -1)
  debug("=== Script Finished ===")
end

OpenItemSourceFolders()
