-- @provides
--   [main] Meat-Script_Find_Identical_FX_with_Identical_Parameters.lua
-- @description Find Identical FX with Identical Parameters
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Find Identical FX with Identical Parameters
--   Scans the entire project for duplicate FX instances containing identical parameter values.
--   Useful for optimizing mixing structure.

-- =============== USER OPTIONS =================
local SCAN_TRACK_FX = true
local SCAN_TAKE_FX  = true
local DEC_PLACES    = 6     -- rounding used for param comparison
local SHOW_UP_TO    = 25    -- how many locations to list per duplicate group
-- ==============================================

local r = reaper

-- small helpers
local function round_str(x)
  -- normalized params are 0..1; format is stable & fast
  return string.format("%." .. DEC_PLACES .. "f", x or 0)
end

local function strip_leading_index(name)
  return (name or ""):gsub("^%d+:%s*", "")
end

local function norm_fx_name(name)
  -- normalize: drop "1: " style prefix and trim
  local n = strip_leading_index(name or "")
  return n:gsub("^%s+", ""):gsub("%s+$", "")
end

local function track_name(track)
  if track == r.GetMasterTrack(0) then return "[MASTER]" end
  local _, nm = r.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
  if nm == "" or not nm then
    local idx = r.CSurf_TrackToID(track, false) -- 1-based visible order
    nm = string.format("Track %d", idx)
  end
  return nm
end

local function take_name(take)
  if not take then return "(no-take)" end
  local _, nm = r.GetSetMediaItemTakeInfo_String(take, "P_NAME", "", false)
  if nm == "" or not nm then
    local src = r.GetMediaItemTake_Source(take)
    local _, fn = r.GetMediaSourceFileName(src, "")
    nm = fn ~= "" and fn or "(unnamed take)"
  end
  return nm
end

-- signature building: "plugin|numParams|p0,p1,..."
local function build_param_signature(param_reader, num_params)
  local vals = {}
  for i = 0, num_params - 1 do
    vals[#vals+1] = round_str(param_reader(i))
  end
  return table.concat(vals, ",")
end

-- maps:
-- groups[pluginKey][sig] = { instances = { <location strings> } }
local groups = {}

local function add_instance(plugin_name, num_params, signature, location_str)
  local key = plugin_name .. "||" .. tostring(num_params)
  if not groups[key] then groups[key] = {} end
  if not groups[key][signature] then groups[key][signature] = { instances = {} } end
  table.insert(groups[key][signature].instances, location_str)
end

-- TRACK FX SCAN
local function scan_track_fx()
  local proj = 0

  -- master first
  do
    local tr = r.GetMasterTrack(proj)
    local cnt = r.TrackFX_GetCount(tr)
    for fx = 0, cnt - 1 do
      local _, fxname = r.TrackFX_GetFXName(tr, fx, "")
      fxname = norm_fx_name(fxname)
      local nparams = r.TrackFX_GetNumParams(tr, fx)

      local function reader(p) return r.TrackFX_GetParam(tr, fx, p) end
      local sig = build_param_signature(reader, nparams)

      local loc = string.format("[Track FX] %s  →  FX #%d", track_name(tr), fx+1)
      add_instance(fxname, nparams, sig, loc)
    end
  end

  -- regular tracks
  local track_count = r.CountTracks(proj)
  for i = 0, track_count - 1 do
    local tr = r.GetTrack(proj, i)
    local cnt = r.TrackFX_GetCount(tr)
    for fx = 0, cnt - 1 do
      local _, fxname = r.TrackFX_GetFXName(tr, fx, "")
      fxname = norm_fx_name(fxname)
      local nparams = r.TrackFX_GetNumParams(tr, fx)

      local function reader(p) return r.TrackFX_GetParam(tr, fx, p) end
      local sig = build_param_signature(reader, nparams)

      local loc = string.format("[Track FX] %s  →  FX #%d", track_name(tr), fx+1)
      add_instance(fxname, nparams, sig, loc)
    end
  end
end

-- TAKE FX SCAN
local function scan_take_fx()
  local proj = 0
  local item_count = r.CountMediaItems(proj)
  for i = 0, item_count - 1 do
    local item = r.GetMediaItem(proj, i)
    local pos  = r.GetMediaItemInfo_Value(item, "D_POSITION")
    local tr   = r.GetMediaItem_Track(item)
    local tn   = track_name(tr)

    local take_count = r.GetMediaItemNumTakes(item)
    for t = 0, take_count - 1 do
      local take = r.GetMediaItemTake(item, t)
      if take then
        local fxcnt = r.TakeFX_GetCount(take)
        for fx = 0, fxcnt - 1 do
          local _, fxname = r.TakeFX_GetFXName(take, fx, "")
          fxname = norm_fx_name(fxname)
          local nparams = r.TakeFX_GetNumParams(take, fx)
          local function reader(p) return r.TakeFX_GetParam(take, fx, p) end
          local sig = build_param_signature(reader, nparams)

          local loc = string.format("[Take FX] %s  →  Item@%.3fs  →  Take '%s'  →  FX #%d",
                                    tn, pos, take_name(take), fx+1)
          add_instance(fxname, nparams, sig, loc)
        end
      end
    end
  end
end

local function build_report()
  local lines = {}
  local dup_total = 0

  for pluginKey, sigs in pairs(groups) do
    for sig, bucket in pairs(sigs) do
      local n = #bucket.instances
      if n >= 2 then
        dup_total = dup_total + 1
        -- decode plugin name + param count for header
        local plugin_name, nparams = pluginKey:match("^(.*)||(%d+)$")
        table.insert(lines, string.format("• %s  (params: %s)  — %d identical instances",
                                          plugin_name, nparams, n))

        -- list a few locations
        local limit = math.min(SHOW_UP_TO, n)
        for i = 1, limit do
          table.insert(lines, "    - " .. bucket.instances[i])
        end
        if n > limit then
          table.insert(lines, string.format("    ...and %d more", n - limit))
        end
		
		-- add a blank line after each duplicate group
        table.insert(lines, "")
		
      end
    end
  end

  if dup_total == 0 then
    return "No identical FX with exactly matching parameters were found."
  else
    return table.concat(lines, "\n")
  end
end

-- main
local function main()
  if SCAN_TRACK_FX then scan_track_fx() end
  if SCAN_TAKE_FX  then scan_take_fx()  end

  local msg = build_report()
  r.ShowMessageBox(msg, "Identical Plugins Check", 0)
end

main()
