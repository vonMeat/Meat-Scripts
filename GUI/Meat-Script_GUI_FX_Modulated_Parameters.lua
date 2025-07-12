-- @provides
--   [main] Meat-Script_GUI_FX_Modulated_Parameters.lua
-- @description FX Modulated Parameters GUI
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### FX Modulated Parameters GUI
--   This GUI displays all modulated parameters for the focused FX
--   - Last touched parameter is displayed for whatever parameter on whichever FX was last interacted with
--   - When no FX has focus, script will display modulated parameters for the FX which was last interacted with.
--   - 'Open' displays the FX that was last interacted with.
--   - Bottom window displays ALL plugins that have modulation applied within the active Reaper project
-- @extrequires ReaImGui

-- Helper function to remove a leading index from a string (e.g., "1: ").
local function stripLeadingIndex(name)
  return string.gsub(name, "^%d+:%s*", "")
end

local ctx = reaper.ImGui_CreateContext("Modulated Parameters")
local init = false  -- Only set the initial window size once
local listAllOpen = false
local listAllInitialized = false

-- Persistent geometry variables for the main window
local lastMainX, lastMainY, lastMainW, lastMainH = 0, 0, 400, 200

function main()
  if not init then
    reaper.ImGui_SetNextWindowSize(ctx, 400, 200)
    init = true
  end
  
  local visible, open = reaper.ImGui_Begin(ctx, "FX Modulated Parameters", true, 32)
  
  if visible then
    -- Last touched parameter block
    local retTouched, tTrackIdx, tItemIdx, tTakeIdx, tFXIdx, tParmIdx = reaper.GetTouchedOrFocusedFX(0)
    if retTouched then
      local lastTrack = nil
      if tTrackIdx == -1 then
        lastTrack = reaper.GetMasterTrack(0)
      else
        lastTrack = reaper.CSurf_TrackFromID(tTrackIdx + 1, false)
      end
      if lastTrack then
        local retFXName, lastFXName = reaper.TrackFX_GetFXName(lastTrack, tFXIdx, "", 512)
        local retParamName, lastParamName = reaper.TrackFX_GetParamName(lastTrack, tFXIdx, tParmIdx, "")
        local displayFXName = stripLeadingIndex(lastFXName)
        reaper.ImGui_Text(ctx, displayFXName)
        reaper.ImGui_SameLine(ctx, 0, 5)
        if reaper.ImGui_Button(ctx, "Open", 40, 0) then
          reaper.TrackFX_Show(lastTrack, tFXIdx, 3)  -- Open the FX window
        end
        reaper.ImGui_Text(ctx, "Last touched: " .. lastParamName)
        reaper.ImGui_SameLine(ctx, 0, 5)
        if reaper.ImGui_Button(ctx, "Modulate", 80, 0) then
          reaper.TrackFX_SetNamedConfigParm(lastTrack, tFXIdx, "param." .. tParmIdx .. ".mod.visible", "1")
          if reaper.TrackFX_Modulation_SetOpen then
            reaper.TrackFX_Modulation_SetOpen(lastTrack, tFXIdx, tParmIdx, true)
          end
        end
      else
        reaper.ImGui_Text(ctx, "Last touched: (Unable to retrieve track)")
      end
    else
      reaper.ImGui_Text(ctx, "No last touched parameter.")
    end
    
    reaper.ImGui_Separator(ctx)
    
    -- Modulated parameters for focused FX block, or fallback to last touched FX if none is focused.
    local modFXTrack, modFXIndex = nil, nil
    local retval, trackNumber, itemNumber, fxIndex = reaper.GetFocusedFX()
    if retval ~= 0 and trackNumber >= 0 and itemNumber < 0 then
      modFXTrack = reaper.CSurf_TrackFromID(trackNumber, false)
      modFXIndex = fxIndex
    elseif retTouched then
      local fallbackTrack = nil
      if tTrackIdx == -1 then
        fallbackTrack = reaper.GetMasterTrack(0)
      else
        fallbackTrack = reaper.CSurf_TrackFromID(tTrackIdx + 1, false)
      end
      if fallbackTrack then
        modFXTrack = fallbackTrack
        modFXIndex = tFXIdx
      end
    end
    
    if modFXTrack == nil then
      reaper.ImGui_Text(ctx, "No focused FX.")
    else
      local retName, fxName = reaper.TrackFX_GetFXName(modFXTrack, modFXIndex, "", 512)
      local displayFXNameFocused = stripLeadingIndex(fxName)
      reaper.ImGui_Text(ctx, displayFXNameFocused)
      
      local numParams = reaper.TrackFX_GetNumParams(modFXTrack, modFXIndex)
      local modulatedCount = 0
      
      for paramIndex = 0, numParams - 1 do
        local retParam, paramName = reaper.TrackFX_GetParamName(modFXTrack, modFXIndex, paramIndex, "")
        
        local retLFO, lfo_active_str = reaper.TrackFX_GetNamedConfigParm(modFXTrack, modFXIndex, "param." .. paramIndex .. ".lfo.active")
        local lfo_active = tonumber(lfo_active_str) or 0
        
        local retACS, acs_active_str = reaper.TrackFX_GetNamedConfigParm(modFXTrack, modFXIndex, "param." .. paramIndex .. ".acs.active")
        local acs_active = tonumber(acs_active_str) or 0
        
        local retPLINK, plink_active_str = reaper.TrackFX_GetNamedConfigParm(modFXTrack, modFXIndex, "param." .. paramIndex .. ".plink.active")
        local plink_active = tonumber(plink_active_str) or 0

        if lfo_active == 1 or acs_active == 1 or plink_active == 1 then
          modulatedCount = modulatedCount + 1
          local modStr = ""
          if lfo_active == 1 then 
            modStr = modStr .. "LFO" 
          end
          if acs_active == 1 then 
            if modStr ~= "" then modStr = modStr .. ", " end
            modStr = modStr .. "ACS"
          end
          if plink_active == 1 then 
            if modStr ~= "" then modStr = modStr .. ", " end
            modStr = modStr .. "PLINK"
          end
          
          reaper.ImGui_Text(ctx, paramName .. ": " .. modStr)
          reaper.ImGui_SameLine(ctx, 0, 10)
          local btnLabel = "Settings##" .. paramIndex
          if reaper.ImGui_Button(ctx, btnLabel, 80, 0) then
            reaper.TrackFX_SetNamedConfigParm(modFXTrack, modFXIndex, "param." .. paramIndex .. ".mod.visible", "1")
            if reaper.TrackFX_Modulation_SetOpen then
              reaper.TrackFX_Modulation_SetOpen(modFXTrack, modFXIndex, paramIndex, true)
            end
          end
        end
      end
      
      if modulatedCount == 0 then
        reaper.ImGui_Text(ctx, "No modulated parameters found.")
      end
    end
    
    -- Save the main window's geometry for later use.
    lastMainX, lastMainY = reaper.ImGui_GetWindowPos(ctx)
    lastMainW, lastMainH = reaper.ImGui_GetWindowSize(ctx)
    
    reaper.ImGui_End(ctx)
  end
  
  -- List ALL window
  do
  local offsetY = -1 -- gap between windows
  reaper.ImGui_SetNextWindowPos(ctx, lastMainX, lastMainY + lastMainH + offsetY, 0)
  reaper.ImGui_SetNextWindowSize(ctx, lastMainW, 200, 0)

  -- Collapse on first run
  if not listAllInitialized then
    reaper.ImGui_SetNextWindowCollapsed(ctx, true, 0)
    listAllInitialized = true
  end

  local windowTitle = "All FX with parameter modulation"
  local visible2, open2 = reaper.ImGui_Begin(ctx, windowTitle, nil, 2)
  if visible2 then
    local foundSomething = false
    for i = 0, reaper.CountTracks(0) - 1 do
      local track = reaper.GetTrack(0, i)
      local fxCount = reaper.TrackFX_GetCount(track)
      for fxIndex = 0, fxCount - 1 do
        local modulated = false
        local numParams = reaper.TrackFX_GetNumParams(track, fxIndex)
        for paramIndex = 0, numParams - 1 do
          local _, lfo_active_str   = reaper.TrackFX_GetNamedConfigParm(track, fxIndex, "param." .. paramIndex .. ".lfo.active")
          local _, acs_active_str   = reaper.TrackFX_GetNamedConfigParm(track, fxIndex, "param." .. paramIndex .. ".acs.active")
          local _, plink_active_str = reaper.TrackFX_GetNamedConfigParm(track, fxIndex, "param." .. paramIndex .. ".plink.active")
          if tonumber(lfo_active_str) == 1 
             or tonumber(acs_active_str) == 1 
             or tonumber(plink_active_str) == 1 then
            modulated = true
            break
          end
        end

        if modulated then
          foundSomething = true
          local _, fxName = reaper.TrackFX_GetFXName(track, fxIndex, "", 512)
          reaper.ImGui_Text(ctx, fxName)
          reaper.ImGui_SameLine(ctx, 0, 10)
          if reaper.ImGui_Button(ctx, "Open##" .. i .. "_" .. fxIndex, 60, 0) then
            reaper.TrackFX_Show(track, fxIndex, 3)
          end
        end
      end
    end

    if not foundSomething then
      reaper.ImGui_Text(ctx, "None")
    end

    reaper.ImGui_End(ctx)
  end
  
  if open then
    reaper.defer(main)
  else
    if reaper.ImGui_DestroyContext then
      reaper.ImGui_DestroyContext(ctx)
    end
  end
end
end
main()
