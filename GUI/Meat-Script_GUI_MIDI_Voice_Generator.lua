-- @provides
--   [main] Meat-Script_GUI_MIDI_Voice_Generator.lua
-- @description MIDI Voice Generator GUI
-- @version 1.0
-- @author Jeremy Romberg
-- @about
--   ### MIDI Voice Generator GUI
--   Generate complex MIDI patterns with up to 8 independent voices. 
--   Useful for creating arpeggios, rhythmic patterns, and evolving sequences.
--
--   ### Setup
--   1. Create a track and set your VST instrument.
--   2. Arm track for recording.
--   3. Set input to: MIDI > Virtual MIDI Keyboard > Channel 1 (or All Channels)
--   4. Configure voices in the GUI
--   5. Hit Record in REAPER to capture MIDI output
-- 
--   ### Modes:
--   • Automatic: Continuous playback (use Play/Stop buttons)
--   • MIDI Trigger: Playback follows your MIDI keyboard input
--     >> Select MIDI device from dropdown first
--
--   ### Features:
--   • Per-voice controls: Note, Velocity, Sustain %, Rate
--   • Real-time transpose (overridden in MIDI Trigger mode)  
--   • BPM sync with project tempo
--   • Randomization with individual toggles
--   • Save and Load presets (also remembers settings per project)
--
--   ### Notes:
--   Track must remain armed during playback.
--   Edit 'VOICE_COUNT' variable below if you want more than 8 voices. Warning: untested. 

--------------------------------------------------------------------
-- USER CONFIG -----------------------------------------------------
--------------------------------------------------------------------
local VOICE_COUNT = 8       -- number of voices; default 8
local MIDI_DEV    = 0       -- MIDI output device index

-- defaults
local DEF_VELOC   = 100
local DEF_SUSTAIN = 50
local DEF_BPM     = 120

-- Rate settings
local MIN_RATE    = 0       -- 0 = sustain (no pulses)
local MAX_RATE    = 32      -- maximum notes per measure (4/4 time)

-- Transpose settings
local MIN_TRANSPOSE = -24
local MAX_TRANSPOSE = 24
local REFERENCE_NOTE = 60   -- C4

-- GUI sizing (edit to taste)
local COL_ENABLE_W = 55     -- fixed Enable column width (px)
local COL_NOTE_W = 120      -- fixed Note column width (px)
local COL_VELOCITY_W = 100  -- fixed Velocity column width (px)
local COL_SUSTAIN_W = 100   -- fixed Sustain column width (px)
-- Rate column will stretch to fill remaining space
local WINDOW_W, WINDOW_H = 640, 500  -- Reduced height since debug moved to console
--------------------------------------------------------------------

local FULL_WIDTH = -1       -- stretch slider across cell (‑1 = ImGui full width)

-- voice state -----------------------------------------------------
local voices = {}
for i = 1, VOICE_COUNT do
  voices[i] = {
    enabled = (i == 1), note=60, notesPerMeasure=4, velocity=DEF_VELOC, sustain=DEF_SUSTAIN,
    noteOn=false, currentNote=nil,               -- ← NEW
    nextTime=0, offTime=0,
    lastNote=60, lastRate=4, lastVelocity=DEF_VELOC, lastSustain=DEF_SUSTAIN,
    wasEnabled=true,
}
end

-- BPM state
local customBPM = DEF_BPM
local syncToProject = true

-- BPM randomization variables (move to top of script, around line 50-60)
local randBPMOn = false     -- checkbox state
local randVoicesOn = false  -- checkbox state  
local randParamsOn = false  -- checkbox state
local bpmRandMin = 60       -- default min
local bpmRandMax = 180      -- default max

-- Transpose and MIDI input state
local transposeValue = 0
local midiInputDevice = -1  -- -1 = All devices
local midiInputMode = 0     -- 0 = Automatic, 1 = MIDI Trigger
local midiInputDevices = {}
local midiTriggered = false
local lastMidiScanTime = 0
local lastInputTime = nil   -- For debouncing MIDI trigger stop

-- MIDI trigger state for note-specific triggering
local midiTriggerNotes = {}  -- Table to track which MIDI notes are currently pressed
local baseNote = 60          -- C4 - the root note for triggering voices

-- Debug state
local debugEnabled = false
local lastDebugTime = 0
local lastConsoleDebugTime = 0
local debugCounter = 0

-- MIDI detection variables
local processedEvents = {}   -- track already processed events
local lastMidiEventTime = 0  -- track when we last saw MIDI activity

--------------------------------------------------------------------
-- PERSISTENCE (per-project) --------------------------------------
--------------------------------------------------------------------
local PROJ_KEY = "MIDI_VOICE_GEN"

-- ←-----  RESTORE  ------►
do
  for i = 1, VOICE_COUNT do
    local ok, data = reaper.GetProjExtState(0, PROJ_KEY, "voice"..i)
    if ok == 1 and data ~= "" then
      local e,n,v,s,r = data:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")
      voices[i].enabled         = (e == "1")
      voices[i].note            = tonumber(n) or voices[i].note
      voices[i].velocity        = tonumber(v) or voices[i].velocity
      voices[i].sustain         = tonumber(s) or voices[i].sustain
      voices[i].notesPerMeasure = tonumber(r) or voices[i].notesPerMeasure
    end
  end
  local ok2, meta = reaper.GetProjExtState(0, PROJ_KEY, "meta")
  if ok2 == 1 and meta ~= "" then
    local bpm,sync,trans = meta:match("([^,]+),([^,]+),([^,]+)")
    customBPM      = tonumber(bpm)  or customBPM
    syncToProject  = (sync == "1")
    transposeValue = tonumber(trans) or transposeValue
  end
end

-- helper for saving later
local function save_state()
  for i, v in ipairs(voices) do
    local line = table.concat({
      v.enabled and "1" or "0",
      v.note, v.velocity, v.sustain, v.notesPerMeasure
    }, ",")
    reaper.SetProjExtState(0, PROJ_KEY, "voice"..i, line)
  end
  local meta = table.concat({
    customBPM, syncToProject and "1" or "0", transposeValue
  }, ",")
  reaper.SetProjExtState(0, PROJ_KEY, "meta", meta)
end

--------------------------------------------------------------------
-- FILE-BASED PRESET SAVE / LOAD  ---------------------------------
--------------------------------------------------------------------
local PRESET_DIR = reaper.GetResourcePath() .. "/MIDI-Voice-Gen Presets/"
reaper.RecursiveCreateDirectory(PRESET_DIR, 0)

local function serialize_current_state()
  local t = {}
  -- meta first
  t[#t+1] = table.concat({customBPM,
                          syncToProject and 1 or 0,
                          transposeValue}, ",")
  -- each voice on its own line
  for i,v in ipairs(voices) do
    t[#t+1] = table.concat({
        v.enabled and 1 or 0,
        v.note, v.velocity, v.sustain, v.notesPerMeasure
    }, ",")
  end
  return table.concat(t, "\n")
end

--------------------------------------------------------------------
-- Make apply_state tolerant to voice-count mismatches
--------------------------------------------------------------------
local function apply_state(lines)
  if #lines < 2 then 
    reaper.ShowConsoleMsg("[PRESET] Error: Not enough lines in preset file\n")
    return false 
  end

  ----------------------------------------------------------------
  -- META (BPM, sync flag, transpose) ----------------------------
  local mbpm, msync, mtrans = lines[1]:match("([^,]+),([^,]+),([^,]+)")
  if not mbpm then
    reaper.ShowConsoleMsg("[PRESET] Error: Invalid meta line format\n")
    return false
  end
  
  local oldBPM = customBPM
  local oldSync = syncToProject
  local oldTrans = transposeValue
  
  customBPM      = tonumber(mbpm)  or customBPM
  syncToProject  = msync == "1"
  transposeValue = tonumber(mtrans) or transposeValue
  
  --reaper.ShowConsoleMsg(string.format("[PRESET] BPM: %.1f -> %.1f, Sync: %s -> %s, Transpose: %d -> %d\n", 
    --oldBPM, customBPM, tostring(oldSync), tostring(syncToProject), oldTrans, transposeValue))

  ----------------------------------------------------------------
  -- VOICES ------------------------------------------------------
  local voiceLines = math.min(VOICE_COUNT, #lines-1)  -- clamp to what we have
  --reaper.ShowConsoleMsg(string.format("[PRESET] Loading %d voice lines\n", voiceLines))
  
  for i = 1, voiceLines do
    local v         = voices[i]
    local L         = lines[i+1]
    local e,n,vel,sus,rate = L:match("([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)")

    if e and n and vel and sus and rate then
      local oldEnabled = v.enabled
      local oldNote = v.note
      local oldVel = v.velocity
      local oldSus = v.sustain
      local oldRate = v.notesPerMeasure
      
      v.enabled         = (e == "1")
      v.note            = tonumber(n) or v.note
      v.velocity        = tonumber(vel) or v.velocity
      v.sustain         = tonumber(sus) or v.sustain
      v.notesPerMeasure = tonumber(rate) or v.notesPerMeasure
      v.nextTime        = 0           -- reset timing so changes take effect immediately
      v.noteOn          = false
      
      --reaper.ShowConsoleMsg(string.format("[PRESET] Voice %d: En:%s->%s, Note:%d->%d, Vel:%d->%d, Sus:%d->%d, Rate:%d->%d\n", 
        --i, tostring(oldEnabled), tostring(v.enabled), oldNote, v.note, oldVel, v.velocity, 
        --oldSus, v.sustain, oldRate, v.notesPerMeasure))
    else
      reaper.ShowConsoleMsg(string.format("[PRESET] Warning: Invalid voice line %d: %s\n", i, L))
    end
  end
  return true
end


local function save_preset(fname)
  local ok, f = pcall(io.open, fname, "w")
  if not ok or not f then
    reaper.ShowMessageBox("Couldn’t write preset:\n"..tostring(fname),
                          "Preset save error", 0);
    return
  end
  f:write(serialize_current_state())
  f:close()
end

local function load_preset(fname)
  local ok, f = pcall(io.open, fname, "r")
  if not ok or not f then
    reaper.ShowMessageBox("Couldn't read preset:\n"..tostring(fname),
                          "Preset load error", 0);
    return false
  end
  local lines = {}
  for ln in f:lines() do 
    lines[#lines+1] = ln 
  end
  f:close()
  
  -- Actually apply the loaded state
  if apply_state(lines) then
    --reaper.ShowConsoleMsg("[PRESET] Loaded "..fname.."\n")
    
    -- Force all voices to reset their timing after loading
    local now = reaper.time_precise()
    for i, v in ipairs(voices) do
      v.nextTime = now
      v.offTime = now
      v.noteOn = false
      v.currentNote = nil
      -- Reset change detection so new settings take effect
      v.lastNote = nil
      v.lastRate = nil  
      v.lastVelocity = nil
      v.lastSustain = nil
      v.wasEnabled = false  -- Force retrigger
    end
    
    return true
  else
    reaper.ShowMessageBox("Invalid preset format:\n"..tostring(fname),
                          "Preset load error", 0);
    return false
  end
end

--------------------------------------------------------------------
-- RUNTIME STATE & HELPERS ----------------------------------------
--------------------------------------------------------------------
local playing = false
local ctx = reaper.ImGui_CreateContext('MIDI Voice Generator')

local function console_msg(msg)
  if debugEnabled then
    reaper.ShowConsoleMsg(msg .. "\n")
  end
end

local function get_current_bpm()
  return syncToProject and reaper.Master_GetTempo() or customBPM
end

local function hold_len(interval, sus)
  return math.max(0.02, interval * (sus/100))
end

local function all_notes_off()
  for _,v in ipairs(voices) do
    if v.noteOn and v.currentNote then
      reaper.StuffMIDIMessage(MIDI_DEV, 0x80, v.currentNote, 0)
    end
    v.noteOn      = false
    v.currentNote = nil
  end
end

-- Updated device scanning to better show the indexing
local function scan_midi_devices()
  midiInputDevices = {"All Devices"}  -- Index 0 in dropdown
  local numInputs = reaper.GetNumMIDIInputs()
  for i = 0, numInputs - 1 do
    local retval, name = reaper.GetMIDIInputName(i, "")
    if retval then
      table.insert(midiInputDevices, string.format("%s (Device %d)", name, i))
    end
  end
  
  -- commenting out the debug output 
  --console_msg(string.format("[MIDI SCAN] Found %d MIDI input devices", numInputs))
  --for i = 1, #midiInputDevices do
    --console_msg(string.format("[MIDI SCAN] Dropdown index %d: %s", i-1, midiInputDevices[i]))
  --end
end

local function get_transposed_note(originalNote)
  local transposed = originalNote + transposeValue
  if transposed < 0 or transposed > 127 then
    return nil  -- Out of range, ignore this voice
  end
  return transposed
end

-- Function to check if a voice should be triggered by MIDI input
local function should_voice_trigger_from_midi(voiceIndex, midiNote)
  if midiInputMode ~= 1 then return false end
  
  -- Calculate the interval from the base note
  local interval = midiNote - baseNote
  
  -- Check if this voice should be triggered based on the interval
  -- Voice 1 triggers on base note (C), Voice 2 on base+interval from voice 1's note, etc.
  local voiceInterval = voices[voiceIndex].note - voices[1].note
  
  return interval == voiceInterval
end



--------------------------------------------------------------------
-- IMPROVED MIDI DETECTION WITH NOTE STATE TRACKING ---------------
--------------------------------------------------------------------

-- IMPROVED MIDI DETECTION WITH BETTER EVENT PROCESSING
-- Replace the check_midi_input() function with this improved version

-- Track individual MIDI note states
local activeNotes = {}  -- table: note -> true/false
local triggerBaseNote = nil  -- The note that's currently triggering playback
local lastProcessedEventId = 0  -- Track the last processed event ID

-- classify messages correctly
local function classify_midi_message(st, d1, d2)
  local status = st & 0xF0
  local chan   = (st & 0x0F) + 1
  
  if (status == 0x90 and d2 > 0) then
    -- Note On (key pressed)
    return "NOTE_ON", chan, d1, d2
  elseif (status == 0x80 or (status == 0x90 and d2 == 0)) then
    -- Note Off (key released)
    return "NOTE_OFF", chan, d1, d2
  elseif status == 0xB0 then
    return "CC", chan, d1, d2
  else
    return "OTHER", chan, d1, d2
  end
end

-- Check if any trigger notes are currently held
local function any_trigger_notes_active()
  local activeCount = 0
  local firstActive = nil
  
  for note, active in pairs(activeNotes) do
    if active then
      activeCount = activeCount + 1
      if not firstActive then
        firstActive = note
      end
    end
  end
  
  if debugEnabled and activeCount > 0 then
    console_msg(string.format("[DEBUG] %d notes still active, first: %d", activeCount, firstActive))
  end
  
  return activeCount > 0, firstActive
end

-- Calculate transpose offset based on the trigger note
local function calculate_transpose_from_trigger(triggerNote)
  if not triggerNote then return 0 end
  -- The offset is the difference between the trigger note and the base note (C4 = 60)
  return triggerNote - baseNote
end

-- FIXED: Much more reliable MIDI input checking
-- FIXED: Process ALL available MIDI events, not just one
--------------------------------------------------------------------
-- NEW unified + fixed check_midi_input() --------------------------
--------------------------------------------------------------------
local function check_midi_input()
  local now             = reaper.time_precise()
  local hasNewMidiEvent = false

  ----------------------------------------------------------------
  -- 1) Harvest *all* unseen MIDI events in correct order
  ----------------------------------------------------------------
  local newestId = reaper.MIDI_GetRecentInputEvent(0)
  if newestId > lastProcessedEventId then
    local pending = {}

    -- Walk back through the recent-event ring buffer (depth 0-127 is safe)
    for i = 0, 127 do
      local id, buf, ts, devIdx = reaper.MIDI_GetRecentInputEvent(i)
      if id <= 0 or id <= lastProcessedEventId then break end
      pending[#pending + 1] = { id = id,
                                buf = buf,
                                ts  = ts,
                                dev = devIdx & 0xFFFF }
    end

    -- Oldest → newest, tie-break by sequence-id
    table.sort(pending, function(a, b)
      if a.ts == b.ts then return a.id < b.id end
      return a.ts < b.ts
    end)

    ----------------------------------------------------------------
    -- 2) Run NOTE-ON / NOTE-OFF handler on each harvested event
    ----------------------------------------------------------------
    for _, ev in ipairs(pending) do
      local process =   (midiInputDevice == 0)                           -- “All devices”
                     or (midiInputDevice > 0 and                       -- specific device
                         ev.dev == (midiInputDevice - 1))

      if process and ev.buf and #ev.buf >= 3 then
        local s  = ev.buf:byte(1) or 0
        local d1 = ev.buf:byte(2) or 0
        local d2 = ev.buf:byte(3) or 0

        local msgType, chan, note, vel = classify_midi_message(s, d1, d2)

        ------------------------------------------------------------
        -- NOTE_ON -------------------------------------------------
        ------------------------------------------------------------
        if msgType == "NOTE_ON" then
          activeNotes[note]   = true
          hasNewMidiEvent     = true
          lastMidiEventTime   = now

          console_msg(string.format("[MIDI] NOTE_ON %d vel %d", note, vel))

          if not triggerBaseNote then
            -- first key establishes base & starts playback
            triggerBaseNote = note
            transposeValue  = calculate_transpose_from_trigger(note)
            console_msg(string.format(
              "[TRIGGER] Note %d pressed – starting (transpose %+d)",
              note, transposeValue))

            midiTriggered = true
            if not playing then
              playing = true
              local t = reaper.time_precise()
              for _, v in ipairs(voices) do
                v.nextTime, v.offTime, v.noteOn = t, t, false
              end
            end

          elseif triggerBaseNote ~= note then
            -- chord change → switch transpose target
            console_msg(string.format(
              "[TRIGGER] Switching base %d → %d", triggerBaseNote, note))

            triggerBaseNote = note
            transposeValue  = calculate_transpose_from_trigger(note)

            if playing then
              all_notes_off()
              local t = reaper.time_precise()
              for _, v in ipairs(voices) do
                v.nextTime, v.offTime, v.noteOn = t, t, false
              end
            end
          end

        ------------------------------------------------------------
        -- NOTE_OFF -----------------------------------------------
        ------------------------------------------------------------
        elseif msgType == "NOTE_OFF" then
          activeNotes[note] = false
          hasNewMidiEvent   = true
          lastMidiEventTime = now

          console_msg(string.format("[MIDI] NOTE_OFF %d", note))

          if triggerBaseNote == note then
            -- base released ⇒ pick another active note or stop
            local stillHeld, newBase = any_trigger_notes_active()
            if stillHeld and newBase then
              triggerBaseNote = newBase
              transposeValue  = calculate_transpose_from_trigger(newBase)
              console_msg(string.format(
                "[TRIGGER] New base note %d (transpose %+d)",
                newBase, transposeValue))

              if playing then
                all_notes_off()
                local t = reaper.time_precise()
                for _, v in ipairs(voices) do
                  v.nextTime, v.offTime, v.noteOn = t, t, false
                end
              end
            else
              -- nothing left pressed – full stop
              triggerBaseNote = nil
              midiTriggered   = false
              transposeValue  = 0
              console_msg("[TRIGGER] All notes released – stopping")
              if playing then
                playing = false
                all_notes_off()
              end
            end
          end
        end
      end
    end

    -- advance the watermark so we never re-process these events
    lastProcessedEventId = newestId
  end

  ----------------------------------------------------------------
  -- 3) Trigger logic (no eventsProcessed counter)
  ----------------------------------------------------------------
  local anyHeld, firstHeld = any_trigger_notes_active()

  if midiInputMode == 1 then            -- MIDI-trigger mode
    if anyHeld and not midiTriggered then
      midiTriggered = true
      console_msg(string.format(
        "[TRIGGER] Consistency – activating for note %d", firstHeld))
    elseif not anyHeld and midiTriggered then
      midiTriggered = false
      console_msg("[TRIGGER] Consistency – deactivating (no notes held)")
      if playing then
        playing = false
        all_notes_off()
      end
      transposeValue  = 0
      triggerBaseNote = nil
    end

  else                                  -- Automatic mode
    if hasNewMidiEvent and not midiTriggered then
      midiTriggered = true
      console_msg("[TRIGGER] MIDI activity detected – start")
      if not playing then
        playing = true
        local t = reaper.time_precise()
        for _, v in ipairs(voices) do v.nextTime, v.offTime, v.noteOn = t, t, false end
      end
      lastInputTime = nil

    elseif not hasNewMidiEvent and midiTriggered then
      if not lastInputTime then
        lastInputTime = now
      elseif now - lastInputTime > 0.5 then
        midiTriggered = false
        console_msg("[TRIGGER] 0.5 s silence – stop")
        if playing then
          playing = false
          all_notes_off()
        end
        lastInputTime = nil
      end

    elseif hasNewMidiEvent then
      lastInputTime = nil            -- reset debounce timer
    end
  end
end


-- Alternative Method 3: Using REAPER's built-in MIDI monitoring
-- This function can be called to set up MIDI input monitoring
local function setup_midi_monitoring()
  -- Enable MIDI input monitoring for better detection
  local numInputs = reaper.GetNumMIDIInputs()
  console_msg(string.format("[SETUP] Found %d MIDI input devices", numInputs))
  
  for i = 0, numInputs - 1 do
    local retval, name = reaper.GetMIDIInputName(i, "")
    if retval then
      console_msg(string.format("[SETUP] Device %d: %s", i, name))
      -- You could potentially enable specific MIDI devices here if needed
    end
  end
end

-- Call this during initialization
setup_midi_monitoring()

--------------------------------------------------------------------
-- DEBUG / MIDI TRACE HELPERS -------------------------------------
--------------------------------------------------------------------
local function midi_out(status, data1, data2, tag)
  reaper.StuffMIDIMessage(MIDI_DEV, status, data1, data2)
  if DEBUG then
    reaper.ShowConsoleMsg(
      string.format("[%-4s] %02X %3d %3d\n",
                    tag or "", status, data1 or 0, data2 or 0))
  end
end

local function note_on(note, vel)  midi_out(0x90, note, vel, "ON")  end
local function note_off(note)      midi_out(0x80, note,   0, "OFF") end

--------------------------------------------------------------------
-- SEND LOOP -------------------------------------------------------
--------------------------------------------------------------------
local function sendLoop()
  -- Check MIDI input using improved detection
  --check_midi_input()
  
  if midiInputMode == 1 then
    check_midi_input()
  end
  
  -- Only proceed if playing and either in Automatic mode or MIDI triggered
  if not playing then 
    reaper.defer(sendLoop)
    return 
  end
  
  local now               = reaper.time_precise()
  local bpm               = get_current_bpm()
  local beatsPerSecond    = bpm / 60
  local measuresPerSecond = beatsPerSecond / 4  -- 4/4 time

  for i,v in ipairs(voices) do
    ----------------------------------------------------------------
    -- 1.  Skip disabled voices, make sure any ringing note stops --
    ----------------------------------------------------------------
    if not v.enabled then
      if v.noteOn and v.currentNote then
        reaper.StuffMIDIMessage(MIDI_DEV, 0x80, v.currentNote, 0)
      end
      v.noteOn      = false
      v.currentNote = nil
      goto skip
    end

    -- Check if this voice should be triggered in MIDI trigger mode
    local shouldTriggerFromMidi = true  -- In MIDI trigger mode, if we're here, play all enabled voices
    if midiInputMode == 1 and not midiTriggered then
      shouldTriggerFromMidi = false
    end

    -- Skip this voice if it shouldn't be triggered by current MIDI input
    if not shouldTriggerFromMidi then
      if v.noteOn and v.currentNote then
        reaper.StuffMIDIMessage(MIDI_DEV, 0x80, v.currentNote, 0)
      end
      v.noteOn = false
      v.currentNote = nil
      goto skip
    end

    ---------------------------------------------------------------
    -- 2.  Figure out which note we *would* play right now -------
    ---------------------------------------------------------------
    local playNote = get_transposed_note(v.note)
    if not playNote then goto skip end -- out of MIDI range

    ----------------------------------------------------------------
    ----------------------------------------------------------------
    -- 3.  First-enable clean-up & change detection  --------------
    ----------------------------------------------------------------
    local justEnabled = v.enabled and (v.lastRate == nil or not v.wasEnabled)

    if justEnabled then
      ----------------------------------------------------------------
      -- 3a.  Flush any stray note ----------------------------------
      if v.noteOn and v.currentNote then
        note_off(v.currentNote)
      end
      v.noteOn      = false
      v.currentNote = nil

      ----------------------------------------------------------------
      -- 3b.  Establish fresh timing that *cannot* be in the past ---
      if v.notesPerMeasure == 0 then
        -- For sustain mode, set nextTime to now so it triggers immediately
        -- but don't add extra intervals that cause timing issues
        v.nextTime = now
        v.offTime  = now
      else
        -- For pulsed mode, calculate proper interval timing
        local interval = 1 / (v.notesPerMeasure * measuresPerSecond)
        local guard   = 0.02   -- 20 ms safety gap prevents "same-frame" loops
        v.nextTime    = now + guard  -- Just add the guard, not the full interval
        v.offTime     = v.nextTime   -- safe placeholder
      end

      ----------------------------------------------------------------
      -- 3c.  Reset change-detection baselines ----------------------
      v.lastNote      = v.note
      v.lastRate      = v.notesPerMeasure
      v.lastVelocity  = v.velocity
      v.lastSustain   = v.sustain
      v.lastTranspose = transposeValue

      if DEBUG then
        reaper.ShowConsoleMsg(
          string.format("[VOICE %d] Enabled  • nextTime=%.3f\n", i, v.nextTime))
      end
    end

    -- Now test for *real* changes (justEnabled no longer forces a retrigger)
    local settingsChanged = v.note~=v.lastNote
                         or v.notesPerMeasure~=v.lastRate
                         or v.velocity~=v.lastVelocity
                         or v.sustain~=v.lastSustain

    local lastTransposedNote = v.lastNote and (v.lastNote + (v.lastTranspose or 0)) or nil
    local transposeChanged   = (v.lastTranspose or 0) ~= transposeValue

    local sustainRelated     = (v.lastRate == 0 or v.notesPerMeasure == 0)
    local shouldRetrigger    = transposeChanged
                             or (sustainRelated and settingsChanged)

    ---------------------------------------------------------------
    -- 4.  If we must restart the note, turn the old one off -----
    ---------------------------------------------------------------
    if shouldRetrigger then
      if v.noteOn and v.currentNote then
        reaper.StuffMIDIMessage(MIDI_DEV, 0x80, v.currentNote, 0)
        v.noteOn      = false
        v.currentNote = nil
      end
      v.nextTime = now           -- reschedule immediately
    end

    ---------------------------------------------------------------
    -- 5.  Sustain mode  (notesPerMeasure == 0) ------------------
    ---------------------------------------------------------------
    if v.notesPerMeasure == 0 then
      ----------------------------------------------------------------
      -- NOTE-ON  (only if we're not already holding one)
      ----------------------------------------------------------------
      if not v.noteOn then 
        note_on(playNote, v.velocity)
        v.noteOn      = true
        v.currentNote = playNote

        -- work out when to release, based on Sustain %
        if v.sustain < 100 then
          local sustainDur = 4 / measuresPerSecond * (v.sustain / 100)
          v.offTime = now + sustainDur
        else
          v.offTime = math.huge -- never turn off
        end

      ----------------------------------------------------------------
      -- UPDATE velocity or sustain while note is held
      ----------------------------------------------------------------
      elseif v.velocity ~= v.lastVelocity then
        reaper.StuffMIDIMessage(MIDI_DEV, 0x80, v.currentNote, 0)
        note_on(playNote, v.velocity)
        v.currentNote = playNote

        if v.sustain < 100 then
          local sustainDur = 4 / measuresPerSecond * (v.sustain / 100)
          v.offTime = now + sustainDur
        else
          v.offTime = math.huge
        end

      elseif v.sustain ~= v.lastSustain then
        if v.sustain < 100 then
          local sustainDur = 4 / measuresPerSecond * (v.sustain / 100)
          v.offTime = now + sustainDur
        else
          v.offTime = math.huge
        end
      end

      ----------------------------------------------------------------
      -- NOTE-OFF because sustain time elapsed
      ----------------------------------------------------------------
      if v.noteOn and v.sustain < 100 and now >= v.offTime then
        note_off(v.currentNote or playNote)
        v.noteOn      = false
        v.currentNote = nil
        v.nextTime    = now       -- restart the sustain cycle
      end

    ---------------------------------------------------------------
    -- 6.  Pulsed mode (notes per measure > 0) -------------------
    ---------------------------------------------------------------
    else
      local interval = 1 / (v.notesPerMeasure * measuresPerSecond)

      ----------------------------------------------------------------
      -- NOTE-OFF after hold time
      ----------------------------------------------------------------
      if v.noteOn and now >= v.offTime then
        note_off(v.currentNote or playNote)
        v.noteOn      = false
        v.currentNote = nil
      end

      ----------------------------------------------------------------
      -- NOTE-ON when it's time
      ----------------------------------------------------------------
      if now >= v.nextTime then
        note_on(playNote, v.velocity)
        v.noteOn      = true
        v.currentNote = playNote
        v.offTime     = now + hold_len(interval, v.sustain)
        -- Fix: Always schedule next note from NOW, not from old nextTime
        v.nextTime    = now + interval
      end
    end

    ----------------------------------------------------------------
    -- 7.  Store last-frame values for change detection ----------
    ----------------------------------------------------------------
    v.lastNote, v.lastRate, v.lastVelocity, v.lastSustain,
    v.wasEnabled, v.lastTranspose = 
      v.note,    v.notesPerMeasure, v.velocity, v.sustain,
      v.enabled, transposeValue

    ::skip::
  end

  ------------------------------------------------------------------
  -- 8.  Loop -------------------------------------------------------
  ------------------------------------------------------------------
  reaper.defer(sendLoop)
end

-- ---------------------------------------------------------------
-- Randomise every voice’s parameters ----------------------------
-- ---------------------------------------------------------------
local function randomize_voices()
  math.randomseed(reaper.time_precise()*1000)

  -- BPM randomization
  if randBPMOn then
    -- swap if user typed min > max
    if bpmRandMax < bpmRandMin then
      bpmRandMin, bpmRandMax = bpmRandMax, bpmRandMin
    end
    syncToProject = false           -- use custom tempo
    local r = bpmRandMin + math.random() * (bpmRandMax - bpmRandMin)
    local oldBPM = customBPM
    customBPM = math.floor(r + 0.5) -- round to whole BPM
    console_msg(string.format("[RANDOMIZE] BPM changed from %.1f to %.1f (range: %.1f-%.1f)", oldBPM, customBPM, bpmRandMin, bpmRandMax))
  else
    console_msg("[RANDOMIZE] BPM randomization disabled")
  end

  for _, v in ipairs(voices) do
    -------------------------------------------------
    if randVoicesOn then
      v.enabled = (math.random() < 0.5)            -- 50 % chance
    end
    -------------------------------------------------
    if randParamsOn then
      v.note            = math.random(0, 127)       -- Note
      v.velocity        = math.random(1, 127)       -- Velocity
      v.sustain         = math.random(0, 100)       -- Sustain %
      v.notesPerMeasure = math.random(MIN_RATE, MAX_RATE)
    end
  end
  console_msg(string.format("[RANDOMIZE] BPM set to: %.1f, syncToProject: %s", customBPM, syncToProject and "true" or "false"))
end

--------------------------------------------------------------------
-- SIMPLE “SAVE AS” PICKER  (≈15 lines) ----------------------------
--------------------------------------------------------------------
local function pick_save_path()
  --------------------------------------------------------------
  -- 1) If the JS extension is present, use its native dialog --
  --------------------------------------------------------------
  if reaper.JS_Dialog_BrowseForSaveFile then
    local ok, path = reaper.JS_Dialog_BrowseForSaveFile(
                       "Save preset…",     -- title
                       PRESET_DIR,         -- start folder
                       "MyPreset",         -- suggested name
                       "Preset (*.mvg)" )  -- filter
    if ok == 1 and path ~= "" then         -- user clicked “Save”
      return path
    end
    return nil                             -- user cancelled
  end

  --------------------------------------------------------------
  -- 2) No JS extension → simple text prompt ------------------
  --------------------------------------------------------------
  local ok, name = reaper.GetUserInputs(
                     "Save preset", 1,
                     "Preset name (no ext):", "MyPreset")
  if ok and name ~= "" then
    return PRESET_DIR .. name .. ".mvg"
  end
  return nil
end

--------------------------------------------------------------------
-- GUI -------------------------------------------------------------
--------------------------------------------------------------------
local function drawUI()
  -- Periodically scan for MIDI devices (less frequently now)
  local now = reaper.time_precise()
  if now - lastMidiScanTime > 5.0 then -- Scan every 5 seconds instead of 2
    scan_midi_devices()
    lastMidiScanTime = now
  end
  
  reaper.ImGui_SetNextWindowSize(ctx, WINDOW_W, WINDOW_H, reaper.ImGui_Cond_FirstUseEver())
  local visible, open = reaper.ImGui_Begin(ctx,'MIDI Voice Generator',true)
  if visible then
  
    if reaper.ImGui_Button(ctx, "Save Preset") then
      local outPath = pick_save_path()
      if outPath then
        if not outPath:lower():match("%.mvg$") then
          outPath = outPath .. ".mvg"
        end
        save_preset(outPath)
      end
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_Button(ctx, "Load Preset") then
      local ok, fname = reaper.GetUserFileNameForRead(
                          "Choose preset to load",
                          PRESET_DIR, "*.mvg" )
      if ok and fname and fname ~= "" then
        if load_preset(fname) then
          -- Success feedback
          --reaper.ShowConsoleMsg("[GUI] Preset loaded successfully: " .. fname .. "\n")
          -- Optionally show a brief success message
          -- reaper.ShowMessageBox("Preset loaded successfully!", "Load Preset", 0)
        end
      end
    end
  
    local tf = reaper.ImGui_TableFlags_Borders()|reaper.ImGui_TableFlags_RowBg()|reaper.ImGui_TableFlags_SizingStretchProp()
    if reaper.ImGui_BeginTable(ctx,'tbl',5,tf) then
      -- Set up columns - Enable fixed, others stretch proportionally
      reaper.ImGui_TableSetupColumn(ctx,'Enable',reaper.ImGui_TableColumnFlags_WidthFixed(),COL_ENABLE_W)
      reaper.ImGui_TableSetupColumn(ctx,'Note',reaper.ImGui_TableColumnFlags_WidthStretch(),COL_NOTE_W)
      reaper.ImGui_TableSetupColumn(ctx,'Velocity',reaper.ImGui_TableColumnFlags_WidthStretch(),COL_VELOCITY_W)
      reaper.ImGui_TableSetupColumn(ctx,'Sustain %',reaper.ImGui_TableColumnFlags_WidthStretch(),COL_SUSTAIN_W)
      reaper.ImGui_TableSetupColumn(ctx,'Rate (n/bar)',reaper.ImGui_TableColumnFlags_WidthStretch(),COL_NOTE_W)
      reaper.ImGui_TableHeadersRow(ctx)

      for i,v in ipairs(voices) do
        reaper.ImGui_TableNextRow(ctx)

        -- Enable checkbox (approx centred) -------------------------
        reaper.ImGui_TableNextColumn(ctx)
        local cursorX=reaper.ImGui_GetCursorPosX(ctx)
        reaper.ImGui_SetCursorPosX(ctx,cursorX+(COL_ENABLE_W-reaper.ImGui_GetFrameHeight(ctx))/2)
        local ch,en = reaper.ImGui_Checkbox(ctx,'##en'..i,v.enabled); if ch then v.enabled=en end

        -- Note slider ---------------------------------------------
        reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_SetNextItemWidth(ctx,FULL_WIDTH)
        local cn,nn = reaper.ImGui_SliderInt(ctx,'##note'..i,v.note,0,127,'%d'); if cn then v.note=nn end

        -- Velocity slider -----------------------------------------
        reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_SetNextItemWidth(ctx,FULL_WIDTH)
        local cv,nv = reaper.ImGui_SliderInt(ctx,'##vel'..i,v.velocity,1,127,'%d'); if cv then v.velocity=nv end

        -- Sustain slider ------------------------------------------
        reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_SetNextItemWidth(ctx,FULL_WIDTH)
        local cs,ns = reaper.ImGui_SliderInt(ctx,'##sus'..i,v.sustain,0,100,'%d'); if cs then v.sustain=ns end

        -- Rate slider (notes per measure) ---------------------------
        reaper.ImGui_TableNextColumn(ctx); reaper.ImGui_SetNextItemWidth(ctx,FULL_WIDTH)
        local rateLabel = v.notesPerMeasure == 0 and "sustain" or tostring(v.notesPerMeasure)
        local cr,nr = reaper.ImGui_SliderInt(ctx,'##rate'..i,v.notesPerMeasure,MIN_RATE,MAX_RATE,rateLabel); if cr then v.notesPerMeasure=nr end
      end
      reaper.ImGui_EndTable(ctx)
    end

    -- Random-parameter button
    -- Randomise button and options
    if reaper.ImGui_Button(ctx, "Randomize", 90) then
      randomize_voices()
    end
    reaper.ImGui_SameLine(ctx)
    local changedVoices,  newVoices  = reaper.ImGui_Checkbox(ctx, "Voices",     randVoicesOn)
    if changedVoices  then randVoicesOn  = newVoices  end

    reaper.ImGui_SameLine(ctx)

    local changedParams, newParams = reaper.ImGui_Checkbox(ctx, "Parameters", randParamsOn)
    if changedParams then randParamsOn = newParams end
    
    -- BPM checkbox
    reaper.ImGui_SameLine(ctx)
    local cBp, nBp = reaper.ImGui_Checkbox(ctx, "BPM ->", randBPMOn)
    if cBp then randBPMOn = nBp end

    -- ► Min / Max inputs (greyed-out when box is off)
    local flags = randBPMOn and 0 or reaper.ImGui_InputTextFlags_ReadOnly()

    reaper.ImGui_SameLine(ctx, nil, 8)
    reaper.ImGui_Text(ctx, "Min")
    reaper.ImGui_SameLine(ctx)

    reaper.ImGui_PushItemWidth(ctx, 100)
    local chMin, newMin = reaper.ImGui_InputDouble(ctx, "##bpmMin", bpmRandMin, 1, 10, "%.0f", flags)
    if chMin then bpmRandMin = math.max(20, math.min(300, newMin)) end
    reaper.ImGui_PopItemWidth(ctx)

    reaper.ImGui_SameLine(ctx, nil, 4)
    reaper.ImGui_Text(ctx, " Max")
    reaper.ImGui_SameLine(ctx)

    reaper.ImGui_PushItemWidth(ctx, 100)
    local chMax, newMax = reaper.ImGui_InputDouble(ctx, "##bpmMax", bpmRandMax, 1, 10, "%.0f", flags)
    if chMax then bpmRandMax = math.max(20, math.min(300, newMax)) end
    reaper.ImGui_PopItemWidth(ctx)

    reaper.ImGui_Separator(ctx)
    
    -- BPM Controls
    reaper.ImGui_Text(ctx, "BPM:       ")
    reaper.ImGui_SameLine(ctx)
    
    if syncToProject then
      reaper.ImGui_Text(ctx, string.format("%.1f (Project)          ", reaper.Master_GetTempo()))
    else
      reaper.ImGui_SetNextItemWidth(ctx, 172)
      local changed, newBPM = reaper.ImGui_InputDouble(ctx, "##bpm", customBPM, 1, 10, "%.1f")
      if changed then customBPM = math.max(20, math.min(300, newBPM)) end
    end
    
    reaper.ImGui_SameLine(ctx)
    local syncChanged, newSync = reaper.ImGui_Checkbox(ctx, "Sync to Project Tempo", syncToProject)
    if syncChanged then syncToProject = newSync end
    
    --reaper.ImGui_Separator(ctx)
    
    -- Transpose Control
    reaper.ImGui_Text(ctx, "Transpose: ")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local transposeChanged, newTranspose = reaper.ImGui_SliderInt(ctx, "##transpose", transposeValue, MIN_TRANSPOSE, MAX_TRANSPOSE, "%d")
    if transposeChanged then transposeValue = newTranspose end
    
    -- Replace the GUI section that handles MIDI Input Controls and status display:

    -- MIDI Input Controls
    reaper.ImGui_Text(ctx, "MIDI Input:")
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_SetNextItemWidth(ctx, 200)
    local deviceItems = table.concat(midiInputDevices, "\0") .. "\0"
    local deviceChanged, newDevice = reaper.ImGui_Combo(ctx, "##mididevice", midiInputDevice, deviceItems)
    if deviceChanged then 
      midiInputDevice = newDevice 
      console_msg(string.format("[DEVICE CHANGE] Selected device index: %d", midiInputDevice))
    end
    
    reaper.ImGui_SameLine(ctx)
    reaper.ImGui_Text(ctx, "Mode:")
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "Automatic", midiInputMode == 0) then 
      midiInputMode = 0 
      console_msg("[MODE CHANGE] Switched to Automatic mode")
      -- Reset note tracking when switching modes
      activeNotes = {}
      triggerBaseNote = nil
      midiTriggered = false
    end
    reaper.ImGui_SameLine(ctx)
    if reaper.ImGui_RadioButton(ctx, "MIDI Trigger", midiInputMode == 1) then 
      midiInputMode = 1 
      console_msg("[MODE CHANGE] Switched to MIDI Trigger mode")
      -- Reset note tracking when switching modes
      activeNotes = {}
      triggerBaseNote = nil
      midiTriggered = false
    end
    
    reaper.ImGui_Separator(ctx)
    
    -- Play/Stop Controls and Status
    if midiInputMode == 0 then
      -- Automatic mode - manual play/stop buttons
      if not playing then
        if reaper.ImGui_Button(ctx,'Play',80) then 
          playing=true
          console_msg("[MANUAL] Play button pressed")
          local now=reaper.time_precise()
          for _,v in ipairs(voices) do v.nextTime,v.offTime,v.noteOn=now,now,false end
        end
      else
        if reaper.ImGui_Button(ctx,'Stop',80) then 
          playing=false
          console_msg("[MANUAL] Stop button pressed")
          all_notes_off() 
        end
      end
    else
      -- MIDI Trigger mode - show detailed status
      if midiTriggered then
        if triggerBaseNote then
          reaper.ImGui_Text(ctx, string.format("Status: MIDI Triggered (Playing) - Base Note: %d", triggerBaseNote))
          if transposeValue ~= 0 then
            reaper.ImGui_Text(ctx, string.format("Auto-Transpose: %+d semitones", transposeValue))
          end
        else
          reaper.ImGui_Text(ctx, "Status: MIDI Triggered (Playing)")
        end
        
        -- Show which notes are currently pressed
        local pressedNotes = {}
        for note, pressed in pairs(activeNotes) do
          if pressed then
            table.insert(pressedNotes, tostring(note))
          end
        end
        if #pressedNotes > 0 then
          table.sort(pressedNotes, function(a, b) return tonumber(a) < tonumber(b) end)
          reaper.ImGui_Text(ctx, "Active Notes: " .. table.concat(pressedNotes, ", "))
        end
      else
        reaper.ImGui_Text(ctx, "Status: Waiting for MIDI input...")
        reaper.ImGui_Text(ctx, "Press any key to start playback")
        reaper.ImGui_Text(ctx, "The first key pressed sets the transpose offset")
      end
      
      -- Manual override button for stopping
      if midiTriggered then
        reaper.ImGui_SameLine(ctx)
        if reaper.ImGui_Button(ctx, "Force Stop", 80) then
          midiTriggered = false
          playing = false
          all_notes_off()
          activeNotes = {}
          triggerBaseNote = nil
          transposeValue = 0
          console_msg("[MANUAL] Force stop - all notes cleared")
        end
      end
    end
    
    --
    -- Debug controls (simplified)
    reaper.ImGui_Separator(ctx)
    local debugChanged, newDebug = reaper.ImGui_Checkbox(ctx, "Debug to Console", debugEnabled)
    if debugChanged then 
      debugEnabled = newDebug 
      if debugEnabled then
        console_msg("[DEBUG] Console debug enabled")
      else
        console_msg("[DEBUG] Console debug disabled")
      end
    end
    
    if debugEnabled then
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Clear Console") then
        reaper.ClearConsole()
        console_msg("[DEBUG] Console cleared")
      end
      
      reaper.ImGui_SameLine(ctx)
      if reaper.ImGui_Button(ctx, "Test MIDI") then
        console_msg("[TEST] Manual MIDI test started")
        local numInputs = reaper.GetNumMIDIInputs()
        for i = 0, numInputs - 1 do
          local retval, name = reaper.GetMIDIInputName(i, "")
          local safeName = name or "Unknown"
          console_msg(string.format("[TEST] Device %d: %s", i, safeName))
          
          local msg1, msg2, msg3 = reaper.MIDI_GetRecentInputEvent(i)
          local safe_msg1 = tonumber(msg1) or 0
          if safe_msg1 > 0 then
            console_msg(string.format("[TEST] Device %d has recent MIDI: %d, %d, %d", i, safe_msg1, tonumber(msg2) or 0, tonumber(msg3) or 0))
          else
            console_msg(string.format("[TEST] Device %d: No recent MIDI", i))
          end
        end
        console_msg("[TEST] Manual MIDI test completed")
      end
    end
    --
    reaper.ImGui_End(ctx)
  end

  if open then 
    reaper.defer(drawUI) 
  else 
    save_state()
    if playing then playing=false; all_notes_off() end
    if reaper.ImGui_DestroyContext then reaper.ImGui_DestroyContext(ctx) end
  end
end

-- Initialize
console_msg("[INIT] MIDI Voice Generator started")
scan_midi_devices()

-- Start the loops
reaper.defer(sendLoop)
reaper.defer(drawUI)