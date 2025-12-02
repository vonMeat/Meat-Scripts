-- @provides
--   [main] Meat-Script_Toggle_Auto_Track_Renamer.lua
-- @description Toggle: Auto Track Renamer
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Toggle: Auto Track Renamer
--   While enabled, continuously renames tracks using names of media items contained within.
--   
--   Track naming is based on the following rules: 
--   1. Parent track has no media items: 'TRACK_EMPTY'
--   2. If parent track or any of its children has media items:
--      - If any media item is a video file (.mp4, .mov, etc), base name is "!REF_VISUAL".
--      - Else gathers all words within media items on the track; any media items on parent track have word priority.
--      - Two most frequent words become the base name for the parent track.
--      - All children/sub-children inherit the base name and are numbered sequentially.
--   3. Empty Item override:
--      - If any track has an Empty Item with text, that track becomes its own base group:
--      - That track's name is the Empty Item text (uppercased), with no numeric suffix.
--      - Its children inherit that base and are numbered sequentially.
--   4. "!" override: 
--      - Add "!" ahead of any track name to force the base name.
--      - Overrides all other naming rules.
--
--   TIPS :
--   -> Use the variables below 'ignore_words' and 'prefer_words' to tailer the naming preferences to your liking.

--   Recommended to add to a custom toolbar via toolbar docker.
--   -> When disabling, select 'Terminate instances' and 'Remember my answer for this script'
--   -> Toggle once to enable (toolbar button lights up), toggle again to disable (restores all visible).
--   
--   WARNING : If you accidentally enabled the script and want to undo 
--             FIRST disable the script before undoing, or old names may be overwritten.
-- @changelog
--   - Improve functionality of track naming overrides.

local r = reaper

-------------------------------------------------------
-- USER CONFIG
-------------------------------------------------------

-- Words to ignore completely when building base names (case-insensitive)
-- Example: { "the", "and", "of", "fx" }
local ignore_words = {"DTCK", "glued", "CECK", "GP", "SFX", "CFCK", "CC", "CK", "CH", "CK", "CREK", "UEDS", "DS", 
"MLCK", "CRAFT", "HRCK", "CREK", "SOUNDDESIGN", "SOUND", "DESIGN", "MECH", "MECK", "MBCK", "MEDS",
"DBDS", "BOOM", "DBCK", "by", "the", "and", "of", "fx", "IMM"
  -- "the", "and", "of", "fx"
}

-- Words to prefer when there is a tie in frequency (case-insensitive)
-- Example: { "impact", "whoosh", "hit" }
local prefer_words = {"AMB", "CLOTH", "IMPACT", "WHOOSH", "KICK", "SWEETENER", "METAL", "RING"
  -- "impact", "whoosh", "hit"
}

-- Video file extensions that trigger !REF_VISUAL (lowercase, no dot)
local VIDEO_EXTS = {
  mp4  = true,
  mov  = true,
  m4v  = true,
  avi  = true,
  mkv  = true,
  webm = true,
  mpg  = true,
  mpeg = true,
  wmv  = true,
  mxf  = true,
}

-------------------------------------------------------
-- INTERNAL CONFIG DERIVED FROM USER CONFIG
-------------------------------------------------------

local IGNORE_SET = {}
for _, w in ipairs(ignore_words) do
  if type(w) == "string" and w ~= "" then
    IGNORE_SET[w:lower()] = true
  end
end

local PREFER_SET = {}
for _, w in ipairs(prefer_words) do
  if type(w) == "string" and w ~= "" then
    PREFER_SET[w:lower()] = true
  end
end

-------------------------------------------------------
-- TOGGLE / SINGLETON STATE
-------------------------------------------------------

local NS          = "Meat_AutoTrackRenamer"
local KEY_RUNNING = "running"
local KEY_STOP    = "stop"
local KEY_TOKEN   = "token"

-- Toolbar toggle state
local _, _, sectionID, cmdID = r.get_action_context()
local function set_toggle(on)
  r.SetToggleCommandState(sectionID, cmdID, on and 1 or 0)
  r.RefreshToolbar2(sectionID, cmdID)
end

-- ExtState helpers
local function get(key) return r.GetExtState(NS, key) end
local function set(key, val) r.SetExtState(NS, key, tostring(val or ""), false) end

-- Singleton: if another instance is running, ask it to stop and exit
if get(KEY_RUNNING) == "1" then
  set(KEY_STOP, "1")
  set(KEY_TOKEN, tostring(math.random()) .. os.clock())
  set_toggle(false)
  return
end

-- Mark this instance as running
local MY_TOKEN = tostring(math.random()) .. os.clock()
set(KEY_TOKEN,   MY_TOKEN)
set(KEY_STOP,    "0")
set(KEY_RUNNING, "1")

-- State
local running = true
local last_state_change = -1

-- Locked tracks
local function is_locked(track)
    local ok, name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if not ok or not name or name == "" then return false end

    -- Any !REF_VISUAL* (base or numbered) is NOT a lock
    -- e.g. "!REF_VISUAL", "!REF_VISUAL_01", "!REF_VISUAL_12" etc.
    if name:sub(1, 11) == "!REF_VISUAL" then
        return false
    end

    -- Any other name starting with "!" is considered locked
    return name:sub(1,1) == "!"
end

-- Return the base name for a locked track (strip leading "!")
local function locked_base_name(track)
  local ok, nm = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if not ok or not nm or nm == "" then return nil end
  if nm:sub(1,1) ~= "!" then return nil end
  -- "!REF_VISUAL" is not considered locked by is_locked(), so no special case here
  return nm:sub(2)
end

-------------------------------------------------------
-- TRACK TREE
-------------------------------------------------------

local function buildTrackTree()
  local n = r.CountTracks(0)
  local nodes_by_track = {}
  local tracks = {}

  for i = 0, n - 1 do
    local tr = r.GetTrack(0, i)
    tracks[#tracks + 1] = tr
    nodes_by_track[tr] = {
      track    = tr,
      parent   = nil,
      children = {},
      -- to be filled later:
      empty_base = nil,
      has_video  = false,
      freq_base  = nil,
      has_items  = false,
      base       = nil,
      owner      = nil,
      new_name   = nil,
    }
  end

  local roots = {}

  for _, tr in ipairs(tracks) do
    local node = nodes_by_track[tr]
    local parent_tr = r.GetParentTrack(tr)
    if parent_tr then
      local parent_node = nodes_by_track[parent_tr]
      node.parent = parent_node
      table.insert(parent_node.children, node)
    else
      table.insert(roots, node)
    end
  end

  return roots, nodes_by_track
end

-------------------------------------------------------
-- ITEM ANALYSIS
-------------------------------------------------------

-- Analyze items on a single track. Returns:
--   empty_base (string or nil)  -> text of first Empty Item (uppercased), if any
--   has_video (boolean)         -> true if any take uses a video extension
--   freq_base (string or nil)   -> base from word frequency, or nil if no usable words
--   has_items (boolean)         -> true if the track has at least one media item
local function analyze_track_items(track)
  local item_count = r.CountTrackMediaItems(track)
  local has_items = item_count > 0

  local empty_base = nil
  local has_video  = false

  local freq      = {}
  local first_pos = {}
  local pos       = 0

  for i = 0, item_count - 1 do
    local item = r.GetTrackMediaItem(track, i)

    local num_takes = r.GetMediaItemNumTakes(item)
    local take      = r.GetActiveTake(item)

    -- Empty Item detection (no takes or no active take)
    if (not take or num_takes == 0) and not empty_base then
      local _, note = r.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
      if note and note ~= "" then
        empty_base = note:upper()
      end
    end

    -- Video detection
    if take then
      local src = r.GetMediaItemTake_Source(take)
      if src then
        local src_name = r.GetMediaSourceFileName(src, "")
        if src_name and src_name ~= "" then
          local ext = src_name:match("%.([%w]+)$")
          if ext then
            ext = ext:lower()
            if VIDEO_EXTS[ext] then
              has_video = true
            end
          end
        end
      end
    end

    -- Word frequency (ignore Empty Items; they have no takes)
    local name = nil

    if take then
      -- Prefer take name
      local ok, tname = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      if ok and tname and tname ~= "" then
        name = tname
      else
        -- Fallback to source filename without path and extension
        local src = r.GetMediaItemTake_Source(take)
        if src then
          local buf = r.GetMediaSourceFileName(src, "")
          if buf and buf ~= "" then
            local filename = buf:match("([^/\\]+)$") or buf
            filename = filename:gsub("%.[^%.]+$", "")
            name = filename
          end
        end
      end
    end

    if name and name ~= "" then
      local nm = name:lower()
      -- Safety: strip trailing extension if present
      nm = nm:gsub("%.[%w]+$", "")

      for word in nm:gmatch("%w+") do
        pos = pos + 1

        -- Skip numeric-only tokens
        if not word:match("^%d+$") then
          -- Skip ignored words
          if not IGNORE_SET[word] then
            freq[word] = (freq[word] or 0) + 1
            if not first_pos[word] then
              first_pos[word] = pos
            end
          end
        end
      end
    end
  end

  local freq_base = nil

  if next(freq) ~= nil then
    local ranked = {}
    for w, c in pairs(freq) do
      ranked[#ranked + 1] = {
        w    = w,
        c    = c,
        pos  = first_pos[w] or math.huge,
        pref = PREFER_SET[w] and 1 or 0,
      }
    end

    table.sort(ranked, function(a, b)
      if a.c ~= b.c then
        return a.c > b.c                 -- higher frequency first
      end
      if a.pref ~= b.pref then
        return a.pref > b.pref           -- preferred words win ties
      end
      return a.pos < b.pos               -- earlier first appearance wins
    end)

    local base_words = { ranked[1].w }
    if #ranked >= 2 then
      base_words[2] = ranked[2].w
    end

    for i = 1, #base_words do
      base_words[i] = base_words[i]:upper()
    end

    freq_base = table.concat(base_words, "_")
  end

  return empty_base, has_video, freq_base, has_items
end

-- Analyze all items in the subtree under a root node (children + sub-children only).
-- Returns:
--   empty_base (string or nil)
--   has_video  (boolean)
--   freq_base  (string or nil)
--   has_items  (boolean)  -> true if any descendant has items
local function analyze_subtree_items(root_node)
  local empty_base = nil
  local has_video  = false
  local has_items  = false

  local freq      = {}
  local first_pos = {}
  local pos       = 0

  local function walk(node)
    for _, child in ipairs(node.children) do
      local track       = child.track
      local item_count  = r.CountTrackMediaItems(track)

      if item_count > 0 then
        has_items = true
      end

      for i = 0, item_count - 1 do
        local item = r.GetTrackMediaItem(track, i)
        local num_takes = r.GetMediaItemNumTakes(item)
        local take      = r.GetActiveTake(item)

        -- Empty item in descendants: first one wins for base
        if (not take or num_takes == 0) and not empty_base then
          local _, note = r.GetSetMediaItemInfo_String(item, "P_NOTES", "", false)
          if note and note ~= "" then
            empty_base = note:upper()
          end
        end

        -- Video detection in descendants
        if take then
          local src = r.GetMediaItemTake_Source(take)
          if src then
            local src_name = r.GetMediaSourceFileName(src, "")
            if src_name and src_name ~= "" then
              local ext = src_name:match("%.([%w]+)$")
              if ext then
                ext = ext:lower()
                if VIDEO_EXTS[ext] then
                  has_video = true
                end
              end
            end
          end
        end

        -- Word frequency from descendant tracks
        local name = nil
        if take then
          local ok, tname = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
          if ok and tname and tname ~= "" then
            name = tname
          else
            local src = r.GetMediaItemTake_Source(take)
            if src then
              local buf = r.GetMediaSourceFileName(src, "")
              if buf and buf ~= "" then
                local filename = buf:match("([^/\\]+)$") or buf
                filename = filename:gsub("%.[^%.]+$", "")
                name = filename
              end
            end
          end
        end

        if name and name ~= "" then
          local nm = name:lower()
          nm = nm:gsub("%.[%w]+$", "")

          for word in nm:gmatch("%w+") do
            pos = pos + 1
            if not word:match("^%d+$") then
              if not IGNORE_SET[word] then
                freq[word] = (freq[word] or 0) + 1
                if not first_pos[word] then
                  first_pos[word] = pos
                end
              end
            end
          end
        end
      end

      walk(child)
    end
  end

  walk(root_node)

  local freq_base = nil
  if next(freq) ~= nil then
    local ranked = {}
    for w, c in pairs(freq) do
      ranked[#ranked + 1] = {
        w    = w,
        c    = c,
        pos  = first_pos[w] or math.huge,
        pref = PREFER_SET[w] and 1 or 0,
      }
    end

    table.sort(ranked, function(a, b)
      if a.c ~= b.c then
        return a.c > b.c
      end
      if a.pref ~= b.pref then
        return a.pref > b.pref
      end
      return a.pos < b.pos
    end)

    local base_words = { ranked[1].w }
    if #ranked >= 2 then
      base_words[2] = ranked[2].w
    end

    for i = 1, #base_words do
      base_words[i] = base_words[i]:upper()
    end

    freq_base = table.concat(base_words, "_")
  end

  return empty_base, has_video, freq_base, has_items
end

-------------------------------------------------------
-- BASE / OWNER ASSIGNMENT
-------------------------------------------------------

local function assign_bases_and_owners(roots, nodes_by_track)
  -- First pass: analyze items on every track
  for _, node in pairs(nodes_by_track) do
    local empty_base, has_video, freq_base, has_items = analyze_track_items(node.track)
    node.empty_base = empty_base
    node.has_video  = has_video
    node.freq_base  = freq_base
    node.has_items  = has_items
  end

  -- Second pass: for each root, determine its base and propagate through descendants
  local function propagate_from_root(root)
    local base

    local locked       = is_locked(root.track)
    local locked_base  = locked_base_name(root.track)

    if locked and locked_base and locked_base ~= "" then
      -- Locked parent: always use its own name (without the "!") as base,
      -- ignoring Empty Items or media-derived bases.
      base = locked_base
    elseif root.empty_base then
      -- Root has its own Empty Item text
      base = root.empty_base
    else
      if root.has_items then
        -- Root has items itself
        if root.has_video then
          base = "!REF_VISUAL"
        elseif root.freq_base then
          base = root.freq_base
        else
          base = "TRACK_EMPTY"
        end
      else
        -- Root has no items; NEW RULE:
        -- If any children or sub-children have items, derive base from all subtree items.
        local sub_empty, sub_has_video, sub_freq, sub_has_items = analyze_subtree_items(root)
        if sub_has_items then
          if sub_empty then
            base = sub_empty
          elseif sub_has_video then
            base = "!REF_VISUAL"
          elseif sub_freq then
            base = sub_freq
          else
            base = "TRACK_EMPTY"
          end
        else
          base = "TRACK_EMPTY"
        end
      end
    end


    root.base  = base
    root.owner = root

    local function recurse(node)
      for _, child in ipairs(node.children) do
        local child_locked      = is_locked(child.track)
        local child_locked_base = child_locked and locked_base_name(child.track) or nil

        if child_locked and child_locked_base and child_locked_base ~= "" then
          -- Locked child: becomes its own base group, using its own name (without "!")
          child.base  = child_locked_base
          child.owner = child
        elseif child.empty_base then
          -- Empty Item override: new base group (only for UNLOCKED tracks)
          child.base  = child.empty_base
          child.owner = child
        else
          -- Inherit both base and owner from parent
          child.base  = node.base
          child.owner = node.owner
        end

        recurse(child)
      end
    end

    recurse(root)
  end

  for _, root in ipairs(roots) do
    propagate_from_root(root)
  end
end

-------------------------------------------------------
-- NAME ASSIGNMENT
-------------------------------------------------------

local function apply_names(nodes_by_track)
  local owner_index = {}
  local ntracks = r.CountTracks(0)

  for i = 0, ntracks - 1 do
    local tr   = r.GetTrack(0, i)
    local node = nodes_by_track[tr]

    if node then
      -- Skip auto-renaming for locked tracks ("!" prefix)
      if not is_locked(tr) then
        local owner   = node.owner
        local desired

        if owner == node then
          -- Owner track: base only
          desired = node.base or "TRACK_EMPTY"
          if not owner_index[owner] then
            owner_index[owner] = 0
          end
        else
          if owner then
            local idx = (owner_index[owner] or 0) + 1
            owner_index[owner] = idx
            desired = (node.base or "TRACK_EMPTY") .. "_" .. string.format("%02d", idx)
          else
            desired = node.base or "TRACK_EMPTY"
          end
        end

        local _, current_name = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
        if current_name ~= desired then
          r.GetSetMediaTrackInfo_String(tr, "P_NAME", desired, true)
        end
      end
    end
  end
end

-------------------------------------------------------
-- MAIN RENAME ENTRY
-------------------------------------------------------

local function rename_tracks()
  local ntracks = r.CountTracks(0)
  if ntracks == 0 then return end

  local roots, nodes_by_track = buildTrackTree()
  assign_bases_and_owners(roots, nodes_by_track)
  apply_names(nodes_by_track)
end

-------------------------------------------------------
-- LOOP / LIFECYCLE
-------------------------------------------------------

-- Only apply when the project actually changed
local function apply_if_needed()
  if not running then return end

  local current_change = r.GetProjectStateChangeCount(0)
  if current_change == last_state_change then
    return
  end

  rename_tracks()
  last_state_change = current_change
end

local function stop_and_restore()
  if not running then return end
  running = false

  set_toggle(false)
  set(KEY_RUNNING, "0")
  set(KEY_STOP,    "0")
end

r.atexit(stop_and_restore)

local function loop()
  if not running then return end

  -- Kill switch and singleton token check
  if get(KEY_STOP) == "1" or get(KEY_TOKEN) ~= MY_TOKEN then
    stop_and_restore()
    return
  end

  apply_if_needed()
  r.defer(loop)
end

-- Start
set_toggle(true)
apply_if_needed()
loop()