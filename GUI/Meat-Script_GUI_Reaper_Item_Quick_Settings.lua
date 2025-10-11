-- @provides
--   [main] Meat-Script_GUI_Reaper_Item_Quick_Settings.lua
--   [nomain] ProggyClean.ttf
-- @description Reaper Item Quick Settings GUI
-- @version 1.3
-- @author Jeremy Romberg
-- @about
--   ### Reaper Item Quick Settings GUI
--   Prerequisits:
--   - ReaImGui (cfillion)
--   - Explorer Item Source Folder (Meat-Scripts)
-- 
--   This GUI displays controls for each selected item’s first take.
--   
--   Settings that can be toggled between displayed/hidden:
--   - Name, Volume, Pan, Pitch, Play Rate, Pitch Mode, and EQ.
--   - EQ parameter enables the application of basic EQ curves (high pass, low pass, band pass):
--   - > Dynamically adds/removes ReaEQ (named 'RS_EQ') to the end of the FX chain on the take.
--   - > Script supports moving the EQ instance wherever you want.
--
--   Always-displayed settings include: 
--   - Solo & Mute buttons: applies to the track of the media item.
--   - Loop: sets timeline selection to the item, moves playhead to its start, enables 'Repeat'.
--   - Rename: applies the text written in the 'Name' field to the take.
--   - Source: opens windows explorer to the location of the audio file on the disk drive.
--   - FX: opens the FX window for the take.
--   - Reverse: applies to the take. 
--   - Hold: keeps a given item in the GUI, regardless if it is selected or not.
-- @extrequires ReaImGui
-- @changelog
--   - Fixed crash related to PushFont

-------------------------------------------------
-- WINDOW SIZE CONSTANTS
-------------------------------------------------
local INITIAL_WINDOW_WIDTH   = 650
local INITIAL_WINDOW_HEIGHT  = 400
local NO_ITEM_WINDOW_WIDTH   = 400
local NO_ITEM_WINDOW_HEIGHT  = 0

-------------------------------------------------
-- USER SETTINGS for Volume, Pan, Pitch & Rate
-------------------------------------------------
local MIN_VOLUME, MAX_VOLUME = 0.0, 4.0
local MIN_PAN,    MAX_PAN    = -1.0, 1.0
local MIN_PITCH,  MAX_PITCH  = -50, 50
local PITCH_SPEED = 0.01
local MIN_RATE,   MAX_RATE   = 0.01, 5.0

-------------------------------------------------
-- PITCH MODES
-------------------------------------------------
local pitchModes = {
  { value = -65536,  label = "Project default"           },
  { value = 0,       label = "SoundTouch"                },
  { value = 131072,  label = "Simple windowed (fast)"    },
  { value = 393216,  label = "elastique 2.2.8 Pro"       },
  { value = 458752,  label = "elastique 2.2.8 Efficient" },
  { value = 524288,  label = "elastique 2.2.8 Soloist"   },
  { value = 589824,  label = "elastique 3.3.3 Pro"       },
  { value = 655360,  label = "elastique 3.3.3 Efficient" },
  { value = 720896,  label = "elastique 3.3.3 Soloist"   },
  { value = 851968,  label = "Rubber Band Library"       },
  { value = 983040,  label = "ReaReaRea"                 },
  { value = 917504,  label = "Rrreeeaaa"                 },
}

local function findPitchModeIndex(modeVal)
  for i, pm in ipairs(pitchModes) do
    if pm.value == modeVal then
      return i - 1
    end
  end
  return 0
end

local function getPitchModeValueFromIndex(idx)
  local i = idx + 1
  if i < 1 or i > #pitchModes then
    return pitchModes[1].value
  end
  return pitchModes[i].value
end

-------------------------------------------------
-- CREATE IMGUI CONTEXT
-------------------------------------------------
if not reaper.ImGui_CreateContext then
  reaper.ShowMessageBox("ReaImGui extension not found.\nInstall via ReaPack.", "ERROR", 0)
  return
end
local ctx = reaper.ImGui_CreateContext("Reaper Item Quick Settings")

-- Load font
local dir       = debug.getinfo(1,"S").source:match("@(.+)[/\\]") or ""
local font_path = dir .. "/ProggyClean.ttf"
local font      

-- Support Older Imgui
if reaper.ImGui_CreateFontFromFile then
  -- Newer ReaImGui versions
  font = reaper.ImGui_CreateFontFromFile(font_path)
else
  -- Older ReaImGui versions
  font = reaper.ImGui_CreateFont("sans-serif", 14)
end

if not font then
  r.ShowMessageBox("Failed to load ProggyClean.ttf", "Font error", 0)
  return
end
reaper.ImGui_Attach(ctx, font)

-- Project State Change for undo logic 
local lastProjStateChangeCount = reaper.GetProjectStateChangeCount(0)

-------------------------------------------------
-- DATA STORAGE & SHOW/HIDE TOGGLES
-------------------------------------------------
local displayedItems    = {}
local lastSelectionHash = ""

-- "Hold" logic:
local heldItems         = {}        -- Map: tostring(item) -> item info
local heldItemsOrder    = {}        -- List of item keys in the order they were held
local holdRank = {}                 -- Map: itemKey -> integer
local newlyUnheldItems  = {}        -- Mark items that just got un-held

local forceRefresh = false

local showVolume = true
local showPan    = true
local showPitch  = true
local showRate   = true
local showMode   = true
local showEQ     = true

-- Load stored values if they exist
local function loadSettings()
  local function getBool(extStateVal, default)
    -- If extStateVal is "0", return false; if "1", return true; else default.
    if extStateVal == "0" then return false
    elseif extStateVal == "1" then return true
    else return default
    end
  end

  showVolume = getBool(reaper.GetExtState("ItemQuickSettings", "showVolume"), showVolume)
  showPan    = getBool(reaper.GetExtState("ItemQuickSettings", "showPan"),    showPan)
  showPitch  = getBool(reaper.GetExtState("ItemQuickSettings", "showPitch"),  showPitch)
  showRate   = getBool(reaper.GetExtState("ItemQuickSettings", "showRate"),   showRate)
  showMode   = getBool(reaper.GetExtState("ItemQuickSettings", "showMode"),   showMode)
  showEQ     = getBool(reaper.GetExtState("ItemQuickSettings", "showEQ"),     showEQ)
end

loadSettings()

-------------------------------------------------
-- HELPER: RGBA -> 32-bit integer
-------------------------------------------------
local function ColorConvertFloat4ToU32(r, g, b, a)
  local function clamp(x)
    return math.floor(math.max(0, math.min(255, x * 255 + 0.5)))
  end
  local R, G, B, A = clamp(r), clamp(g), clamp(b), clamp(a)
  return (A << 24) | (B << 16) | (G << 8) | R
end

-------------------------------------------------
-- HELPER: TAKE NAME
-------------------------------------------------
local function getItemTakeName(take)
  if not take then return "" end
  local _, nm = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  return nm or ""
end

local function setTakeName(take, newName)
  if not take then return end
  reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", newName, true)
end

-------------------------------------------------
-- BUILD SELECTION HASH
-------------------------------------------------
local function buildSelectionHash()
  local cnt = reaper.CountSelectedMediaItems(0)
  if cnt == 0 then return "" end
  local t = {}
  for i = 0, cnt - 1 do
    local it = reaper.GetSelectedMediaItem(0, i)
    t[#t + 1] = tostring(it)
  end
  table.sort(t)
  return table.concat(t, "|")
end

-------------------------------------------------
-- EQ INTEGRATION
-------------------------------------------------
local EQ_PRESET_OFF = "RS_EQ_DISABLED"
local EQ_PRESET_HPF = "RS_EQ_HPF"
local EQ_PRESET_LPF = "RS_EQ_LPF"
local EQ_PRESET_BPF = "RS_EQ_BPF"

-- Guarded param->freq
local function eq_paramToFreq(param)
  if not param or param < 0 then param = 0 end
  local minF, maxF = 20, 24000
  local lnMin, lnMax = math.log(minF), math.log(maxF)
  local lnF = lnMin + param * (lnMax - lnMin)
  return math.exp(lnF)
end

local function eq_freqToParam(freq)
  if not freq or freq < 20 then freq = 20 end
  if freq > 24000 then freq = 24000 end
  local lnMin, lnMax = math.log(20), math.log(24000)
  local lnF = math.log(freq)
  return (lnF - lnMin) / (lnMax - lnMin)
end

local function eq_displayFreq(guiFreq)
  if not guiFreq or guiFreq < 20 then
    guiFreq = 20
  elseif guiFreq > 24000 then
    guiFreq = 24000
  end
  local minF, maxF = 20, 24000
  local lnMin, lnMax = math.log(minF), math.log(maxF)
  local p = (math.log(guiFreq) - lnMin) / (lnMax - lnMin)

  local base = 1.011 * p^3 - 1.8005 * p^2 + 1.7895 * p
  local g = base
  if p > 0.5 and p <= 0.9 then
    g = base + 0.10 * (p - 0.5)^(1.5)
  elseif p > 0.9 then
    g = base + 0.10 * (0.9 - 0.5)^(1.5) + 0.03 * (p - 0.9)^(1.5)
  end
  return math.exp(g * (lnMax - lnMin) + lnMin)
end

local function eq_isValidPreset(tk, fx)
  local retval, presetName = reaper.TakeFX_GetPreset(tk, fx)
  if not retval or type(presetName) ~= "string" then return false end
  if presetName:find("HPF") or presetName:find("LPF") or presetName:find("BPF") or presetName:find("DISABLED") then
    return true
  end
  return false
end

local function eq_findByRenamedName(tk)
  local count = reaper.TakeFX_GetCount(tk)
  for i = 0, count - 1 do
    local val = reaper.TakeFX_GetNamedConfigParm(tk, i, "renamed_name")
    if val and eq_isValidPreset(tk, i) then
      return i
    end
  end
  return -1
end

local function eq_findByFXNameSubstring(tk)
  local count = reaper.TakeFX_GetCount(tk)
  for i = 0, count - 1 do
    local retval, fxnm = reaper.TakeFX_GetFXName(tk, i, "")
    if fxnm and eq_isValidPreset(tk, i) then
      return i
    end
  end
  return -1
end

local function eq_renameFXtoRSEQ(tk, fx)
  reaper.TakeFX_SetNamedConfigParm(tk, fx, "fx_name", "RS_EQ")
  reaper.TakeFX_SetNamedConfigParm(tk, fx, "renamed_name", "RS_EQ")
  reaper.TakeFX_SetNamedConfigParm(tk, fx, "DONE", "")
end

-- Create or find ReaEQ
local function eq_createNew(tk)
  local count = reaper.TakeFX_GetCount(tk)
  local validFound = false
  local invalidInstances = {}
  for i = 0, count - 1 do
    local retval, fxnm = reaper.TakeFX_GetFXName(tk, i, "")
    if retval and fxnm and fxnm:find("ReaEQ") then
      if eq_isValidPreset(tk, i) then
        validFound = true
      else
        local originalName = reaper.TakeFX_GetNamedConfigParm(tk, i, "renamed_name")
        table.insert(invalidInstances, { index = i, originalName = originalName })
      end
    end
  end

  if validFound then
    -- Return first valid instance
    for i = 0, count - 1 do
      local retval, fxnm = reaper.TakeFX_GetFXName(tk, i, "")
      if retval and fxnm and fxnm:find("ReaEQ") and eq_isValidPreset(tk, i) then
        return i
      end
    end
  end

  for _, inst in ipairs(invalidInstances) do
    reaper.TakeFX_SetNamedConfigParm(tk, inst.index, "renamed_name", "ReaEQ_USER")
  end

  local newIdx = reaper.TakeFX_AddByName(tk, "ReaEQ (Cockos)", 1)
  if newIdx < 0 then
    for _, inst in ipairs(invalidInstances) do
      reaper.TakeFX_SetNamedConfigParm(tk, inst.index, "renamed_name", inst.originalName or "")
    end
    return -1
  end

  for _, inst in ipairs(invalidInstances) do
    local restoreName = (type(inst.originalName) == "string") and inst.originalName or "VST: ReaEQ (Cockos)"
    reaper.TakeFX_SetNamedConfigParm(tk, inst.index, "renamed_name", restoreName)
  end

  eq_renameFXtoRSEQ(tk, newIdx)
  reaper.TakeFX_SetPreset(tk, newIdx, EQ_PRESET_OFF)
  return newIdx
end

local function eq_modeFromPresetName(presetName)
  if presetName:find("HPF") then
    return "HPF"
  elseif presetName:find("LPF") then
    return "LPF"
  elseif presetName:find("BPF") then
    return "BPF"
  end
  return "OFF"
end

local function eq_updateFromFX(tk, fxIndex)
  if fxIndex < 0 then
    return 1000, "OFF"
  end
  local paramVal = reaper.TakeFX_GetParam(tk, fxIndex, 0)
  local freq = eq_paramToFreq(paramVal)
  local retval, presetName = reaper.TakeFX_GetPreset(tk, fxIndex)
  if not retval or type(presetName) ~= "string" then
    presetName = ""
  end
  local mode = eq_modeFromPresetName(presetName)
  return freq, mode
end

local function eq_getForTake(tk)
  -- Return (fxIndex, freq, mode)
  local idx = eq_findByRenamedName(tk)
  if idx >= 0 then
    local retval, presetName = reaper.TakeFX_GetPreset(tk, idx)
    if retval and presetName and
       (presetName:find("HPF") or presetName:find("LPF") or presetName:find("BPF")) then
      local freq, mode = eq_updateFromFX(tk, idx)
      return idx, freq, mode
    else
      local retval, fxName = reaper.TakeFX_GetFXName(tk, idx, "")
      if retval and fxName and fxName:find("ReaEQ") then
        reaper.TakeFX_Delete(tk, idx)
      end
      return -1, 1000, "OFF"
    end
  end

  idx = eq_findByFXNameSubstring(tk)
  if idx >= 0 then
    local retval, presetName = reaper.TakeFX_GetPreset(tk, idx)
    if retval and presetName and
       (presetName:find("HPF") or presetName:find("LPF") or presetName:find("BPF")) then
      local freq, mode = eq_updateFromFX(tk, idx)
      return idx, freq, mode
    else
      local retval, fxName = reaper.TakeFX_GetFXName(tk, idx, "")
      if retval and fxName and fxName:find("ReaEQ") then
        reaper.TakeFX_Delete(tk, idx)
      end
      return -1, 1000, "OFF"
    end

  end

  return -1, 1000, "OFF"
end

-------------------------------------------------
-- REFRESH SELECTED ITEMS
-------------------------------------------------
local function refreshSelectedItems()

  -- Clean up held items that are no longer valid
  for key, info in pairs(heldItems) do
    if not reaper.ValidatePtr2(0, info.item, "MediaItem*") then
      heldItems[key] = nil
    end
  end

  local cnt = reaper.CountSelectedMediaItems(0)
  local selectionLookup = {}
  local itemsList = {}

  -- 1) Gather currently selected items
  for i = 0, cnt - 1 do
    local item = reaper.GetSelectedMediaItem(0, i)
    local key  = tostring(item)
    selectionLookup[key] = true

    local take = reaper.GetMediaItemTake(item, 0)
    if take then
      -- Normal fields
      local _, nm = reaper.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
      if nm == "" then nm = "Item " .. key end

      local vol      = reaper.GetMediaItemTakeInfo_Value(take, "D_VOL")       or 1.0
      local pan      = reaper.GetMediaItemTakeInfo_Value(take, "D_PAN")       or 0.0
      local pitch    = reaper.GetMediaItemTakeInfo_Value(take, "D_PITCH")     or 0
      local rate     = reaper.GetMediaItemTakeInfo_Value(take, "D_PLAYRATE")  or 1.0
      local preserve = reaper.GetMediaItemTakeInfo_Value(take, "B_PPITCH")    or 0
      local modeVal  = reaper.GetMediaItemTakeInfo_Value(take, "I_PITCHMODE") or 0
      local isRev    = (reaper.GetMediaItemTakeInfo_Value(take, "B_REVERSE") == 1)
      --local isHeld   = (heldItems[key] ~= nil)

      -- NEW: get EQ parameters so eqMode is never nil
      local fxIndex, eqFreq, eqMode = eq_getForTake(take)
      if not eqMode then eqMode = "OFF" end

      local info = {
        item        = item,
        take        = take,
        itemName    = nm,
        volume      = vol,
        pan         = pan,
        pitch       = pitch,
        rate        = rate,
        preserve    = preserve,
        pitchMode   = modeVal,
        isReversed  = isRev,
        hold        = (heldItems[key] ~= nil),

        -- EQ
        eqFxIndex   = fxIndex,
        eqFreq      = eqFreq,
        eqMode      = eqMode,  -- guaranteed non-nil
      }
      
      -- **Update heldItems if this item is currently held.**
      if heldItems[key] then
        heldItems[key] = info
      end
      
      itemsList[#itemsList + 1] = info
    end
  end

  -- 2) Also include held items that are not selected
  for k, oldInfo in pairs(heldItems) do
    if not selectionLookup[k] then
      itemsList[#itemsList + 1] = oldInfo
    end
  end

  -- 3) If the user’s selection changed, clear newlyUnheldItems
  local newHash = buildSelectionHash()
  if newHash ~= lastSelectionHash then
    newlyUnheldItems = {}
  end

  -----------------------------------------------------------------
  -- 4) Sort: Held items up top, sorted by holdRank; non-held keep old order
  -----------------------------------------------------------------
  -- Helper: return track number (1 = highest track)
  local function getTrackNumber(item)
    local track = reaper.GetMediaItemTrack(item)
    return reaper.CSurf_TrackToID(track, false) -- false returns the unselected ordering
  end

  -- Build oldPos lookup (preserving prior display order)
  local oldPos = {}
  for oldIndex, oldInfo in ipairs(displayedItems) do
    local k = tostring(oldInfo.item)
    oldPos[k] = oldIndex
  end

  -- Count how many non-held items in itemsList are new (i.e. not present in oldPos)
  local nonHeldNewCount = 0
  for _, info in ipairs(itemsList) do
    local k = tostring(info.item)
    if not heldItems[k] and not oldPos[k] then
      nonHeldNewCount = nonHeldNewCount + 1
    end
  end

  table.sort(itemsList, function(a, b)
    local aKey = tostring(a.item)
    local bKey = tostring(b.item)
    local aHeld = (heldItems[aKey] ~= nil)
    local bHeld = (heldItems[bKey] ~= nil)

    if aHeld and not bHeld then
      return true
    elseif bHeld and not aHeld then
      return false
    elseif aHeld and bHeld then
      -- For held items, preserve original order (using holdRank or oldPos)
      local oA = oldPos[aKey] or 999999
      local oB = oldPos[bKey] or 999999
      return oA < oB
    else
      -- For non-held items, check if they were already in the display order:
      local aOld = oldPos[aKey]
      local bOld = oldPos[bKey]
      if aOld and bOld then
        return aOld < bOld
      elseif aOld then
        return true  -- a was already displayed, so it comes first
      elseif bOld then
        return false -- b was already displayed, so it comes first
      else
        -- Both are new: sort by track number, then by position
        local trackA = getTrackNumber(a.item)
        local trackB = getTrackNumber(b.item)
        if trackA ~= trackB then
          return trackA < trackB  -- lower track number means higher on screen
        else
          local posA = reaper.GetMediaItemInfo_Value(a.item, "D_POSITION")
          local posB = reaper.GetMediaItemInfo_Value(b.item, "D_POSITION")
          return posA < posB
        end
      end
    end
  end)

  -----------------------------------------------------------------
  -- 5) Done — no leapfrogging pass
  -----------------------------------------------------------------
  displayedItems = itemsList
  lastSelectionHash = newHash  -- Keep your hash in sync
end

-------------------------------------------------
-- HELPER: FOCUS REAPER
-------------------------------------------------
local function focusReaperMain()
  if reaper.JS_Window_SetFocus then
    reaper.JS_Window_SetFocus(reaper.GetMainHwnd())
  end
end

-------------------------------------------------
-- MAIN GUI LOOP
-------------------------------------------------
local function frame()

  -- Check if a project state change (undo/redo, etc.) occurred
  local currentStateCount = reaper.GetProjectStateChangeCount(0)
  if currentStateCount ~= lastProjStateChangeCount then
    refreshSelectedItems()  -- Re-read all parameters from the project
    lastProjStateChangeCount = currentStateCount
  end

  local hash = buildSelectionHash()
  -- If selection changed or forced, we refresh
  if hash == "" or forceRefresh or hash ~= lastSelectionHash then
    refreshSelectedItems()
    lastSelectionHash = hash
    forceRefresh = false
  end

  local winW, winH = INITIAL_WINDOW_WIDTH, INITIAL_WINDOW_HEIGHT
  if #displayedItems == 0 then
    winW, winH = NO_ITEM_WINDOW_WIDTH, NO_ITEM_WINDOW_HEIGHT
  end
  reaper.ImGui_SetNextWindowSize(ctx, winW, winH, reaper.ImGui_Cond_FirstUseEver())

  -- Font set
  --reaper.ImGui_PushFont(ctx, font, 16)
  
  -- Push font only when visible
  local font_pushed = false
  do
    local ok = pcall(reaper.ImGui_PushFont, ctx, font, 16)
    if ok then font_pushed = true end
  end

  -- Start
  local visible, open = reaper.ImGui_Begin(ctx, "Reaper Item Quick Settings", true, reaper.ImGui_WindowFlags_AlwaysAutoResize())
  if visible then
  
    

    -- Show/hide toggles
    reaper.ImGui_Text(ctx, "Show/hide:")
    reaper.ImGui_SameLine(ctx, nil, 8)
    if reaper.ImGui_Checkbox(ctx, "Vol##toggle", showVolume) then showVolume = not showVolume end
    reaper.ImGui_SameLine(ctx, nil, 6)
    if reaper.ImGui_Checkbox(ctx, "Pan##toggle", showPan) then showPan = not showPan end
    reaper.ImGui_SameLine(ctx, nil, 6)
    if reaper.ImGui_Checkbox(ctx, "Pitch##toggle", showPitch) then showPitch = not showPitch end
    reaper.ImGui_SameLine(ctx, nil, 6)
    if reaper.ImGui_Checkbox(ctx, "Rate##toggle", showRate) then showRate = not showRate end
    reaper.ImGui_SameLine(ctx, nil, 6)
    if reaper.ImGui_Checkbox(ctx, "Mode##toggle", showMode) then showMode = not showMode end
    reaper.ImGui_SameLine(ctx, nil, 6)
    if reaper.ImGui_Checkbox(ctx, "EQ##toggle", showEQ) then showEQ = not showEQ end
    reaper.ImGui_SameLine(ctx, nil, 6)
    reaper.ImGui_Text(ctx, "   ")
    reaper.ImGui_Separator(ctx)

    if #displayedItems == 0 then
      reaper.ImGui_Text(ctx, "No items selected.")
      -- Padding
      reaper.ImGui_Dummy(ctx, 418, 0)
    else
      -- "Selected items: X"
      reaper.ImGui_Text(ctx, ("Selected items: %2d"):format(#displayedItems))

      -- Button : Reset Visible Values
      reaper.ImGui_SameLine(ctx, nil, 138)                 -- small gap
      local resetLbl = "Reset"
      local txtW, _  = reaper.ImGui_CalcTextSize(ctx, resetLbl)
      local btnW     = txtW + 16                          -- 8-px padding each side
      if reaper.ImGui_Button(ctx, resetLbl .. "##ResetAllVisible", btnW) then
        ------------------------------------------------------------------------
        -- 1)  Commit CURRENT values to the undo stack
        --     (creates its own undo step so we can come back here)
        ------------------------------------------------------------------------
        reaper.Undo_BeginBlock()
        reaper.MarkProjectDirty(0)                  -- force a snapshot even if nothing
        reaper.Undo_EndBlock("RIQS: Commit Visible Values", -1)

        ------------------------------------------------------------------------
        -- 2)  Now perform the actual reset as a second undo step
        ------------------------------------------------------------------------
        reaper.Undo_BeginBlock()
        reaper.PreventUIRefresh(1)

        for _, info in ipairs(displayedItems) do
          local take = info.take
          local itm  = info.item

          if showVolume then
            info.volume = 1.0
            reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", 1.0)
          end
          if showPan then
            info.pan = 0.0
            reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", 0.0)
          end
          if showPitch then
            info.pitch = 0
            reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", 0)
          end
          if showRate then
            info.rate = 1.0
            reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", 1.0)
          end
          if showEQ then
            if info.eqFxIndex and info.eqFxIndex >= 0 then
              reaper.TakeFX_Delete(take, info.eqFxIndex)
            end
            info.eqFxIndex = -1
            info.eqFreq    = 1000
            info.eqMode    = "OFF"
          end

          reaper.UpdateItemInProject(itm)
        end

        reaper.PreventUIRefresh(-1)
        reaper.MarkProjectDirty(0)
        forceRefresh = true
        reaper.Undo_EndBlock("RIQS: Reset Visible Values", -1)
      end

      -- If more than 1 item displayed, draw "Hold All" / "Release All" at far right
      if #displayedItems >= 1 then
        -- Move to the same line
        reaper.ImGui_SameLine(ctx, nil, 5)

        if reaper.ImGui_Button(ctx, "Hold##HoldAllBtn") then
          for idx, info in ipairs(displayedItems) do
            local key = tostring(info.item)
            if not heldItems[key] then
              -- Mark item as held
              heldItems[key] = info
              info.hold      = true

              -- Add to heldItemsOrder if not present
              local found = false
              for _, k in ipairs(heldItemsOrder) do
                if k == key then
                  found = true
                  break
                end
              end
              if not found then
                table.insert(heldItemsOrder, key)
              end

              -- Clear newlyUnheldItems flag
              newlyUnheldItems[key] = nil
              
              -- NEW: set holdRank if it isn’t already
              if not holdRank[key] then
                holdRank[key] = idx  -- the item’s current display index
              end
              
            end
          end
        end

        reaper.ImGui_SameLine(ctx, nil, 5)
        if reaper.ImGui_Button(ctx, "Release##ReleaseAllBtn") then
          for _, info in ipairs(displayedItems) do
            local key = tostring(info.item)
            if heldItems[key] then
              -- Un-hold this item
              heldItems[key] = nil
              info.hold      = false

              -- Remove from heldItemsOrder
              for idx, k in ipairs(heldItemsOrder) do
                if k == key then
                  table.remove(heldItemsOrder, idx)
                  break
                end
              end

              -- Mark as newly unheld
              newlyUnheldItems[key] = true
            end
          end
        end
      end

      reaper.ImGui_Separator(ctx)

      for i, info in ipairs(displayedItems) do
        local item = info.item
        local take = info.take
        local suffix = "##" .. tostring(item) .. "_" .. i

        -- Row 1: Name, Mute/Solo, etc.
        reaper.ImGui_Text(ctx, "Name      ")
        reaper.ImGui_SameLine(ctx, nil, 8)
        reaper.ImGui_PushItemWidth(ctx, 340)
        local changedName, newName = reaper.ImGui_InputText(ctx, "##ItemName" .. suffix, info.itemName, 128)
        reaper.ImGui_PopItemWidth(ctx)
        if changedName then
          info.itemName = newName
        end
        
        reaper.ImGui_Text(ctx, "          ")
        reaper.ImGui_SameLine(ctx, nil, 8)
        local track = reaper.GetMediaItemTrack(item)
        local soloState = reaper.GetMediaTrackInfo_Value(track, "I_SOLO")
        local muteState = reaper.GetMediaTrackInfo_Value(track, "B_MUTE")

        -- Some color styling
        local greyBG   = ColorConvertFloat4ToU32(0.3, 0.9, 0.7, 0.6)
        local whiteTXT = ColorConvertFloat4ToU32(1,    1,    1,    1)
        local yellowBG = ColorConvertFloat4ToU32(1,    0.2,  0.9,  1)
        local blackTXT = ColorConvertFloat4ToU32(1,    0.5,  0,    0)
        local redBG    = ColorConvertFloat4ToU32(1,    0,    0,    1)

        --reaper.ImGui_SameLine(ctx, nil, 8)
        if soloState ~= 0 then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), yellowBG)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), blackTXT)
        else
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), greyBG)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), whiteTXT)
        end
        if reaper.ImGui_Button(ctx, "S##Solo" .. suffix) then
          reaper.Undo_BeginBlock()
        
          if soloState ~= 0 then
            reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 0)
          else
            reaper.SetMediaTrackInfo_Value(track, "I_SOLO", 1)
          end
          reaper.Undo_EndBlock("RIQS: Toggle Solo", -1)
        end
        reaper.ImGui_PopStyleColor(ctx)
        reaper.ImGui_PopStyleColor(ctx)

        reaper.ImGui_SameLine(ctx, nil, 5)
        if muteState == 1 then
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), redBG)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), whiteTXT)
        else
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(), greyBG)
          reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), whiteTXT)
        end
        if reaper.ImGui_Button(ctx, "M##Mute" .. suffix) then
          reaper.Undo_BeginBlock()
          reaper.SetMediaTrackInfo_Value(track, "B_MUTE", (muteState == 1) and 0 or 1)
          reaper.Undo_EndBlock("RIQS: Toggle Mute", -1)
        end
        reaper.ImGui_PopStyleColor(ctx)
        reaper.ImGui_PopStyleColor(ctx)

        -- Example "Loop" button
        reaper.ImGui_SameLine(ctx, nil, 5)
        if reaper.ImGui_Button(ctx, "Loop##Loop" .. suffix) then
          reaper.Undo_BeginBlock()
          local savedItems = {}
          local currentCount = reaper.CountSelectedMediaItems(0)
          for i2 = 0, currentCount - 1 do
            table.insert(savedItems, reaper.GetSelectedMediaItem(0, i2))
          end
          reaper.Main_OnCommand(40289, 0)
          reaper.SetMediaItemSelected(item, true)
          local itemStart = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
          local itemLength = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
          local itemEnd = itemStart + itemLength
          reaper.GetSet_LoopTimeRange(true, true, itemStart, itemEnd, false)
          reaper.SetEditCurPos(itemStart, true, false)
          --reaper.GetSetRepeatEx(0, 1) DO NOT TURN ON REPEAT MODE... Unless you want to?
          reaper.UpdateArrange()
          reaper.Main_OnCommand(40289, 0)
          for _, si in ipairs(savedItems) do
            reaper.SetMediaItemSelected(si, true)
          end
          reaper.UpdateArrange()
          reaper.Undo_EndBlock("RIQS: Loop " .. info.itemName, -1)
        end

        reaper.ImGui_SameLine(ctx, nil, 5)
        if reaper.ImGui_Button(ctx, "Rename##btnName" .. suffix) then
          reaper.Undo_BeginBlock()
          setTakeName(take, info.itemName)
          reaper.UpdateItemInProject(item)
          reaper.TrackList_AdjustWindows(false)
          reaper.UpdateArrange()
          focusReaperMain()
          reaper.Undo_EndBlock("RIQS: Rename media item", -1)
        end

        reaper.ImGui_SameLine(ctx, nil, 5)
        if reaper.ImGui_Button(ctx, "Source##" .. suffix) then
          -- Step 1: Save the current selection
          local savedSelection = {}
          local numSel = reaper.CountSelectedMediaItems(0)
          for s = 0, numSel - 1 do
            savedSelection[#savedSelection + 1] = reaper.GetSelectedMediaItem(0, s)
          end

          -- Step 2: Check if this item is already selected
          local wasAlreadySelected = reaper.IsMediaItemSelected(item)

          -- Step 3: If not selected, select only this item
          if not wasAlreadySelected then
            reaper.Main_OnCommand(40289, 0) -- Unselect all items
            reaper.SetMediaItemSelected(item, true)
          end

          -- Step 4: Run the "Source" action
          local cmdID = reaper.NamedCommandLookup("_RS6f5bb77e80af16127e9541975bc86efec66b07b8")
          if cmdID ~= 0 then
            reaper.Main_OnCommand(cmdID, 0)
          end

          -- Step 5: Restore original selection if we changed it
          if not wasAlreadySelected then
            reaper.Main_OnCommand(40289, 0) -- Unselect all
            for _, it in ipairs(savedSelection) do
              reaper.SetMediaItemSelected(it, true)
            end
          end

          focusReaperMain()
        end

        reaper.ImGui_SameLine(ctx, nil, 5)
        if reaper.ImGui_Button(ctx, "FX" .. suffix) then
          local selectedItems = {}
          local numSel = reaper.CountSelectedMediaItems(0)
          for si = 0, numSel - 1 do
            selectedItems[#selectedItems + 1] = reaper.GetSelectedMediaItem(0, si)
          end
          reaper.Main_OnCommand(40289, 0)
          reaper.SetMediaItemSelected(item, true)
          reaper.Main_OnCommand(40638, 0)
          reaper.Main_OnCommand(40289, 0)
          for _, it2 in ipairs(selectedItems) do
            reaper.SetMediaItemSelected(it2, true)
          end
          focusReaperMain()
        end

        reaper.ImGui_SameLine(ctx, nil, 5)
        if reaper.ImGui_Button(ctx, "Reverse##rev" .. suffix) then
          reaper.Undo_BeginBlock()
          info.isReversed = not info.isReversed
          local currentlySelected = reaper.CountSelectedMediaItems(0)
          local savedItems = {}
          for j = 0, currentlySelected-1 do
            savedItems[j] = reaper.GetSelectedMediaItem(0, j)
          end
          reaper.Main_OnCommand(40289, 0)
          reaper.SetMediaItemSelected(item, true)
          reaper.Main_OnCommand(41051, 0)
          reaper.Main_OnCommand(40289, 0)
          for j = 0, #savedItems do
            if savedItems[j] then
              reaper.SetMediaItemSelected(savedItems[j], true)
            end
          end
          reaper.UpdateArrange()
          reaper.Undo_EndBlock("RIQS: Reverse " .. info.itemName, -1)
        end

        -- HOLD checkbox
        reaper.ImGui_SameLine(ctx, nil, 5)
        local holdState = info.hold
        local changedHold, newHold = reaper.ImGui_Checkbox(ctx, "Hold##hold" .. suffix, holdState)
        if changedHold then
          info.hold = newHold
          local key = tostring(item)
          if newHold then
            -- BECOMING HELD
            heldItems[key] = info

            -- Insert into heldItemsOrder if not already
            local exists = false
            for _, k in ipairs(heldItemsOrder) do
              if k == key then
                exists = true
                break
              end
            end
            if not exists then
              table.insert(heldItemsOrder, key)
            end

            -- NEW: record holdRank only if not set
            if not holdRank[key] then
              -- find the current display index of this item
              for idx, dispInfo in ipairs(displayedItems) do
                if dispInfo.item == item then
                  holdRank[key] = idx
                  break
                end
              end
            end

            newlyUnheldItems[key] = nil
          else
            -- BECOMING UNHELD
            heldItems[key] = nil
            for idx, k in ipairs(heldItemsOrder) do
              if k == key then
                table.remove(heldItemsOrder, idx)
                break
              end
            end
            newlyUnheldItems[key] = true
          
          end
          -- forceRefresh = true or not, depending on your preference
        end

        -- Row 2: Volume
        if showVolume then
          reaper.ImGui_Text(ctx, "Volume    ")
          reaper.ImGui_SameLine(ctx, nil, 8)
          reaper.ImGui_PushItemWidth(ctx, 260)
          local changedVol, newVol = reaper.ImGui_SliderDouble(ctx, "##Volume" .. suffix, info.volume, MIN_VOLUME, MAX_VOLUME, "%.2f")
          reaper.ImGui_PopItemWidth(ctx)
          reaper.ImGui_SameLine(ctx, nil, 6)
          if reaper.ImGui_Button(ctx, "Reset##Vol" .. suffix) then
            reaper.Undo_BeginBlock()
            newVol = 1.0
            changedVol = true
            reaper.Undo_EndBlock("RIQS: Reset Volume: " .. info.itemName, -1)
          end
          if changedVol then
            info.volume = newVol
            reaper.SetMediaItemTakeInfo_Value(take, "D_VOL", info.volume)
            reaper.UpdateItemInProject(item)
            reaper.UpdateArrange()
          end
        end

        -- Row 3: Pan
        if showPan then
          reaper.ImGui_Text(ctx, "Pan       ")
          reaper.ImGui_SameLine(ctx, nil, 8)
          reaper.ImGui_PushItemWidth(ctx, 260)
          local changedPan, newPan = reaper.ImGui_SliderDouble(ctx, "##Pan" .. suffix, info.pan, MIN_PAN, MAX_PAN, "%.2f")
          reaper.ImGui_PopItemWidth(ctx)
          reaper.ImGui_SameLine(ctx, nil, 6)
          if reaper.ImGui_Button(ctx, "Reset##Pan" .. suffix) then
            reaper.Undo_BeginBlock()
            newPan = 0.0
            changedPan = true
            reaper.Undo_EndBlock("RIQS: Reset Pan: " .. info.itemName, -1)
          end
          if changedPan then
            info.pan = newPan
            reaper.SetMediaItemTakeInfo_Value(take, "D_PAN", info.pan)
            reaper.UpdateItemInProject(item)
            reaper.UpdateArrange()
          end
        end

        -- Row 4: Pitch
        if showPitch then
          reaper.ImGui_Text(ctx, "Pitch     ")
          reaper.ImGui_SameLine(ctx, nil, 8)
          reaper.ImGui_PushItemWidth(ctx, 260)
          local changedPitch, newPitch = reaper.ImGui_DragDouble(ctx, "##Pitch" .. suffix, info.pitch, PITCH_SPEED, MIN_PITCH, MAX_PITCH, "%.2f semitones")
          reaper.ImGui_PopItemWidth(ctx)
          reaper.ImGui_SameLine(ctx, nil, 6)
          if reaper.ImGui_Button(ctx, "Reset##Pitch" .. suffix) then
            reaper.Undo_BeginBlock()
            newPitch = 0
            changedPitch = true
            reaper.Undo_EndBlock("RIQS: Reset Pitch: " .. info.itemName, -1)
          end
          if changedPitch then
            info.pitch = newPitch
            reaper.SetMediaItemTakeInfo_Value(take, "D_PITCH", info.pitch)
            reaper.UpdateItemInProject(item)
            reaper.UpdateArrange()
          end
        end

        -- Row 5: Rate
        if showRate then
          reaper.ImGui_Text(ctx, "Play Rate ")
          reaper.ImGui_SameLine(ctx, nil, 8)
          reaper.ImGui_PushItemWidth(ctx, 260)
          local changedRate, newRate = reaper.ImGui_DragDouble(ctx, "##Rate" .. suffix, info.rate, 0.01, MIN_RATE, MAX_RATE, "%.2fx")
          reaper.ImGui_PopItemWidth(ctx)
          reaper.ImGui_SameLine(ctx, nil, 5)
          if reaper.ImGui_Button(ctx, "Reset##Rate" .. suffix) then
            reaper.Undo_BeginBlock()
            newRate = 1.0
            changedRate = true
            reaper.Undo_EndBlock("RIQS: Reset Play Rate: " .. info.itemName, -1)
          end
          if changedRate then
            info.rate = newRate
            reaper.SetMediaItemTakeInfo_Value(take, "D_PLAYRATE", info.rate)
            reaper.UpdateItemInProject(item)
            reaper.UpdateArrange()
          end
        end

        -- Row 6: Pitch Mode + Preserve
        if showMode then
          reaper.ImGui_Text(ctx, "Pitch Mode")
          reaper.ImGui_SameLine(ctx, nil, 8)
          reaper.ImGui_PushItemWidth(ctx, 260)
          local currentIndex = findPitchModeIndex(info.pitchMode)
          local pitchModesStr = ""
          for _, pm in ipairs(pitchModes) do
            pitchModesStr = pitchModesStr .. pm.label .. "\0"
          end
          local comboChanged, newIndex = reaper.ImGui_Combo(ctx, "##PitchMode" .. suffix, currentIndex, pitchModesStr)
          if comboChanged then
            reaper.Undo_BeginBlock()
            info.pitchMode = getPitchModeValueFromIndex(newIndex)
            reaper.SetMediaItemTakeInfo_Value(take, "I_PITCHMODE", info.pitchMode)
            reaper.UpdateItemInProject(item)
            reaper.UpdateArrange()
            reaper.Undo_EndBlock("RIQS: Modify Pitch Mode: " .. info.itemName, -1)
          end
          reaper.ImGui_PopItemWidth(ctx)

          reaper.ImGui_SameLine(ctx, nil, 5)
          local preserveVal = (info.preserve == 1)
          local changedPres, newPres = reaper.ImGui_Checkbox(ctx, "Pres." .. suffix, preserveVal)
          if changedPres then
            reaper.Undo_BeginBlock()
            info.preserve = newPres and 1 or 0
            reaper.SetMediaItemTakeInfo_Value(take, "B_PPITCH", info.preserve)
            reaper.UpdateItemInProject(item)
            reaper.TrackList_AdjustWindows(false)
            reaper.UpdateArrange()
            focusReaperMain()
            reaper.Undo_EndBlock("RIQS: Toggle Preserve Pitch: " .. info.itemName, -1)
            forceRefresh = true  -- Force refresh so that the GUI is updated from the project state
          end
        end

        -- Row 7: EQ
        if showEQ then
          reaper.ImGui_Text(ctx, "EQ Freq   ")
          reaper.ImGui_SameLine(ctx, nil, 8)
          reaper.ImGui_PushItemWidth(ctx, 260)

          -- eq_displayFreq() won't crash
          local displayVal = eq_displayFreq(info.eqFreq)
          local changedEQ, newFreq = reaper.ImGui_SliderDouble(
            ctx,
            "##EQFreq" .. suffix,
            info.eqFreq,
            20,
            24000,
            string.format("%.0f Hz", displayVal),
            reaper.ImGui_SliderFlags_Logarithmic()
          )

          reaper.ImGui_PopItemWidth(ctx)
          if changedEQ then
            info.eqFreq = newFreq
            if info.eqFxIndex >= 0 then
              local pval = eq_freqToParam(newFreq)
              reaper.TakeFX_SetParam(take, info.eqFxIndex, 0, pval)
            end
          end

          reaper.ImGui_SameLine(ctx, nil, 5)
          if reaper.ImGui_Button(ctx, "Mode: " .. info.eqMode .. "##EQMode" .. suffix) then
          
          -- Always actively search for the correct FX index before doing anything
          local fxCount = reaper.TakeFX_GetCount(take)
          local foundEQ = false
          for i = 0, fxCount - 1 do
            local retval, fxName = reaper.TakeFX_GetFXName(take, i, "")
            if retval and fxName and fxName:find("RS_EQ") then
              info.eqFxIndex = i
              foundEQ = true
              break
            end
          end
          
          -- If not found and not OFF, create new instance
          if not foundEQ and info.eqMode == "OFF" then
            local newIdx = eq_createNew(take)
            if newIdx >= 0 then
              info.eqFxIndex = newIdx
              info.eqMode = "HPF"
              reaper.TakeFX_SetPreset(take, newIdx, EQ_PRESET_HPF)
              local pval = eq_freqToParam(info.eqFreq)
              reaper.TakeFX_SetParam(take, newIdx, 0, pval)
            end
          elseif foundEQ then
            -- Cycle through modes reliably using found index
            if info.eqMode == "HPF" then
              info.eqMode = "LPF"
              reaper.TakeFX_SetPreset(take, info.eqFxIndex, EQ_PRESET_LPF)
            elseif info.eqMode == "LPF" then
              info.eqMode = "BPF"
              reaper.TakeFX_SetPreset(take, info.eqFxIndex, EQ_PRESET_BPF)
            elseif info.eqMode == "BPF" then
              info.eqMode = "OFF"
              -- Delete safely in reverse loop, though usually single match
              for i = fxCount - 1, 0, -1 do
                local retval, fxName = reaper.TakeFX_GetFXName(take, i, "")
                if retval and fxName and fxName:find("RS_EQ") then
                  reaper.TakeFX_Delete(take, i)
                end
              end
              info.eqFxIndex = -1
            elseif info.eqMode == "OFF" then
              -- User manually re-enabled the EQ while we found an old RS_EQ: reset to HPF mode
              info.eqMode = "HPF"
              reaper.TakeFX_SetPreset(take, info.eqFxIndex, EQ_PRESET_HPF)
              local pval = eq_freqToParam(info.eqFreq)
              reaper.TakeFX_SetParam(take, info.eqFxIndex, 0, pval)
            end
          end
        end

        end

        reaper.ImGui_Separator(ctx)
        reaper.ImGui_Separator(ctx)
      end
    end
    
    -- Cleanup IMGUI
    -- Pop only if font pushed
    if font_pushed then
      reaper.ImGui_PopFont(ctx)
    end
    reaper.ImGui_End(ctx)
  end

  -- Spacebar => transport
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Space()) and not reaper.ImGui_IsAnyItemActive(ctx) then
    reaper.Main_OnCommand(40044, 0) -- Toggle play/stop
  end
  
  -- R => Cycle Repeat MODE
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_R()) and not reaper.ImGui_IsAnyItemActive(ctx) then
    local repeatState = reaper.GetSetRepeatEx(0, -1)
    if repeatState == 0 then
      reaper.GetSetRepeatEx(0, 1)
    else
      reaper.GetSetRepeatEx(0, 0)
    end
  end
  
  --
    -- CTRL+Z / CTRL+SHIFT+Z: Undo/Redo with selection restoration
  if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Z()) and not reaper.ImGui_IsAnyItemActive(ctx) then
    -- Check modifier keys individually
    local ctrlDown = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftCtrl()) or
                     reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightCtrl())
    local shiftDown = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_LeftShift()) or
                      reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Key_RightShift())

    -- Capture currently selected items
    local savedSelection = {}
    local numSel = reaper.CountSelectedMediaItems(0)
    for i = 0, numSel - 1 do
      savedSelection[#savedSelection + 1] = reaper.GetSelectedMediaItem(0, i)
    end

    -- Perform Undo or Redo based on modifier keys
    if ctrlDown and not shiftDown then
      reaper.Main_OnCommand(40029, 0)  -- Undo
      --forceRefresh = true  -- Force refresh so that the GUI is updated from the project state
    elseif ctrlDown and shiftDown then
      reaper.Main_OnCommand(40030, 0)  -- Redo
    end

    -- Reselect the previously saved items
    reaper.Main_OnCommand(40289, 0) -- Unselect all items
    for _, item in ipairs(savedSelection) do
      if reaper.ValidatePtr2(0, item, "MediaItem*") then
        reaper.SetMediaItemSelected(item, true)
      end
    end

    reaper.UpdateArrange()
    -- Force the GUI to refresh its data (the main loop will pick this up)
    forceRefresh = true
  end
  --
  if not open then
    -- Save settings on script exit
    local function storeBool(key, value)
      reaper.SetExtState("ItemQuickSettings", key, value and "1" or "0", true)
      -- The last parameter "persist" = true means it will be saved across sessions.
    end

    storeBool("showVolume", showVolume)
    storeBool("showPan",    showPan)
    storeBool("showPitch",  showPitch)
    storeBool("showRate",   showRate)
    storeBool("showMode",   showMode)
    storeBool("showEQ",     showEQ)

    if reaper.ImGui_DestroyContext then reaper.ImGui_DestroyContext(ctx) end
    return false
  end
  
  return true
end

-------------------------------------------------
-- DEFER LOOP
-------------------------------------------------
local function mainLoop()
  if not frame() then return end
  reaper.defer(mainLoop)
end

-------------------------------------------------
-- INIT
-------------------------------------------------
mainLoop()