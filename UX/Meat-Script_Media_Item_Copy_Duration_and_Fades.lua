-- @provides
--   [main] Meat-Script_Media_Item_Copy_Duration_and_Fades.lua
-- @description Media Item Copy Duration and Fades
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Media Item Copy Duration and Fades
--   - Requires companion script 'Meat-Script_Media_Item_Paste_Duration_and_Fades.lua'.
--   - Copies both duration and fades of a singular media item, which can later be pasted on other media items using the companion script.
--   - Recommended shortcut: SHIFT+ALT+C

local r = reaper
local SEC, KEY = "RS_ITEM_FRAME", "DATA"

local function esc_str(s) return string.format("%q", s or "") end
local function serialize(v)
  local t = type(v)
  if t == "number" then return tostring(v)
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "string" then return esc_str(v)
  elseif t == "table" then
    local parts = {}
    for k,val in pairs(v) do
      if type(k)=="number" then parts[#parts+1]=serialize(val)
      else parts[#parts+1]=string.format("[%s]=%s", esc_str(k), serialize(val)) end
    end
    return "{"..table.concat(parts,",").."}"
  end
  return "nil"
end

local function put(tbl) r.SetExtState(SEC, KEY, "return "..serialize(tbl), true) end

local function one_selected_item()
  if r.CountSelectedMediaItems(0) ~= 1 then return nil end
  return r.GetSelectedMediaItem(0,0)
end

local function read_fades(it)
  return {
    in_len   = r.GetMediaItemInfo_Value(it, "D_FADEINLEN"),
    out_len  = r.GetMediaItemInfo_Value(it, "D_FADEOUTLEN"),
    in_auto  = r.GetMediaItemInfo_Value(it, "D_FADEINLEN_AUTO"),
    out_auto = r.GetMediaItemInfo_Value(it, "D_FADEOUTLEN_AUTO"),
    in_shape = r.GetMediaItemInfo_Value(it, "C_FADEINSHAPE"),
    out_shape= r.GetMediaItemInfo_Value(it, "C_FADEOUTSHAPE"),
    in_dir   = r.GetMediaItemInfo_Value(it, "D_FADEINDIR"),
    out_dir  = r.GetMediaItemInfo_Value(it, "D_FADEOUTDIR"),
  }
end

local function main()
  r.ClearConsole()
  local it = one_selected_item()
  if not it then r.ShowMessageBox("Select exactly one item to copy.", "Copy Item Frame", 0) return end

  local len = r.GetMediaItemInfo_Value(it, "D_LENGTH")
  local fades = read_fades(it)
  put({ src_len = len, fades = fades })

end

main()
