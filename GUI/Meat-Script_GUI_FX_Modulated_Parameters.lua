-- @provides
--   [main] Meat-Script_GUI_FX_Modulated_Parameters.lua
-- @description FX Modulated Parameters GUI
-- @version 1.1
-- @author Jeremy Romberg
-- @about
--   ### FX Modulated Parameters GUI
--   This GUI displays all modulated parameters for the focused FX
--   - Last touched parameter is displayed for whatever parameter on whichever FX was last interacted with
--   - When no FX has focus, script will display modulated parameters for the FX which was last interacted with.
--   - 'Open' displays the FX that was last interacted with.
--   - Bottom window displays ALL plugins that have modulation applied within the active Reaper project
-- @extrequires ReaImGui
-- @changelog
--   - Add support for FX modulation on media items. 

local function stripLeadingIndex(name)
  return (name:gsub("^%d+:%s*", ""))          -- parentheses force 1 return
end

local ctx = reaper.ImGui_CreateContext("Modulated Parameters")
local init = false  -- Only set the initial window size once
local listAllOpen = false
local listAllInitialized = false

-- Persistent geometry variables for the main window
local lastMainX, lastMainY, lastMainW, lastMainH = 0, 0, 400, 200

-- Helpers for addressing either Track-FX or Take-FX
local function csurfTrack(id)
  return (id < 0) and reaper.GetMasterTrack(0)
                  or  reaper.GetTrack(0, id)   -- 0 = first track
end

local function normalizeFxIndex(idx)
  if idx >= 0x2000000 then return idx - 0x2000000 end  -- monitor FX flag
  if idx >= 0x1000000 then return idx - 0x1000000 end  -- input-FX flag
  return idx
end

-- returns the take handle given the indexes from GetTouchedOrFocusedFX /
-- GetFocusedFX; nil if the indexes do not point to a take-FX.
local function takeHandle(trackIdx, itemIdx, takeIdx)
  if itemIdx < 0 then return nil end                       -- it’s a Track-FX call
  local tr   = csurfTrack(trackIdx)
  if not tr then return nil end
  local item = reaper.GetTrackMediaItem(tr, itemIdx)
  if not item then return nil end
  return reaper.GetMediaItemTake(item, takeIdx)
end


function main()
  if not init then
    reaper.ImGui_SetNextWindowSize(ctx, 400, 200)
    init = true
  end
  
  local visible, open = reaper.ImGui_Begin(ctx, "FX Modulated Parameters", true, 32)
  
  if visible then
    -- Last touched parameter block
    local touched, trIdx, itIdx, tkIdx, fxIdx, parmIdx = reaper.GetTouchedOrFocusedFX(0)
    local lastTouchedFxIdx = fxIdx
    if touched then
      local tk       = takeHandle(trIdx, itIdx, tkIdx)
      local tr       = csurfTrack(trIdx)
      local srcIsTake = (tk ~= nil)

      -- name helpers -----------------------------------------------------
      local fxName, parmName
      if srcIsTake then
        _, fxName   = reaper.TakeFX_GetFXName(tk, fxIdx, "", 512)
        _, parmName = reaper.TakeFX_GetParamName(tk, fxIdx, parmIdx, "")
      else
        _, fxName   = reaper.TrackFX_GetFXName(tr, fxIdx, "", 512)
        _, parmName = reaper.TrackFX_GetParamName(tr, fxIdx, parmIdx, "")
      end
      fxName = stripLeadingIndex(fxName)

      -- GUI --------------------------------------------------------------
      reaper.ImGui_Text(ctx, fxName)
      reaper.ImGui_SameLine(ctx, 0, 5)

      if reaper.ImGui_Button(ctx, "Open", 40, 0) then
        if srcIsTake then
          reaper.TakeFX_Show(tk, fxIdx, 3)
        else
          reaper.TrackFX_Show(tr, fxIdx, 3)
        end
      end

      reaper.ImGui_Text(ctx, "Last touched: " .. parmName)
      reaper.ImGui_SameLine(ctx, 0, 5)

      if reaper.ImGui_Button(ctx, "Modulate", 80, 0) then
        local setParm = srcIsTake and reaper.TakeFX_SetNamedConfigParm
                                  or  reaper.TrackFX_SetNamedConfigParm
        setParm(srcIsTake and tk or tr, fxIdx,
                "param." .. parmIdx .. ".mod.visible", "1")

        local setOpen = srcIsTake and reaper.TakeFX_Modulation_SetOpen
                                  or  reaper.TrackFX_Modulation_SetOpen
        if setOpen then setOpen(srcIsTake and tk or tr, fxIdx, parmIdx, true) end
      end
    else
      reaper.ImGui_Text(ctx, "No last touched parameter.")
    end
    -- HERE 
    
    reaper.ImGui_Separator(ctx)
    
    -- -------------------------------------------------------------------
    -- MODULATED PARAMETERS for FOCUSED FX  (track or take)
    -- -------------------------------------------------------------------
    local fxTrack, fxTake, focusFxIdx = nil, nil, nil
    local focChain, fTrIdx, fItIdx, fFxIdx = reaper.GetFocusedFX()

    -- Check if there's a focused FX (GetFocusedFX returns 1 for track FX, 2 for take FX)
    if focChain > 0 then  
        focusFxIdx = normalizeFxIndex(fFxIdx)
        
        if focChain == 2 then  -- Take FX
            -- For GetFocusedFX with take FX, we need to decode the indices
            -- fTrIdx is trackidx, fItIdx encodes both item and take index
            local tr = csurfTrack(fTrIdx - 1)  -- GetFocusedFX returns 1-based track number
            if tr then
                -- Decode the item/take from fItIdx
                -- High word = item index, Low word = take index
                local itemIdx = fItIdx >> 16
                local takeIdx = fItIdx & 0xFFFF
                local item = reaper.GetTrackMediaItem(tr, itemIdx)
                if item then
                    fxTake = reaper.GetMediaItemTake(item, takeIdx)
                end
            end
        else  -- Track FX (focChain == 1)
            -- GetFocusedFX returns 1-based track number (0=master, 1=first track, etc.)
            fxTrack = csurfTrack(fTrIdx - 1)  -- Convert to 0-based for csurfTrack
        end
    end

    -- Fallback to last-touched when no focused FX
    if not fxTrack and not fxTake and touched then
        focusFxIdx = normalizeFxIndex(lastTouchedFxIdx)
        fxTake = takeHandle(trIdx, itIdx, tkIdx)
        if not fxTake then 
            fxTrack = csurfTrack(trIdx) 
        end
    end

    if not fxTrack and not fxTake then
        reaper.ImGui_Text(ctx, "No focused FX.")
    else
        local srcIsTake = (fxTake ~= nil)
        local getFXName = srcIsTake and reaper.TakeFX_GetFXName or reaper.TrackFX_GetFXName
        local getParam = srcIsTake and reaper.TakeFX_GetParamName or reaper.TrackFX_GetParamName
        local getNParam = srcIsTake and reaper.TakeFX_GetNumParams or reaper.TrackFX_GetNumParams
        local getCFG = srcIsTake and reaper.TakeFX_GetNamedConfigParm or reaper.TrackFX_GetNamedConfigParm
        local showFX = srcIsTake and reaper.TakeFX_Show or reaper.TrackFX_Show
        local setOpen = srcIsTake and reaper.TakeFX_Modulation_SetOpen or reaper.TrackFX_Modulation_SetOpen
        local setParm = srcIsTake and reaper.TakeFX_SetNamedConfigParm or reaper.TrackFX_SetNamedConfigParm
        local container = srcIsTake and fxTake or fxTrack

        -- Debug output to see what we're working with
        -- reaper.ImGui_Text(ctx, "Debug: srcIsTake=" .. tostring(srcIsTake) .. ", focusFxIdx=" .. tostring(focusFxIdx))
        
        -- Header -----------------------------------------------------------
        local ok, fxName = getFXName(container, focusFxIdx, "", 512)
        if ok and fxName and fxName ~= "" then
            reaper.ImGui_Text(ctx, stripLeadingIndex(fxName))
        else
            reaper.ImGui_Text(ctx, "Unknown FX (could not get name)")
        end

        -- Parameter loop ---------------------------------------------------
        local nParams = getNParam(container, focusFxIdx)
        local modCount = 0
        
        if nParams and nParams > 0 then
            for p = 0, nParams-1 do
                local _, pName = getParam(container, focusFxIdx, p, "")
                local _, lfo = getCFG(container, focusFxIdx, "param." .. p .. ".lfo.active")
                local _, acs = getCFG(container, focusFxIdx, "param." .. p .. ".acs.active")
                local _, plink = getCFG(container, focusFxIdx, "param." .. p .. ".plink.active")

                if (tonumber(lfo) or 0) == 1 or
                   (tonumber(acs) or 0) == 1 or
                   (tonumber(plink) or 0) == 1 then
                    modCount = modCount + 1
                    local tags = {}
                    if tonumber(lfo) == 1 then tags[#tags+1] = "LFO" end
                    if tonumber(acs) == 1 then tags[#tags+1] = "ACS" end
                    if tonumber(plink) == 1 then tags[#tags+1] = "PLINK" end
                    reaper.ImGui_Text(ctx, pName .. ": " .. table.concat(tags, ", "))
                    reaper.ImGui_SameLine(ctx, 0, 10)
                    if reaper.ImGui_Button(ctx, "Settings##"..p, 80, 0) then
                        setParm(container, focusFxIdx, "param." .. p .. ".mod.visible", "1")
                        if setOpen then setOpen(container, focusFxIdx, p, true) end
                    end
                end
            end
        end
        
        if modCount == 0 then 
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
    
    --  WINDOW: All Media-Item FX with parameter modulation
    do
      local offsetY2 = -1
      reaper.ImGui_SetNextWindowPos(ctx, lastMainX,
                                         lastMainY + lastMainH + 200 + offsetY2, 0)
      reaper.ImGui_SetNextWindowSize(ctx, lastMainW, 200, 0)

      local visible3 = reaper.ImGui_Begin(ctx,
                                          "All Media Item FX with parameter modulation",
                                          nil, 2)
      if visible3 then
        local found = false
        local itmCnt = reaper.CountMediaItems(0)

        for itm = 0, itmCnt-1 do
          local item = reaper.GetMediaItem(0, itm)
          local takeCnt = reaper.GetMediaItemNumTakes(item)
          for tk = 0, takeCnt-1 do
            local take = reaper.GetMediaItemTake(item, tk)
            local fxCnt = reaper.TakeFX_GetCount(take)
            for fx = 0, fxCnt-1 do
              local nParams = reaper.TakeFX_GetNumParams(take, fx)
              local mod = false
              for p = 0, nParams-1 do
                local _, lfo   = reaper.TakeFX_GetNamedConfigParm(take, fx, "param."..p..".lfo.active")
                local _, acs   = reaper.TakeFX_GetNamedConfigParm(take, fx, "param."..p..".acs.active")
                local _, plink = reaper.TakeFX_GetNamedConfigParm(take, fx, "param."..p..".plink.active")
                if (tonumber(lfo) or 0)==1 or (tonumber(acs) or 0)==1 or (tonumber(plink) or 0)==1 then
                  mod = true break
                end
              end
              if mod then
                found = true
                local _, fxName = reaper.TakeFX_GetFXName(take, fx, "", 512)
                reaper.ImGui_Text(ctx, fxName)
                reaper.ImGui_SameLine(ctx, 0, 10)
                if reaper.ImGui_Button(ctx,
                                       ("Open##%d_%d_%d"):format(itm,tk,fx), 60, 0) then
                  reaper.TakeFX_Show(take, fx, 3)
                end
              end
            end
          end
        end

        if not found then reaper.ImGui_Text(ctx, "None") end
        reaper.ImGui_End(ctx)
      end
    end
  end
end

-- cleanup
if open then
  reaper.defer(main)
else
  if reaper.ImGui_DestroyContext then
    reaper.ImGui_DestroyContext(ctx)
  end
end
end
main()