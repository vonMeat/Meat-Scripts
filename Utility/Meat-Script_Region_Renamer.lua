-- @provides
--   [main] Meat-Script_Region_Renamer.lua
-- @description Region Renamer
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### Region Renamer
--   - Prompts user to define a name for all regions contained within a timeline selection.
--   - Recommended to add to the 'Ruler/arrange context' menu.

--------------------------------------------------------------
-- GLOBALS/SETTINGS
--------------------------------------------------------------
local window_title = "Rename Markers/Regions"
local init_w, init_h = 500, 100   -- initial window size
local margin = 10
local text_height = 20           -- line-height for text
local text_box_height = 26       -- height for text box
local text_box_y                 -- computed at runtime
local finished = false           -- end the loop when true

-- The text state
local user_text = ""
local cursor_pos = 0        -- insertion point (0 = before first char)
local sel_start = 0         -- selection start index
local sel_end = 0           -- selection end index (exclusive)
local selection_anchor = 0  -- used to track the start of a selection drag

-- Keep track of mouse states for selection
local prev_mouse_cap = 0
local mouse_held = false

-- Max length of user text
local MAX_LEN = 80

-- We'll store character offsets here each frame
local offsets = {}

-- Time selection
local time_sel_start, time_sel_end


--------------------------------------------------------------
-- 1) CHECK TIME SELECTION
--------------------------------------------------------------
local function get_time_selection()
  local ts_start, ts_end = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  return ts_start, ts_end
end


--------------------------------------------------------------
-- 2) RENAME REGIONS IN TIME SELECTION
--------------------------------------------------------------
local function rename_regions_in_time_selection(new_name)
  local i = 0
  while true do
    local retval, isrgn, pos, rgn_end, old_name, markrgnindex = reaper.EnumProjectMarkers(i)
    if retval == 0 then break end
    if isrgn and pos >= time_sel_start and rgn_end <= time_sel_end then
      reaper.SetProjectMarkerByIndex(0, i, isrgn, pos, rgn_end, markrgnindex, new_name, 0)
    end
    i = i + 1
  end
  reaper.Undo_OnStateChangeEx("Rename regions", -1, -1)
end


--------------------------------------------------------------
-- HELPER: Clamp a value between min and max
--------------------------------------------------------------
local function clamp(val, min_val, max_val)
  if val < min_val then return min_val end
  if val > max_val then return max_val end
  return val
end


--------------------------------------------------------------
-- HELPER: Measure a string (with current gfx font) WITHOUT drawing
--------------------------------------------------------------
local function measure_substring(str)
  gfx.setfont(1, "Arial", 16)
  local width, _ = gfx.measurestr(str)
  return width
end


--------------------------------------------------------------
-- HELPER: Build an offsets table for user_text:
--   offsets[0] = 0
--   offsets[i] = width of user_text:sub(1, i), for i=1..#user_text
--------------------------------------------------------------
local function compute_text_offsets()
  offsets = {}
  offsets[0] = 0
  for i = 1, #user_text do
    offsets[i] = measure_substring(user_text:sub(1, i))
  end
end


--------------------------------------------------------------
-- HELPER: Convert a mouseX coordinate to a character index
--------------------------------------------------------------
local function get_char_index_from_mouse_x(mouseX, textX)
  local xRelative = mouseX - textX
  if xRelative < 0 then
    return 0
  end
  for i = 1, #user_text do
    if xRelative < offsets[i] then
      return i - 1
    end
  end
  return #user_text
end


--------------------------------------------------------------
-- HELPER: Delete the selected text
--------------------------------------------------------------
local function delete_selection()
  if sel_start < sel_end then
    local left_part = user_text:sub(1, sel_start)
    local right_part = user_text:sub(sel_end+1)
    user_text = left_part .. right_part
    cursor_pos = sel_start
    sel_start, sel_end = 0, 0
  end
end


--------------------------------------------------------------
-- RENDER THE GUI
--------------------------------------------------------------
local function draw_gui()
  gfx.clear = 0x333333   -- background color (BGR)
  local w, h = gfx.w, gfx.h

  -- Instructions (white text on dark background)
  gfx.set(1, 1, 1, 1)
  gfx.x, gfx.y = margin, margin
  gfx.drawstr("Type new region name, then press ENTER.\nPress ESC to cancel.")

  -- Compute text box rect
  text_box_y = margin*2 + text_height*2
  local text_box_x = margin
  local text_box_w = w - margin*2

  -- Draw text box background (white with black border)
  gfx.set(1, 1, 1, 1)
  gfx.rect(text_box_x, text_box_y, text_box_w, text_box_height, true)
  gfx.set(0, 0, 0, 1)
  gfx.rect(text_box_x, text_box_y, text_box_w, text_box_height, false)

  -- Set font for text inside text box
  gfx.setfont(1, "Arial", 16)
  gfx.set(0, 0, 0, 1)  -- black text

  local draw_x = text_box_x + 3
  local draw_y = text_box_y + (text_box_height - text_height) / 2

  -- Draw selection highlight if we have a selection
  if sel_start < sel_end then
    local sel_left = offsets[sel_start] or 0
    local sel_right = offsets[sel_end] or offsets[#user_text] or 0
    local highlight_x = draw_x + sel_left
    local highlight_w = sel_right - sel_left
    gfx.set(0, 0.5, 1, 0.3) -- bluish highlight
    gfx.rect(highlight_x, draw_y, highlight_w, text_height, true)
  end

  -- Draw the text
  gfx.x, gfx.y = draw_x, draw_y
  gfx.drawstr(user_text)

  -- Draw the blinking cursor if no selection
  if sel_start == sel_end then
    local cpos_offset = offsets[cursor_pos] or (offsets[#user_text] or 0)
    local cursor_screen_x = draw_x + cpos_offset
    gfx.line(cursor_screen_x, draw_y, cursor_screen_x, draw_y + text_height)
  end

  gfx.update()
end


--------------------------------------------------------------
-- HANDLE MOUSE (click & drag selection)
--------------------------------------------------------------
local function handle_mouse()
  local mx, my = gfx.mouse_x, gfx.mouse_y
  local mcap = gfx.mouse_cap
  local left_down = (mcap & 1) == 1  -- left mouse button

  local text_box_x = margin
  local text_box_w = gfx.w - margin*2
  local text_box_h = text_box_height

  local inside_box = (mx >= text_box_x and mx <= text_box_x + text_box_w
                   and my >= text_box_y and my <= text_box_y + text_box_h)
  
  if left_down and (prev_mouse_cap & 1) == 0 then
    -- Mouse button just pressed
    if inside_box then
      mouse_held = true
      local cindex = get_char_index_from_mouse_x(mx, text_box_x + 3)
      selection_anchor = cindex
      cursor_pos = cindex
      sel_start = cindex
      sel_end = cindex
    end
  elseif not left_down then
    mouse_held = false
  end
  
  if mouse_held then
    local cindex
    if mx < text_box_x then
      cindex = 0
    elseif mx > text_box_x + text_box_w then
      cindex = #user_text
    else
      cindex = get_char_index_from_mouse_x(mx, text_box_x + 3)
    end
    cursor_pos = cindex
    sel_start = math.min(selection_anchor, cursor_pos)
    sel_end   = math.max(selection_anchor, cursor_pos)
  end

  prev_mouse_cap = mcap
end


--------------------------------------------------------------
-- HANDLE KEYBOARD
--------------------------------------------------------------
local function handle_keyboard()
  local char = gfx.getchar()
  
  if char < 0 then 
    -- Window closed or script interrupted
    finished = true
    return
  end
  
  -- ESC -> cancel
  if char == 27 then
    finished = true
    return
  end

  -- ENTER -> confirm rename
  if char == 13 then
    if user_text ~= "" then
      rename_regions_in_time_selection(user_text)
    end
    finished = true
    return
  end

  -- CTRL+C (copy)
  if char == 3 then
    if sel_start < sel_end then
      local copy_text = user_text:sub(sel_start+1, sel_end)
      reaper.CF_SetClipboard(copy_text)
    end
    return
  end

  -- CTRL+V (paste)
  if char == 22 then
    local paste_text = reaper.CF_GetClipboard() or ""
    if paste_text ~= "" then
      if sel_start < sel_end then
         delete_selection()
      end
      -- Insert the paste text
      local left = user_text:sub(1, cursor_pos)
      local right = user_text:sub(cursor_pos+1)
      user_text = left .. paste_text .. right
      cursor_pos = cursor_pos + #paste_text

      -- Clamp to MAX_LEN
      if #user_text > MAX_LEN then
        user_text = user_text:sub(1, MAX_LEN)
        cursor_pos = math.min(cursor_pos, MAX_LEN)
      end
    end
    return
  end

  -- CTRL+X (cut)
  if char == 24 then
    if sel_start < sel_end then
      local cut_text = user_text:sub(sel_start+1, sel_end)
      reaper.CF_SetClipboard(cut_text)
      delete_selection()
    end
    return
  end

  -- LEFT arrow
  if char == 1818584692 then
    if sel_start < sel_end then
      cursor_pos = sel_start
      sel_start, sel_end = 0, 0
    else
      cursor_pos = clamp(cursor_pos - 1, 0, #user_text)
    end
  end
  
  -- RIGHT arrow
  if char == 1919379572 then
    if sel_start < sel_end then
      cursor_pos = sel_end
      sel_start, sel_end = 0, 0
    else
      cursor_pos = clamp(cursor_pos + 1, 0, #user_text)
    end
  end

  -- BACKSPACE
  if char == 8 then
    if sel_start < sel_end then
      delete_selection()
    else
      if cursor_pos > 0 then
        local left = user_text:sub(1, cursor_pos-1)
        local right = user_text:sub(cursor_pos+1)
        user_text = left .. right
        cursor_pos = cursor_pos - 1
      end
    end
    return
  end

  -- Normal ASCII input [space(32) to tilde(126)]
  if char >= 32 and char <= 126 then
    -- If there's a selection, delete it first
    if sel_start < sel_end then
      delete_selection()
    end

    -- Only add if under max length
    if #user_text < MAX_LEN then
      local c = string.char(char)
      local left = user_text:sub(1, cursor_pos)
      local right = user_text:sub(cursor_pos+1)
      user_text = left .. c .. right
      cursor_pos = cursor_pos + 1
    end
  end
end


--------------------------------------------------------------
-- MAIN LOOP
--------------------------------------------------------------
local function mainloop()
  if finished then
    gfx.quit()
    return
  end
  
  -- 1) Handle user input first
  handle_mouse()
  handle_keyboard()
  
  -- 2) Now compute offsets after text/cursor changes
  compute_text_offsets()

  -- 3) Draw the interface
  draw_gui()
  
  reaper.defer(mainloop)
end


--------------------------------------------------------------
-- INIT
--------------------------------------------------------------
time_sel_start, time_sel_end = get_time_selection()
if time_sel_start == time_sel_end then
  reaper.ShowMessageBox("No time selection. Please select one or more regions in time first.", "Error", 0)
  return
end

-- Get mouse position to spawn window
local mouse_x, mouse_y = reaper.GetMousePosition()
gfx.init(window_title, init_w, init_h, 0, mouse_x, mouse_y)
gfx.setfont(1, "Arial", 16)

-- Start main loop
mainloop()
