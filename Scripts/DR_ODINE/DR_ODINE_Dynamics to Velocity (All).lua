-- @description DR_ODINE_Dynamics to Velocity (All Notes)
-- @author DR_ODINE
-- @version 1.0
-- @provides [main] DR_ODINE_Dynamics to Velocity (All).lua
-- @about
--   # Dynamics to Velocity (All Notes)
--   
--   Applies dynamics text events to all MIDI note velocities.
--   Supports crescendo/diminuendo and accent processing.

-- Dynamics to Velocity - Simple Version
-- Applies dynamics text events to MIDI note velocities with crescendo/accent support

----------------------------------------------------------------
-- Logging to toast (no REAPER console)
----------------------------------------------------------------
local PRINT_TO_CONSOLE = false
local LOG = ""
local function log(s)
  s = tostring(s or "")
  LOG = LOG .. s .. "\n"
  if PRINT_TO_CONSOLE then reaper.ShowConsoleMsg(s .. "\n") end
end

----------------------------------------------------------------
-- Tiny toast (auto-closing status panel)
----------------------------------------------------------------
local TOAST_SECONDS   = 3
local TOAST_MAXCHARS  = 4000
local _toast_on, _toast_t0, _toast_msg = false, 0, ""

local function toast_tick()
  if not _toast_on then return end
  local elapsed = reaper.time_precise() - _toast_t0
  gfx.set(0,0,0,1); gfx.rect(0,0,gfx.w,gfx.h,1)
  gfx.set(1,1,1,1); gfx.setfont(1, "Arial", 16)
  gfx.x, gfx.y = 10, 10
  gfx.drawstr(_toast_msg)
  gfx.update()
  if elapsed >= TOAST_SECONDS then
    gfx.quit(); _toast_on = false
  else
    reaper.defer(toast_tick)
  end
end

local function show_toast_from_log()
  local msg = (LOG ~= "" and LOG) or "Done."
  if #msg > TOAST_MAXCHARS then
    msg = "...\n" .. msg:sub(#msg-TOAST_MAXCHARS+1)
  end
  local lines = select(2, msg:gsub("\n", "\n")) + 1
  local w = 740
  local h = math.min(110 + lines * 16, 600)
  local mx, my = reaper.GetMousePosition()
  gfx.init("Dynamics to Velocity - Result", w, h, 0, mx - w/2, my - h - 40)
  _toast_msg = msg
  _toast_t0  = reaper.time_precise()
  _toast_on  = true
  toast_tick()
end

----------------------------------------------------------------
-- Utils
----------------------------------------------------------------
local function norm(s) s = s:lower(); return s:gsub("[^%w]+","") end

-- Dynamics constants
local DYN_TO_VEL = { ppp=15, pp=25, p=40, mp=55, mf=75, f=90, ff=110, fff=125 }

----------------------------------------------------------------
-- Target track detection
----------------------------------------------------------------
local function get_target_track()
  local selItemCount = reaper.CountSelectedMediaItems(0)
  for i=0, selItemCount-1 do
    local it = reaper.GetSelectedMediaItem(0,i)
    local take = it and reaper.GetActiveTake(it)
    if take and reaper.TakeIsMIDI(take) then return reaper.GetMediaItem_Track(it) end
  end
  local selTrCount = reaper.CountSelectedTracks(0)
  if selTrCount>0 then return reaper.GetSelectedTrack(0,0) end
  return nil
end

----------------------------------------------------------------
-- Text collection
----------------------------------------------------------------
local function collect_texts_by_ppq(take)
  local _,_,_, n = reaper.MIDI_CountEvts(take)
  local t = {}
  for i=0,n-1 do
    local _,_,_,ppq,typ,msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if typ and msg and typ~=-1 then
      local s = norm(msg)
      if not t[ppq] then t[ppq] = {} end
      t[ppq][#t[ppq]+1] = s
    end
  end
  return t
end

local function choose_dyn_for_ppq(textsAtPPQ)
  if not textsAtPPQ then return nil end
  for _, m in ipairs(textsAtPPQ) do
    local tok = m:match("dynamic([pmf]+)")
    if tok and DYN_TO_VEL[tok] then return DYN_TO_VEL[tok] end
  end
  return nil
end

local function is_accent(textsAtPPQ)
  if not textsAtPPQ then return false end
  for _, m in ipairs(textsAtPPQ) do
    if m:find("articulationaccent", 1, true) then
      return true
    end
  end
  return false
end

local function is_crescendo_diminuendo(textsAtPPQ)
  if not textsAtPPQ then return false end
  for _, m in ipairs(textsAtPPQ) do
    if m:find("crescendo", 1, true) or m:find("diminuendo", 1, true) then
      return true
    end
  end
  return false
end

local function get_accented_velocity_level(current_level)
  -- Dynamics in order: ppp=15, pp=25, p=40, mp=55, mf=75, f=90, ff=110, fff=125
  local dynamics_order = {
    {name="ppp", value=15},
    {name="pp", value=25},
    {name="p", value=40},
    {name="mp", value=55},
    {name="mf", value=75},
    {name="f", value=90},
    {name="ff", value=110},
    {name="fff", value=125}
  }
  
  -- Find current level index
  local current_idx = nil
  for i, dyn in ipairs(dynamics_order) do
    if dyn.value == current_level then
      current_idx = i
      break
    end
  end
  
  if not current_idx then return current_level end -- Unknown level, no change
  
  -- Try to go up 2 steps
  if current_idx + 2 <= #dynamics_order then
    return dynamics_order[current_idx + 2].value
  -- Try to go up 1 step
  elseif current_idx + 1 <= #dynamics_order then
    return dynamics_order[current_idx + 1].value
  else
    -- Already at maximum, return current level (no boost possible)
    return current_level
  end
end

----------------------------------------------------------------
-- Cross-track dynamic search for crescendo
----------------------------------------------------------------
local function find_next_dynamic_info_on_track(tr, after_time)
  local itemCount = reaper.CountTrackMediaItems(tr)
  local next_dyn = nil
  local next_time = math.huge
  
  for itidx = 0, itemCount-1 do
    local item = reaper.GetTrackMediaItem(tr, itidx)
    local take = item and reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local _, _, _, textCount = reaper.MIDI_CountEvts(take)
      
      for i = 0, textCount-1 do
        local _, _, _, ppq, typ, msg = reaper.MIDI_GetTextSysexEvt(take, i)
        if typ and msg and typ ~= -1 then
          local event_time = item_start + reaper.MIDI_GetProjTimeFromPPQPos(take, ppq) - reaper.MIDI_GetProjTimeFromPPQPos(take, 0)
          
          if event_time > after_time and event_time < next_time then
            local norm_msg = norm(msg)
            local tok = norm_msg:match("dynamic([pmf]+)")
            if tok and DYN_TO_VEL[tok] then
              next_dyn = DYN_TO_VEL[tok]
              next_time = event_time
            end
          end
        end
      end
    end
  end
  
  return next_dyn
end

----------------------------------------------------------------
-- Apply dynamics and accents to note velocities
----------------------------------------------------------------
local function apply_dynamics_and_accents(take, textsByPPQ, item, tr)
  local _, noteCount = reaper.MIDI_CountEvts(take)
  local changed = 0
  
  -- Build a list of dynamic changes chronologically
  local ppq_list = {}
  for ppq, _ in pairs(textsByPPQ) do ppq_list[#ppq_list+1] = ppq end
  table.sort(ppq_list)
  
  -- Track current dynamic level as we process events
  local current_dynamic = nil
  local dynamic_changes = {} -- ppq -> {value=X, is_crescendo=bool, target=Y}
  
  -- Process all text events to build dynamic timeline
  for _, ppq in ipairs(ppq_list) do
    local texts = textsByPPQ[ppq]
    
    -- Check for regular dynamic
    local dynVal = choose_dyn_for_ppq(texts)
    
    -- Check for crescendo/diminuendo
    local is_crescendo = is_crescendo_diminuendo(texts)
    
    if dynVal then
      dynamic_changes[ppq] = {value = dynVal, is_crescendo = false}
      current_dynamic = dynVal
    elseif is_crescendo and current_dynamic then
      -- Find the next dynamic level for crescendo target
      local target_dynamic = nil
      
      -- First, look within the current item
      for i, check_ppq in ipairs(ppq_list) do
        if check_ppq > ppq then
          local check_texts = textsByPPQ[check_ppq]
          local check_dyn = choose_dyn_for_ppq(check_texts)
          if check_dyn then
            target_dynamic = check_dyn
            goto found_target
          end
        end
      end
      ::found_target::
      
      -- If not found in current item, search across track
      if not target_dynamic then
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local crescendo_time = item_start + reaper.MIDI_GetProjTimeFromPPQPos(take, ppq) - reaper.MIDI_GetProjTimeFromPPQPos(take, 0)
        target_dynamic = find_next_dynamic_info_on_track(tr, crescendo_time)
      end
      
      if target_dynamic then
        dynamic_changes[ppq] = {value = current_dynamic, is_crescendo = true, target = target_dynamic}
        log(string.format("Crescendo/diminuendo velocity ramp: %d -> %d starting at PPQ %d", current_dynamic, target_dynamic, ppq))
      else
        log(string.format("No target found for crescendo/diminuendo at PPQ %d", ppq))
      end
    end
  end
  
  -- Apply dynamics to note velocities (including accents)
  for i = 0, noteCount-1 do
    local rv, sel, mute, ppqStart, ppqEnd, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
    if rv then
      local note_dynamic = nil
      local is_in_crescendo = false
      local crescendo_start_ppq, crescendo_start_val, crescendo_target_val = nil, nil, nil
      local is_accented = false
      
      -- Check if this note has an accent
      if textsByPPQ[ppqStart] then
        is_accented = is_accent(textsByPPQ[ppqStart])
      end
      
      -- Find the most recent dynamic change at or before this note
      for _, check_ppq in ipairs(ppq_list) do
        if check_ppq <= ppqStart then
          local change = dynamic_changes[check_ppq]
          if change then
            if change.is_crescendo then
              is_in_crescendo = true
              crescendo_start_ppq = check_ppq
              crescendo_start_val = change.value
              crescendo_target_val = change.target
            else
              note_dynamic = change.value
              is_in_crescendo = false
            end
          end
        else
          break
        end
      end
      
      local final_velocity = vel
      
      if is_in_crescendo and crescendo_start_ppq and crescendo_start_val and crescendo_target_val then
        -- Handle crescendo/diminuendo
        local crescendo_end_ppq = nil
        for _, check_ppq in ipairs(ppq_list) do
          if check_ppq > crescendo_start_ppq then
            local change = dynamic_changes[check_ppq]
            if change and not change.is_crescendo then
              crescendo_end_ppq = check_ppq
              break
            end
          end
        end
        
        if crescendo_end_ppq then
          -- Same-item crescendo: ramp to the target dynamic position
          local crescendo_progress = (ppqStart - crescendo_start_ppq) / (crescendo_end_ppq - crescendo_start_ppq)
          crescendo_progress = math.max(0, math.min(1, crescendo_progress)) -- Clamp to 0-1
          final_velocity = math.floor(crescendo_start_val + (crescendo_target_val - crescendo_start_val) * crescendo_progress + 0.5)
          final_velocity = math.max(1, math.min(127, final_velocity)) -- Clamp to valid MIDI range
        else
          -- Cross-item crescendo: ramp to end of current item
          local item_length_sec = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
          local item_end_qn = reaper.MIDI_GetProjQNFromPPQPos(take, 0) + (item_length_sec * reaper.Master_GetTempo() / 60)
          local item_end_ppq = reaper.MIDI_GetPPQPosFromProjQN(take, item_end_qn)
          
          local crescendo_progress = (ppqStart - crescendo_start_ppq) / (item_end_ppq - crescendo_start_ppq)
          crescendo_progress = math.max(0, math.min(1, crescendo_progress)) -- Clamp to 0-1
          final_velocity = math.floor(crescendo_start_val + (crescendo_target_val - crescendo_start_val) * crescendo_progress + 0.5)
          final_velocity = math.max(1, math.min(127, final_velocity)) -- Clamp to valid MIDI range
        end
        
        -- Apply accent boost to crescendo velocity if accented
        if is_accented then
          local accented_velocity = get_accented_velocity_level(final_velocity)
          if accented_velocity ~= final_velocity then
            log(string.format("Accent applied to crescendo note at PPQ %d: %d -> %d", ppqStart, final_velocity, accented_velocity))
            final_velocity = accented_velocity
          else
            log(string.format("Accent ignored on crescendo note at PPQ %d (already at maximum)", ppqStart))
          end
        end
        
      elseif note_dynamic then
        final_velocity = note_dynamic
        
        -- Apply accent boost to regular dynamic if accented
        if is_accented then
          local accented_velocity = get_accented_velocity_level(final_velocity)
          if accented_velocity ~= final_velocity then
            log(string.format("Accent applied to note at PPQ %d: %d -> %d", ppqStart, final_velocity, accented_velocity))
            final_velocity = accented_velocity
          else
            log(string.format("Accent ignored on note at PPQ %d (already at maximum)", ppqStart))
          end
        end
      end
      
      if vel ~= final_velocity then
        reaper.MIDI_SetNote(take, i, sel, mute, ppqStart, ppqEnd, chan, pitch, final_velocity, true)
        changed = changed + 1
      end
    end
  end
  
  if changed > 0 then reaper.MIDI_Sort(take) end
  return changed
end

----------------------------------------------------------------
-- MAIN
----------------------------------------------------------------
local function main()
  log("=== Dynamics to Velocity ===")

  local tr = get_target_track()
  if not tr then
    reaper.MB("No target track found (select a track or a MIDI item).", "Dynamics to Velocity", 0)
    return
  end

  local _, trname = reaper.GetTrackName(tr, "")
  log("Track: "..trname)

  reaper.Undo_BeginBlock()
  
  local itemCount = reaper.CountTrackMediaItems(tr)
  local totalVel = 0

  for itidx = 0, itemCount-1 do
    local item = reaper.GetTrackMediaItem(tr, itidx)
    local take = item and reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local texts = collect_texts_by_ppq(take)
      local velchg = apply_dynamics_and_accents(take, texts, item, tr)
      totalVel = totalVel + velchg
      log(string.format("Item #%d: velocity-changed notes=%d", itidx+1, velchg))
    end
  end

  reaper.Undo_EndBlock("Dynamics to Velocity", -1)
  log(string.format("=== DONE. Total velocity-changed notes=%d ===", totalVel))
  show_toast_from_log()
end

main()