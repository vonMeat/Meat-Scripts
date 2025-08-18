-- @provides
--   [main] Meat-Script_Explorer_Item_LibraryFolder.lua
-- @description Explorer Item Library Folder
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Explorer Item Library Folder
--   Given selected media item(s) this script opens OS explorer to its location(s) in the user provided sound library
--   - First run with no saved library path: asks for the folder and saves it (ExtState).
--   - New project: first time you run it, asks whether to keep or change the saved path.
--   - If it's a 'glued' or renamed take, should still find the original if it exists in your Library; except if you glued a renamed take.
--   - Recommended to add to the 'Media item context' menu.

-------------------------------------
-- 0) USER SETTINGS (debug only)
-------------------------------------
local DEBUG = false

-------------------------------------
-- A) Persistence helpers
-------------------------------------
local EXT_NS   = "LibrarySearch"          -- global ExtState namespace
local EXT_KEY  = "root"                   -- global ExtState key (saved across sessions)
local PROJ_NS  = "LibrarySearch"          -- per-project namespace
local PROJ_KEY = "confirmed"              -- set to "1" once we’ve confirmed for this project

local function log(msg)
  if DEBUG then reaper.ShowConsoleMsg(tostring(msg) .. "\n") end
end

local function has_trailing_sep(p)
  return p:sub(-1) == "/" or p:sub(-1) == "\\"
end

local function join_path(dir, leaf)
  if dir == "" then return leaf end
  local sep = has_trailing_sep(dir) and "" or "/"
  return dir .. sep .. leaf
end

-- Try to sniff whether a directory exists by asking REAPER to enumerate it.
local function dir_exists(path)
  if not path or path == "" then return false end
  -- any file or subdir enumerated means the path is valid; if empty folder, we still need a check
  local f = reaper.EnumerateFiles(path, 0)
  local d = reaper.EnumerateSubdirectories(path, 0)
  if f or d then return true end

  -- Empty directories often return nil for both; try probing the parent as a fallback sanity check
  -- but still allow empty folders by checking whether accessing the path raises nil consistently.
  -- There isn’t a perfect API for this in vanilla; accept nil as “maybe empty” only if the parent works.
  local parent = path:match("^(.*)[/\\][^/\\]+$") or ""
  if parent ~= "" then
    local parentProbe = reaper.EnumerateFiles(parent, 0) or reaper.EnumerateSubdirectories(parent, 0)
    -- If parent exists but the folder yields nil for both, assume the folder exists but is empty.
    if parentProbe then return true end
  end
  return false
end

-- Folder picker (JS_ReaScriptAPI if available), else text prompt
local function prompt_for_folder(default_path)
  -- Prefer JS folder dialog if present
  if reaper.JS_Dialog_BrowseForFolder then
    local title = "Select your sound library folder"
    local start = default_path ~= "" and default_path or reaper.GetResourcePath()
    local ok, out = reaper.JS_Dialog_BrowseForFolder(title, start)
    if ok and out and out ~= "" then
      return out
    else
      return nil -- canceled
    end
  end

  -- Fallback: simple text input
  local def = default_path ~= "" and default_path or reaper.GetResourcePath()
  local retval, input = reaper.GetUserInputs("Sound Library Root", 1, "Enter absolute folder path:", def)
  if not retval or not input or input == "" then return nil end
  return input
end

-- Normalize slashes (avoid Lua escape drama in literals)
local function normalize_path(p)
  if not p then return "" end
  p = p:gsub("\\", "/")
  -- Don’t force a trailing slash; REAPER’s enumeration handles both
  return p
end

-- Load/save global path
local function load_saved_root()
  return reaper.GetExtState(EXT_NS, EXT_KEY) or ""
end

local function save_root(p)
  reaper.SetExtState(EXT_NS, EXT_KEY, p or "", true) -- persist
end

-- Per-project confirmation flag
local function is_project_confirmed()
  local rv, val = reaper.GetProjExtState(0, PROJ_NS, PROJ_KEY)
  return rv == 1 and val == "1"
end

local function set_project_confirmed()
  reaper.SetProjExtState(0, PROJ_NS, PROJ_KEY, "1")
end

-- Resolve library root with the required UX:
-- 1) If no saved root, prompt and save.
-- 2) If saved root exists but project not confirmed, ask to keep/change.
-- 3) Return the final path or nil if the user cancels.
local function resolve_library_root()
  local saved = normalize_path(load_saved_root() or "")

  if saved == "" then
    -- First ever run: ask user for a folder
    while true do
      local picked = prompt_for_folder("")
      if not picked then return nil end -- cancel
      picked = normalize_path(picked)
      if not dir_exists(picked) then
        reaper.ShowMessageBox("That folder doesn’t seem to exist. Please pick a valid directory.", "Invalid path", 0)
      else
        save_root(picked)
        set_project_confirmed() -- also mark this project confirmed on first set
        return picked
      end
    end
  end

  -- We have a saved path. If project isn’t confirmed yet, ask once.
  if not is_project_confirmed() then
    local msg = ("Sound library is set to:\n\n%s\n\nContinue using this path?"):format(saved)
    -- type=4 shows Yes/No on Windows/macOS; returns 6 for Yes, 7 for No
    local choice = reaper.ShowMessageBox(msg, "Confirm Sound Library", 4)
    if choice == 7 then
      -- User wants to change it
      while true do
        local picked = prompt_for_folder(saved)
        if not picked then return nil end -- cancel
        picked = normalize_path(picked)
        if not dir_exists(picked) then
          reaper.ShowMessageBox("That folder doesn’t seem to exist. Please pick a valid directory.", "Invalid path", 0)
        else
          save_root(picked)
          set_project_confirmed()
          return picked
        end
      end
    else
      -- Keep existing
      set_project_confirmed()
      return saved
    end
  end

  -- Project already confirmed; just use it
  return saved
end

-------------------------------------
-- B) Name/extension helpers
-------------------------------------
local SEARCH_EXTS = { ".wav",".aif",".aiff",".flac",".mp3",".ogg",".caf",".wv",".opus",".m4a" }

local function split_ext(filename)
  local base, ext = filename:match("^(.*)%.([^.]+)$")
  if base and ext then
    return base, "." .. ext
  else
    return filename, ""
  end
end

-- Remove any trailing "-glued" suffix from a basename (not from the extension)
local function strip_glued_suffix(name)
  if type(name) ~= "string" or name == "" then return name end
  local base, ext = split_ext(name)        -- ext includes leading "." or ""
  -- strip trailing: -glued, -glued-01, -glued 01, etc. (but only at the very end)
  base = base:gsub("%-glued[%s%-]*%d*$", "")
  return base .. ext
end

-- Get the active take's SOURCE file basename (handles SECTION parents), minus "-glued"
-- Returns: base, ext, leaf  (e.g. "my_take", ".wav", "my_take.wav")
local function get_source_base_name(item)
  local take = reaper.GetActiveTake(item)
  if not take then return nil end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end

  -- Unwrap SECTION container to its parent media source if needed
  local stype = reaper.GetMediaSourceType(src, "")
  if stype == "SECTION" then
    local parent = reaper.GetMediaSourceParent(src)
    if parent then src = parent end
  end

  local path = reaper.GetMediaSourceFileName(src, "") or ""
  if path == "" then return nil end
  local leaf = path:match("([^/\\]+)$") or path
  local base, ext = split_ext(leaf)
  base = strip_glued_suffix(base)
  return base, ext, leaf
end

local function norm(s) return string.lower(s or "") end

local function build_name_candidates(takeName)
  takeName = strip_glued_suffix(takeName)
  local t = {}
  local base, ext = split_ext(takeName)
  if ext ~= "" then
    t[#t+1] = norm(takeName)
    t[#t+1] = norm(base)
  else
    t[#t+1] = norm(base)
    for _, x in ipairs(SEARCH_EXTS) do
      t[#t+1] = norm(base .. x)
    end
  end
  local seen, out = {}, {}
  for _, v in ipairs(t) do
    if not seen[v] then seen[v] = true; out[#out+1] = v end
  end
  return out
end

local function get_best_take_name(item)
  local take = reaper.GetActiveTake(item)
  if not take then return nil end
  local _, nm = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  nm = strip_glued_suffix(nm)
  if nm and nm ~= "" then return nm end
  local src = reaper.GetMediaItemTake_Source(take)
  if not src then return nil end
  local t = reaper.GetMediaSourceType(src, "")
  if t == "SECTION" then
    local parent = reaper.GetMediaSourceParent(src)
    if parent then src = parent end
  end
  local path = reaper.GetMediaSourceFileName(src, "")
  if not path or path == "" then return nil end
  local leaf = path:match("([^/\\]+)$") or path
  local base = split_ext(leaf)
  base = strip_glued_suffix(base) 
  return base
end

-------------------------------------
-- C) Library indexing
-------------------------------------
local function new_set() return { _keys = {} } end
local function set_add(s, v) if not s[v] then s[v] = true; table.insert(s._keys, v) end end
local function set_keys(s) return s._keys end

local function index_library(root)
  local byFull, byBase = {}, {}
  local stack = { root }
  while #stack > 0 do
    local dir = table.remove(stack)
    local i = 0
    while true do
      local fname = reaper.EnumerateFiles(dir, i)
      if not fname then break end
      local full = norm(fname)
      local base = norm(split_ext(fname))
      byFull[full] = byFull[full] or new_set()
      set_add(byFull[full], dir)
      byBase[base] = byBase[base] or new_set()
      set_add(byBase[base], dir)
      i = i + 1
    end
    local j = 0
    while true do
      local sub = reaper.EnumerateSubdirectories(dir, j)
      if not sub then break end
      local nextDir = join_path(dir, sub)
      table.insert(stack, nextDir)
      j = j + 1
    end
  end
  return byFull, byBase
end

-------------------------------------
-- D) Main
-------------------------------------
local function main()
  -- Resolve or ask for the library path as requested
  local LIBRARY_ROOT = resolve_library_root()
  if not LIBRARY_ROOT or LIBRARY_ROOT == "" then
    return -- User canceled
  end

  LIBRARY_ROOT = normalize_path(LIBRARY_ROOT)

  local num_items = reaper.CountSelectedMediaItems(0)
  if num_items == 0 then
    reaper.ShowMessageBox("No items selected.", "Find In Library", 0)
    return
  end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)
  if DEBUG then reaper.ClearConsole() end

  log("Indexing library. This may take a moment on large folders...")
  local byFull, byBase = index_library(LIBRARY_ROOT)
  log("Index complete.")

  local opened_dirs = {}
  local to_open = {}

  for i = 0, num_items - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local take = reaper.GetActiveTake(item)
    local srcName = nil

    if take then
      local src = reaper.GetMediaItemTake_Source(take)
      if src then
        local srcPath = reaper.GetMediaSourceFileName(src, "")
        if srcPath and srcPath ~= "" then
          local leaf = srcPath:match("([^/\\]+)$") -- strip path
          srcName = strip_glued_suffix(leaf)      -- strip "-glued"
        end
      end
    end

    if not srcName or srcName == "" then
      log(string.format("[Item %d] No source file name found.", i+1))
    else
      local candidates = build_name_candidates(srcName)
      local found_dirs = new_set()

      for _, cand in ipairs(candidates) do
        cand = norm(cand) -- <<< normalize before lookup
        local base, ext = split_ext(cand)
        if ext ~= "" then
          local set = byFull[cand]
          if set then
            for _, d in ipairs(set_keys(set)) do set_add(found_dirs, d) end
          end
        else
          local set = byBase[cand]
          if set then
            for _, d in ipairs(set_keys(set)) do set_add(found_dirs, d) end
          end
        end
      end

      local dirs = set_keys(found_dirs)
      if #dirs == 0 then
        log(string.format("[Item %d] '%s' not found under library.", i+1, srcName))
      else
        for _, d in ipairs(dirs) do
          if not opened_dirs[d] then
            opened_dirs[d] = true
            table.insert(to_open, d)
          end
        end
      end
    end
  end

  if #to_open == 0 then
    local msg = ("No matching files were found in the library.\n\n" ..
                 "Sound library is set to:\n\n%s\n\nChange library path?"):format(LIBRARY_ROOT)
    local choice = reaper.ShowMessageBox(msg, "Find In Library", 4) -- 4 = Yes/No
    if choice == 6 then
      local newPath = prompt_for_folder(LIBRARY_ROOT)
      if newPath and newPath ~= "" then
        save_root(normalize_path(newPath))
        set_project_confirmed()
        reaper.ShowMessageBox("Library path updated.", "Find In Library", 0)
      end
    end
    return
  else
    for _, dir in ipairs(to_open) do
      log("Opening: " .. dir)
      reaper.CF_ShellExecute(dir) -- requires SWS
    end
  end

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Open Explorer to Library Folders for Takes", -1)
end



main()
