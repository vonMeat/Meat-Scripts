-- @provides
--   [main] Meat-Script_Scroll_MediaItem_Next_Variation.lua
-- @description Scroll Media Item to Next Variation
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Scroll Media Item to Next Variation
--   - Given an media item with several variations separated by silence, uses peak detection to modify start offset such that it 'scrolls' the next variation to the start of the media item.
--   - Change 'ASK_USER' variable to 'true' if you want to be prompted for peak detection thresholds when the script runs. 
--   - Recommended shortcut : CTRL+ALT+C 

------------------  USER FLAGS  ------------------
local DEBUG     = false
local ASK_USER  = false -- user prompt window 
--------------------------------------------------

local DEF_WINDOW_SEC      = 0.40
local DEF_WINDOW_OVERLAP  = 1
local DEF_SILENCE_DB      = -60

--------------------------------------------------
-- helpers
--------------------------------------------------
local function log(msg) if DEBUG then reaper.ShowConsoleMsg(tostring(msg).."\n") end end

local function WDL_VAL2DB(x)
  if not x or x < 2.9802322387695e-8 then return -150.0 end
  return math.max(-150, math.log(x) * 8.685889638065036)
end

local function getProjectSR()
  return tonumber(reaper.format_timestr_pos(1 - reaper.GetProjectTimeOffset(0,false),"",4))
end

local function prompt()
  if not ASK_USER then
    return DEF_WINDOW_SEC, DEF_WINDOW_OVERLAP, DEF_SILENCE_DB
  end
  local ok,v = reaper.GetUserInputs(
      "Peak-Offset Options",3,
      "RMS window (s),Window overlap,Silence threshold (dB)",
      string.format("%.3f,%d,%d",DEF_WINDOW_SEC,DEF_WINDOW_OVERLAP,DEF_SILENCE_DB))
  if not ok then return end
  local w,o,t = v:match("([^,]+),([^,]+),([^,]+)")
  return math.max(0.005,tonumber(w) or DEF_WINDOW_SEC),
         math.max(1,tonumber(o) or DEF_WINDOW_OVERLAP),
         tonumber(t) or DEF_SILENCE_DB
end

--------------------------------------------------
-- analysis helpers  (unchanged)
--------------------------------------------------
local function getRMSdB(item,winSec,ov)
  local take = reaper.GetActiveTake(item)
  if not take or reaper.TakeIsMIDI(take) then return end

  local track   = reaper.GetMediaItemTrack(item)
  local acc     = reaper.CreateTrackAudioAccessor(track)
  local SR      = getProjectSR()
  local bufSize = math.ceil(winSec * SR)
  local buf     = reaper.new_array(bufSize)

  local startPos = reaper.GetMediaItemInfo_Value(item,"D_POSITION")
  local endPos   = startPos + reaper.GetMediaItemInfo_Value(item,"D_LENGTH")
  local step     = winSec / ov

  local out, idx = {}, 1
  for p = startPos, endPos, step do
    reaper.GetAudioAccessorSamples(acc,SR,1,p,bufSize,buf)
    local sum = 0; for i = 1,bufSize do sum = sum + math.abs(buf[i]) end
    out[idx]  = WDL_VAL2DB(sum / bufSize); idx = idx + 1
  end
  buf.clear(); reaper.DestroyAudioAccessor(acc)
  return out, step
end

local function firstBurstStart(item,rms,step,thr,startIdx)
  startIdx = startIdx or 1
  local base = reaper.GetMediaItemInfo_Value(item,"D_POSITION")
  for i = startIdx, #rms do
    if rms[i] > thr and (i==1 or rms[i-1] <= thr) then
      return base + (i-1)*step, i
    end
  end
end

--------------------------------------------------
--  MAIN
--------------------------------------------------
local function main()
  local win,ov,thr = prompt()
  if not win then return end

  local sel = reaper.CountSelectedMediaItems(0)
  if sel==0 then return reaper.ShowMessageBox("Select at least one item.","",0) end

  reaper.Undo_BeginBlock()
  reaper.PreventUIRefresh(1)

  for i = 0, sel-1 do
    local item = reaper.GetSelectedMediaItem(0,i)
    local take = reaper.GetActiveTake(item)
    if not take or reaper.TakeIsMIDI(take) then goto next_item end

    local origLen   = nil
    local expanded  = false

    ------------------------------------------------------------------
    -- helper: move offset to next peak, return status
    ------------------------------------------------------------------
    local function shiftToNextPeak()
      local rms,step = getRMSdB(item,win,ov)
      if not rms then return "no-rms" end

      local peakT,idx = firstBurstStart(item,rms,step,thr)
      if not peakT then return "no-peak" end

      local itemStart = reaper.GetMediaItemInfo_Value(item,"D_POSITION")
      local delta     = peakT - itemStart

      if delta <= 1e-9 then
        peakT,idx = firstBurstStart(item,rms,step,thr,(idx or 1)+1)
        if not peakT then return "last-peak" end
        delta = peakT - itemStart
      end

      local curOff = reaper.GetMediaItemTakeInfo_Value(take,"D_STARTOFFS")
      reaper.SetMediaItemTakeInfo_Value(take,"D_STARTOFFS",curOff+delta)
      reaper.UpdateItemInProject(item)
      log(string.format("Item %d  ✓ offset +%.3f  (peak %.3f)",i+1,delta,peakT))
      return "done"
    end

    ------------------------------------------------------------------
    -- first pass
    ------------------------------------------------------------------
    local status = shiftToNextPeak()
    log(string.format("Item %d  -- first pass: %s",i+1,status))

    ------------------------------------------------------------------
    -- if “last-peak”, expand to full source length and retry once
    ------------------------------------------------------------------
    if status == "last-peak" then
      local src       = reaper.GetMediaItemTake_Source(take)
      local srcLen    = (src and select(1,reaper.GetMediaSourceLength(src))) or 0
      local playrate  = reaper.GetMediaItemTakeInfo_Value(take,"D_PLAYRATE")
      if playrate <= 0 then playrate = 1 end

      local needLen   = srcLen / playrate
      local curLen    = reaper.GetMediaItemInfo_Value(item,"D_LENGTH")

      log(string.format(
        "Item %d  | curLen %.3f  need %.3f  (src %.3f  rate %.3f)",
        i+1,curLen,needLen,srcLen,playrate))

      if needLen > curLen + 1e-6 then
        origLen  = curLen
        expanded = true
        reaper.SetMediaItemInfo_Value(item,"D_LENGTH",needLen)
        reaper.UpdateItemInProject(item)
        log(string.format("Item %d  → expanded to %.3f",i+1,needLen))
      else
        log(string.format("Item %d  (already long enough, no expand)",i+1))
      end

      -- retry (even if we didn’t expand, harmless)
      status = shiftToNextPeak()
      log(string.format("Item %d  -- second pass: %s",i+1,status))
    end

    ------------------------------------------------------------------
    -- restore length if we changed it
    ------------------------------------------------------------------
    if expanded and origLen then
      reaper.SetMediaItemInfo_Value(item,"D_LENGTH",origLen)
      reaper.UpdateItemInProject(item)
      log(string.format("Item %d  ← restored to %.3f",i+1,origLen))
    end

    ::next_item::
  end

  reaper.PreventUIRefresh(-1)
  reaper.Undo_EndBlock("Set Start Offset to Next Volume Peak",0)
  reaper.UpdateArrange()
end

main()
