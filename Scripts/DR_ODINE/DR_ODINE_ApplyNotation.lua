-- @description DR_ODINE_Articulation & Dynamics to PC & CC1
-- @author DR_ODINE
-- @version 1.0
-- @provides [main] DR_ODINE_ApplyNotation.lua
-- @about
--   # Articulation & Dynamics to PC & CC1
--   
--   Main articulation processor. Converts text events to Program Changes and CC1 dynamics.
--   Supports mapped/unmapped modes, crescendo/diminuendo, and accent handling.

-- Articulation & Dynamics -> PC & CC1 (RAW STREAM) + Unmapped fallback + Toast UI
-- INI path:
-- Dynamic path configuration
local function get_articmaps_dir()
  local dir = reaper.GetResourcePath() .. "/Data/DR_ODINE Maps"
  -- Create directory if it doesn't exist (cross-platform)
  local f = io.open(dir .. "/test", "w")
  if f then
    f:close()
    os.remove(dir .. "/test")  
  else
    -- Directory doesn't exist, try to create it
    if reaper.GetOS():find("Win") then
      os.execute('mkdir "' .. dir .. '"')
    else
      os.execute('mkdir -p "' .. dir .. '"')
    end
  end
  return dir .. "/"
end

local ARTICMAPS_DIR = get_articmaps_dir()
local INI_PATH = ARTICMAPS_DIR .. "DR_ODINE_Maps.ini"

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
  gfx.init("ArticMaps - Result", w, h, 0, mx - w/2, my - h - 40)
  _toast_msg = msg
  _toast_t0  = reaper.time_precise()
  _toast_on  = true
  toast_tick()
end

----------------------------------------------------------------
-- Utils
----------------------------------------------------------------
local function trim(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end
local function norm(s) s = s:lower(); return s:gsub("[^%w]+","") end
local function split_kv(line) local k,v = line:match("^%s*([^=]+)%s*=%s*(.-)%s*$"); if k then return trim(k), trim(v) end end
local function read_file(path) local f=io.open(path,"r"); if not f then return nil,"Cannot open "..path end local t=f:read("*a"); f:close(); return t end

-- Dynamics constants (moved here for global access)
local DYN_CC = { ppp=15, pp=25, p=40, mp=55, mf=75, f=90, ff=110, fff=125 }

-- Helper: decide stamp kind at a PPQ from its text events
local function _normtxt(s)
  return (s or ""):lower():gsub("%s+", "")
end

local function artic_stamp_kind_at(arr)
  local found_stacc, found_marc = false, false
  for _, t in ipairs(arr or {}) do
    local s = (type(t) == "string") and t or (t.text or t.name or t.txt or "")
    s = _normtxt(s)
    if s ~= "" then
      if s:find("marc") then found_marc = true end
      if s:find("stacc") then found_stacc = true end
    end
  end
  if found_marc then return 2 end
  if found_stacc then return 1 end
  return nil
end


----------------------------------------------------------------
-- Enhanced cross-track dynamic search with value return
----------------------------------------------------------------
local function find_next_dynamic_info_on_track(tr, after_time)
  local itemCount = reaper.CountTrackMediaItems(tr)
  local next_dyn = nil
  local next_time = math.huge
  local next_item_idx = nil
  
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
            if tok and DYN_CC[tok] then
              next_dyn = DYN_CC[tok]
              next_time = event_time
              next_item_idx = itidx
            end
          end
        end
      end
    end
  end
  
  return next_dyn, next_item_idx
end


----------------------------------------------------------------
-- INI parsing
----------------------------------------------------------------
local function parse_ini(txt)
  local maps, instruments = {}, {}
  local curType, curName
  for line in txt:gmatch("[^\r\n]+") do
    line = trim(line)
    if line == "" or line:match("^;") or line:match("^#") then goto continue end
    local sec = line:match("^%[(.-)%]$")
    if sec then
      local t,n = sec:match("^(%w+)%s*:%s*(.+)$")
      if t and n then
        curType, curName = t:lower(), trim(n)
        if curType=="map" and not maps[curName] then maps[curName] = {channel=1,names={}, pc_off={}} end
        if curType=="instrument" and not instruments[curName] then instruments[curName] = {} end
      else
        curType,curName=nil,nil
      end
      goto continue
    end
    if not curType or not curName then goto continue end
    local k,v = split_kv(line); if not k then goto continue end
    k = k:lower()
    if curType=="map" then
      if k=="channel" then
        maps[curName].channel = math.max(1, math.min(16, tonumber(v) or 1))
      elseif k=="bank" then
        local msb,lsb=v:match("^(%d+)%s*:%s*(%d+)$")
        if msb then maps[curName].bankMSB, maps[curName].bankLSB = tonumber(msb), tonumber(lsb) end
      elseif k:sub(1,5)=="name." then
        local artName = trim(k:sub(6)); local pc = tonumber(v)
        if pc and pc>=0 and pc<=127 then maps[curName].names[norm(artName)] = pc end
      elseif k:sub(1,3)=="pc." then
        local n = tonumber(k:sub(4))
        if n and n>=0 and n<=127 then
          if v and v:lower():match("^%s*off%s*$") then maps[curName].pc_off[n] = true end
        end
      end
    elseif curType=="instrument" then
      if k=="use" then instruments[curName].use = v end
    end
    ::continue::
  end
  return maps, instruments
end

----------------------------------------------------------------
-- Track / preset resolve
----------------------------------------------------------------
local function get_target_track()
  -- First priority: Check if MIDI editor is open and has a target track
  local midi_editor = reaper.MIDIEditor_GetActive()
  if midi_editor then
    local active_take = reaper.MIDIEditor_GetTake(midi_editor)
    if active_take then
      local target_track = reaper.GetMediaItemTake_Track(active_take)
      if target_track then
        return target_track
      end
    end
  end
  
  -- Second priority: Selected MIDI items
  local selItemCount = reaper.CountSelectedMediaItems(0)
  for i=0, selItemCount-1 do
    local it = reaper.GetSelectedMediaItem(0,i)
    local take = it and reaper.GetActiveTake(it)
    if take and reaper.TakeIsMIDI(take) then return reaper.GetMediaItem_Track(it) end
  end
  
  -- Third priority: Selected track fallback
  local selTrCount = reaper.CountSelectedTracks(0)
  if selTrCount>0 then return reaper.GetSelectedTrack(0,0) end
  
  return nil
end

local function get_track_preset_name(tr)
  if not tr then return nil end
  local fx = reaper.TrackFX_GetInstrument(tr); if fx==-1 then fx=0 end
  local ok, name = reaper.TrackFX_GetPreset(tr, fx)
  if ok and name and name~="" then return name end
  local _, trname = reaper.GetTrackName(tr, ""); return trname
end

local function resolve_instrument_section(instruments, name)
  if not name then return nil end
  local nname = norm(name)
  for inst,_ in pairs(instruments) do if nname==norm(inst) then return inst end end
  for inst,_ in pairs(instruments) do local nn=norm(inst); if nname:find(nn,1,true) or nn:find(nname,1,true) then return inst end end
  return nil
end

local function build_artic_pc_map(maps, instruments, presetName)
  local instKey = resolve_instrument_section(instruments, presetName)
  if not instKey then return nil, "No [instrument:*] matched: "..tostring(presetName) end
  local mapName = instruments[instKey].use
  if not mapName or not maps[mapName] then return nil, "Missing [map:"..tostring(mapName).."]" end
  local map = maps[mapName]
  local names = map.names or {}
  local sustainPC = names[norm("Sustain")] or 0
  local keys = {}; for k,_ in pairs(names) do keys[#keys+1]=k end
  table.sort(keys, function(a,b) return #a > #b end)
  return {
    instKey=instKey, mapName=mapName,
    channel=map.channel or 1, bankMSB=map.bankMSB, bankLSB=map.bankLSB,
    names=names, nameKeys=keys, sustainPC=sustainPC,
    pc_off = map.pc_off or {}
  }
end

----------------------------------------------------------------
-- Text collection / matching
----------------------------------------------------------------
local function collect_texts_by_ppq(take)
  local _, _, _, textCount = reaper.MIDI_CountEvts(take)
  local at = {}
  for i=0, textCount-1 do
    local _, _, _, ppq, typ, msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if typ and msg and typ ~= -1 then
      at[ppq] = at[ppq] or {}
      at[ppq][#at[ppq]+1] = norm(msg)
    end
  end
  return at
end

local function choose_pc_for_ppq(articCfg, textsAtPPQ)
  if textsAtPPQ then
    for _, key in ipairs(articCfg.nameKeys) do
      for _, m in ipairs(textsAtPPQ) do
        if m:find(key,1,true) then return articCfg.names[key] end
      end
    end
    for _, m in ipairs(textsAtPPQ) do
      if m:match("phrase%d*slurbegin")
      or m:match("phrase%d*slurcontinue")
      or m:match("phrase%d*slurend")
      or m:find("phraseslurbegin",1,true)
      or m:find("phraseslurcontinue",1,true)
      or m:find("phraseslurend",1,true)
      then
        local leg = articCfg.names["legato"]
        if leg ~= nil then return leg end
      end
    end
  end
  return articCfg.sustainPC
end

local function choose_dyn_for_ppq(textsAtPPQ)
  if not textsAtPPQ then return nil end
  for _, m in ipairs(textsAtPPQ) do
    local tok = m:match("dynamic([pmf]+)")
    if tok and DYN_CC[tok] then return DYN_CC[tok] end
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

local function get_accented_dynamic_level(current_level)
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
    -- Already at maximum, ignore
    return nil
  end
end

----------------------------------------------------------------
-- Unmapped articulation scanner (whitelist + slur->legato)
----------------------------------------------------------------
local WL = {
  sustain="sustain", staccato="staccato", legato="legato",
  svibrato="sustainvibrato", sustainvibrato="sustainvibrato",
  pizzicato="pizzicato", spiccato="spiccato", tremolo="tremolo", marcato="marcato",
}
local WL_KEYS = {}; for k,_ in pairs(WL) do WL_KEYS[#WL_KEYS+1]=k end
table.sort(WL_KEYS, function(a,b) return #a>#b end)

local function scan_unmapped_articulations_on_take(take, articCfg)
  local unmapped_idx, count = {}, 0
  local _, _, _, textCount = reaper.MIDI_CountEvts(take)
  for i=0, textCount-1 do
    local _, _, _, _, typ, msg = reaper.MIDI_GetTextSysexEvt(take, i)
    if typ and msg and typ ~= -1 then
      local nm = norm(msg)
      local hit = nil
      if nm:find("articulation",1,true) then
        for _, key in ipairs(WL_KEYS) do
          if nm:find("articulation"..key, 1, true) then hit = WL[key]; break end
        end
      else
        if nm:match("phrase%d*slurbegin")
        or nm:match("phrase%d*slurcontinue")
        or nm:match("phrase%d*slurend")
        or nm:find("phraseslurbegin",1,true)
        or nm:find("phraseslurcontinue",1,true)
        or nm:find("phraseslurend",1,true) then
          hit = "legato"
        end
      end
      if hit then
        local pc = articCfg.names[hit]
        local is_unmapped = (pc == nil)
        local is_disabled = (pc and articCfg.pc_off and articCfg.pc_off[pc]) or false
        if is_unmapped or is_disabled then
          unmapped_idx[#unmapped_idx+1]=i; count=count+1
        end
      end
    end
  end
  return unmapped_idx, count
end

----------------------------------------------------------------
-- Raw stream helpers
----------------------------------------------------------------
local pack, unpack = string.pack, string.unpack
local function read_stream(take)
  local ok, buf = reaper.MIDI_GetAllEvts(take, "")
  if not ok then return nil, "MIDI_GetAllEvts failed" end
  local events = {}
  local pos, runppq, idx = 1, 0, 0
  while pos <= #buf do
    local offset, flags, msg
    offset, pos = unpack("<i4", buf, pos)
    flags,  pos = unpack("<I1", buf, pos)
    msg,    pos = unpack("<s4", buf, pos)
    runppq = runppq + offset
    idx = idx + 1
    events[#events+1] = {ppq=runppq, flags=flags, msg=msg, idx=idx}
  end
  return events
end

local function parse_msg(msg)
  local b1 = msg:byte(1); if not b1 then return nil end
  if b1 >= 0x80 and b1 <= 0xEF then
    local d1 = msg:byte(2); local d2 = msg:byte(3)
    return b1, d1, d2
  end
  return b1
end

local function cc_exists_at(events, ppq, chan, ccnum, val)
  for _,e in ipairs(events) do
    if e.ppq == ppq then
      local s,d1,d2 = parse_msg(e.msg)
      if s and (s & 0xF0) == 0xB0 and (s & 0x0F) == (chan & 0x0F) and d1 == ccnum and d2 == val then
        return true
      end
    end
  end
  return false
end

----------------------------------------------------------------
-- PC pre-roll: shift earlier by 1/128 note (musical), clamp to item start
----------------------------------------------------------------
-- PC pre-roll: shift earlier by 1/128 note (musical), can extend to previous item
local SHIFT_QN = 0.03125 -- 1/128 note in QN

local function pc_preroll_ppq(take, note_ppq)
  if note_ppq <= 0 then return 0 end
  local qn_at = reaper.MIDI_GetProjQNFromPPQPos(take, note_ppq)
  local item_qn0 = reaper.MIDI_GetProjQNFromPPQPos(take, 0)
  local pre_qn = qn_at - SHIFT_QN
  if pre_qn < item_qn0 then pre_qn = item_qn0 end
  local pre_ppq = reaper.MIDI_GetPPQPosFromProjQN(take, pre_qn)
  if pre_ppq < 0 then pre_ppq = 0 end
  return pre_ppq
end

-- ADD THE NEW FUNCTIONS HERE:
local function find_adjacent_previous_item(tr, current_item)
  local current_start = reaper.GetMediaItemInfo_Value(current_item, "D_POSITION")
  log(string.format("Current item starts at: %.6f", current_start))
  
  if current_start <= 0.000001 then 
    log("Current item is at project start, no previous item possible")
    return nil 
  end
  
  local item_count = reaper.CountTrackMediaItems(tr)
  log(string.format("Checking %d items on track for adjacency", item_count))
  
  for i = 0, item_count - 1 do
    local item = reaper.GetTrackMediaItem(tr, i)
    if item ~= current_item then
      local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
      local item_length = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
      local item_end = item_start + item_length
      
      local gap = math.abs(item_end - current_start)
      log(string.format("Item %d: start=%.6f, end=%.6f, gap=%.6f", i, item_start, item_end, gap))
      
      -- Increased tolerance for floating-point precision issues
      if gap < 0.01 then  -- 10ms tolerance instead of 1ms
        log(string.format("Found adjacent previous item ending at %.6f (gap: %.6f)", item_end, gap))
        local take = reaper.GetActiveTake(item)
        if take and reaper.TakeIsMIDI(take) then
          log("Adjacent item has valid MIDI take")
          return item, take
        else
          log("Adjacent item has no valid MIDI take")
        end
      end
    end
  end
  log("No adjacent previous item found")
  return nil
end

local function insert_preroll_in_previous_item(prev_item, prev_take, pc, chan)
  log(string.format("Attempting to insert pre-roll PC=%d on channel %d in previous item", pc or 0, chan or 0))
  
  -- Get the length of the previous item in seconds
  local prev_item_length = reaper.GetMediaItemInfo_Value(prev_item, "D_LENGTH")
  log(string.format("Previous item length: %.6f seconds", prev_item_length or 0))
  
  -- Convert to quarter notes and calculate pre-roll position
  local tempo = reaper.Master_GetTempo()
  local prev_item_length_qn = prev_item_length * tempo / 60
  local prev_item_start_qn = reaper.MIDI_GetProjQNFromPPQPos(prev_take, 0)
  local prev_item_end_qn = prev_item_start_qn + prev_item_length_qn
  local preroll_qn = prev_item_end_qn - SHIFT_QN
  
  log(string.format("Previous item: start_qn=%.6f, end_qn=%.6f, preroll_qn=%.6f", 
    prev_item_start_qn or 0, prev_item_end_qn or 0, preroll_qn or 0))
  
  -- Make sure pre-roll position is within the previous item
  if preroll_qn < prev_item_start_qn then
    log("Pre-roll position would be before previous item start, clamping")
    preroll_qn = prev_item_start_qn
  end
  
  local preroll_ppq = reaper.MIDI_GetPPQPosFromProjQN(prev_take, preroll_qn)
  log(string.format("Pre-roll PPQ position: %d", math.floor(preroll_ppq or 0)))
  
  -- Read existing events from previous item
  local events, err = read_stream(prev_take)
  if not events then
    log("Failed to read MIDI stream from previous item: " .. tostring(err))
    return false
  end
  
  -- Add the pre-roll PC event
  local spc = string.char((0xC0 | (chan & 0x0F)), pc & 0x7F)
  events[#events+1] = {ppq=math.floor(preroll_ppq), flags=1, msg=spc, idx=1e9}
  log(string.format("Added PC event at PPQ %d", math.floor(preroll_ppq or 0)))
  
  -- Sort and commit back to the previous item
  table.sort(events, function(a,b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return (a.idx or 0) < (b.idx or 0)
  end)
  
  local out, prev = {}, 0
  for _,e in ipairs(events) do
    out[#out+1] = pack("<i4I1s4", e.ppq - prev, e.flags or 0, e.msg or "")
    prev = e.ppq
  end
  
  local success = reaper.MIDI_SetAllEvts(prev_take, table.concat(out))
  if success then
    reaper.MIDI_Sort(prev_take)
    log("Successfully inserted pre-roll PC in previous item")
    return true
  else
    log("Failed to set MIDI events in previous item")
    return false
  end
end

----------------------------------------------------------------
-- Commit (mapped): clear ALL PCs & CC1, then insert CC1 + (bank) + PCs
----------------------------------------------------------------
local function apply_inserts_stream(take, pc_inserts, cc1_inserts, bankMSB, bankLSB)
  local events = assert(read_stream(take))

  local filtered, removed_pc, removed_cc1 = {}, 0, 0
  for _,e in ipairs(events) do
    local s,d1 = parse_msg(e.msg)
    if s and (s & 0xF0) == 0xC0 then
      removed_pc = removed_pc + 1
    elseif s and (s & 0xF0) == 0xB0 and d1 == 1 then
      removed_cc1 = removed_cc1 + 1
    elseif s and (s & 0xF0) == 0xB0 and d1 == 119 then
      -- also clear CC119 (stacc/marc stamps) in mapped mode
    else
      filtered[#filtered+1] = e
    end
  end
  events = filtered

  local added_pc, added_cc = 0, 0
  local big = 1e9

  -- Helper function to pack flags with curve shape
  local function PackFlags(selected, muted, curve_shape)
    local flags = curve_shape and curve_shape<<4 or 0
    flags = flags|(muted and 2 or 0)|(selected and 1 or 0)
    return flags
  end

  local lastValByChan = {}

  for i, ins in ipairs(cc1_inserts or {}) do
    local ch = ins.chan & 0x0F
    local startPPQ = ins.ppq

    -- Use linear curve for crescendo/diminuendo, square for regular dynamics and accents
    local flags
    if ins.is_crescendo then
      flags = PackFlags(false, false, 1) -- Linear curve (1) for crescendo/diminuendo
    else
      flags = PackFlags(false, false, 0) -- Square curve (0) for regular dynamics and accents
    end

    -- For crescendo and accent events, force insertion even if same value exists
    local should_insert = true
    if not ins.is_crescendo and not ins.is_accent_start and not ins.is_accent_end then
      should_insert = not cc_exists_at(events, startPPQ, ch, 1, ins.val)
    end
    
    if should_insert then
      local scc = string.char((0xB0 | ch), 1, ins.val & 0x7F)
      events[#events+1] = {ppq=startPPQ, flags=flags, msg=scc, idx=big + i*3 + 0}
      added_cc = added_cc + 1
      local event_type = ins.is_crescendo and "(crescendo)" 
                      or ins.is_accent_start and "(accent start)"
                      or ins.is_accent_end and "(accent end)"
                      or "(regular)"
      local curve_type = ins.is_crescendo and "LINEAR" or "SQUARE"
      log(string.format("Inserted CC1=%d at PPQ %d on channel %d %s %s", 
        ins.val, startPPQ, ch, event_type, curve_type))
    else
      log(string.format("Skipped duplicate CC1=%d at PPQ %d on channel %d", ins.val, startPPQ, ch))
    end
    
    lastValByChan[ch] = ins.val
  end

  -- Bank select + PCs at (pre-rolled) PPQ
  for j,ins in ipairs(pc_inserts or {}) do
    local idxbase = big + 200000 + j*3
    if bankMSB then
      local s0 = string.char((0xB0 | (ins.chan & 0x0F)), 0, bankMSB & 0x7F)
      events[#events+1] = {ppq=ins.ppq, flags=1, msg=s0, idx=idxbase + 0}
    end
    if bankLSB then
      local s1 = string.char((0xB0 | (ins.chan & 0x0F)), 32, bankLSB & 0x7F)
      events[#events+1] = {ppq=ins.ppq, flags=1, msg=s1, idx=idxbase + 1}
    end
    local spc = string.char((0xC0 | (ins.chan & 0x0F)), ins.pc & 0x7F)
    events[#events+1] = {ppq=ins.ppq, flags=1, msg=spc, idx=idxbase + 2}
    added_pc = added_pc + 1
  end

  table.sort(events, function(a,b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return (a.idx or 0) < (b.idx or 0)
  end)

  local out, prev = {}, 0
  for _,e in ipairs(events) do
    out[#out+1] = pack("<i4I1s4", e.ppq - prev, e.flags or 0, e.msg or "")
    prev = e.ppq
  end

  assert(reaper.MIDI_SetAllEvts(take, table.concat(out)))
  
  reaper.MIDI_Sort(take)
  return true, added_pc, added_cc, removed_pc, removed_cc1
end


----------------------------------------------------------------
-- UNMAPPED PRESET: dynamics->velocity + clear PCs/CC1 + stamp CC119
----------------------------------------------------------------
local DYN_TO_VEL = { ppp=15, pp=25, p=40, mp=55, mf=75, f=90, ff=110, fff=125 }
local STAMP_CC = 119; local STAMP_STACC=1; local STAMP_MARC=2

local function collect_texts_by_ppq_full(take)
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

local function last_dyn_vel_at(textsByPPQ, ppq)
  if not textsByPPQ then return nil end
  local list = {}
  for p,_ in pairs(textsByPPQ) do list[#list+1]=p end
  table.sort(list)
  local val = nil
  for i=#list,1,-1 do
    local p = list[i]
    if p <= ppq then
      local arr = textsByPPQ[p]
      for j=1,#arr do
        local tok = arr[j]:match("dynamic([pmf]+)")
        if tok and DYN_TO_VEL[tok] then val = DYN_TO_VEL[tok]; break end
      end
      if val then return val end
    end
  end
  return nil
end

local function wipe_pcs_cc1_and_stamp(take, textsByPPQ)
  local events = assert(read_stream(take))
  local kept = {}
  local removedPC, removedCC1, removedCC119 = 0,0,0

  for _, e in ipairs(events) do
    local st, d1 = parse_msg(e.msg)
    if st and (st & 0xF0) == 0xC0 then
      removedPC = removedPC + 1
    elseif st and (st & 0xF0) == 0xB0 and d1 == 1 then
      removedCC1 = removedCC1 + 1
    elseif st and (st & 0xF0) == 0xB0 and d1 == STAMP_CC then
      removedCC119 = removedCC119 + 1
    else
      kept[#kept+1] = e
    end
  end

  local stamp_kind_at = {}
  if textsByPPQ then
    for ppq, arr in pairs(textsByPPQ) do
      local k = artic_stamp_kind_at(arr)
      if k == STAMP_STACC or k == STAMP_MARC then
        stamp_kind_at[ppq] = k
      end
    end
  end

  local _, noteCount = reaper.MIDI_CountEvts(take)
  local uniq_ppq_map, uniq_ppq_list = {}, {}
  for i = 0, noteCount - 1 do
    local ok, _, _, ppqStart = reaper.MIDI_GetNote(take, i)
    if ok and not uniq_ppq_map[ppqStart] then
      uniq_ppq_map[ppqStart] = true
      uniq_ppq_list[#uniq_ppq_list+1] = ppqStart
    end
  end
  table.sort(uniq_ppq_list)

  local addedStamp, last_val = 0, nil
  for _, ppq in ipairs(uniq_ppq_list) do
    local desired = stamp_kind_at[ppq] or 0
    if last_val == nil or desired ~= last_val then
      local val = (desired == STAMP_STACC) and STAMP_STACC
               or (desired == STAMP_MARC)  and STAMP_MARC
               or 0
      local msg = string.char(0xB0, STAMP_CC, val)
      kept[#kept+1] = { ppq = ppq, flags = 1, msg = msg, idx = 1e9 + addedStamp }
      addedStamp = addedStamp + 1
      last_val = desired
    end
  end

  table.sort(kept, function(a,b)
    if a.ppq ~= b.ppq then return a.ppq < b.ppq end
    return (a.idx or 0) < (b.idx or 0)
  end)

  local out, prev = {}, 0
  for _, e in ipairs(kept) do
    out[#out+1] = string.pack("<i4I1s4", e.ppq - prev, e.flags or 0, e.msg or "")
    prev = e.ppq
  end
  reaper.MIDI_SetAllEvts(take, table.concat(out))
  reaper.MIDI_Sort(take)

  return removedPC, removedCC1, addedStamp
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
    local dynVal = nil
    for _, txt in ipairs(texts) do
      local tok = txt:match("dynamic([pmf]+)")
      if tok and DYN_TO_VEL[tok] then
        dynVal = DYN_TO_VEL[tok]
        break
      end
    end
    
    -- Check for crescendo/diminuendo
    local is_crescendo = false
    for _, txt in ipairs(texts) do
      if txt:find("crescendo", 1, true) or txt:find("diminuendo", 1, true) then
        is_crescendo = true
        break
      end
    end
    
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
          for _, txt in ipairs(check_texts) do
            local tok = txt:match("dynamic([pmf]+)")
            if tok and DYN_TO_VEL[tok] then
              target_dynamic = DYN_TO_VEL[tok]
              goto found_target
            end
          end
        end
      end
      ::found_target::
      
      -- If not found in current item, search across track
      if not target_dynamic then
        local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
        local crescendo_time = item_start + reaper.MIDI_GetProjTimeFromPPQPos(take, ppq) - reaper.MIDI_GetProjTimeFromPPQPos(take, 0)
        
        -- Search other items on the track for the next dynamic
        local itemCount = reaper.CountTrackMediaItems(tr)
        for itidx = 0, itemCount-1 do
          local other_item = reaper.GetTrackMediaItem(tr, itidx)
          local other_take = other_item and reaper.GetActiveTake(other_item)
          if other_take and reaper.TakeIsMIDI(other_take) then
            local other_item_start = reaper.GetMediaItemInfo_Value(other_item, "D_POSITION")
            local _, _, _, textCount = reaper.MIDI_CountEvts(other_take)
            
            for i = 0, textCount-1 do
              local _, _, _, other_ppq, typ, msg = reaper.MIDI_GetTextSysexEvt(other_take, i)
              if typ and msg and typ ~= -1 then
                local event_time = other_item_start + reaper.MIDI_GetProjTimeFromPPQPos(other_take, other_ppq) - reaper.MIDI_GetProjTimeFromPPQPos(other_take, 0)
                
                if event_time > crescendo_time then
                  local norm_msg = norm(msg)
                  local tok = norm_msg:match("dynamic([pmf]+)")
                  if tok and DYN_TO_VEL[tok] then
                    target_dynamic = DYN_TO_VEL[tok]
                    goto found_cross_item_target
                  end
                end
              end
            end
          end
        end
        ::found_cross_item_target::
      end
      
      if target_dynamic then
        dynamic_changes[ppq] = {value = current_dynamic, is_crescendo = true, target = target_dynamic, cross_item = not target_dynamic}
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
        for _, txt in ipairs(textsByPPQ[ppqStart]) do
          if txt:find("articulationaccent", 1, true) then
            is_accented = true
            break
          end
        end
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
  log("=== Articulation & Dynamics -> PC & CC1 (raw stream) ===")
  log("INI: "..INI_PATH)

  local iniTxt, err = read_file(INI_PATH)
  if not iniTxt then
    reaper.MB("INI not found:\n"..tostring(err), "Artic/Dyn -> PC/CC1", 0)
    return
  end
  local maps, instruments = parse_ini(iniTxt)

  local tr = get_target_track()
  if not tr then
    reaper.MB("No target track found (select a track or a MIDI item).", "Artic/Dyn -> PC/CC1", 0)
    return
  end

  local _, trname = reaper.GetTrackName(tr, "")
  log("Track: "..trname)
  local presetName = get_track_preset_name(tr)
  log("Preset/identifier: "..tostring(presetName))

  local articCfg, why = build_artic_pc_map(maps, instruments, presetName)

  -- ===== UNMAPPED PRESET FALLBACK =====
  if not articCfg then
    log("Unmapped preset: clear PCs/CC1, apply dynamics->velocity, and stamp Stacc/Marc.")
    reaper.Undo_BeginBlock()
    local itemCount = reaper.CountTrackMediaItems(tr)
    local totalRemovedPC, totalRemovedCC1, totalStamped, totalVel = 0,0,0,0

    for itidx=0,itemCount-1 do
    local item = reaper.GetTrackMediaItem(tr, itidx)
    local take = item and reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
        local texts = collect_texts_by_ppq_full(take)
        local rPC, rCC1, stamps = wipe_pcs_cc1_and_stamp(take, texts)
        local velchg = apply_dynamics_and_accents(take, texts, item, tr)  -- Note: item before tr
        totalRemovedPC  = totalRemovedPC  + rPC
        totalRemovedCC1 = totalRemovedCC1 + rCC1
        totalStamped    = totalStamped    + stamps
        totalVel        = totalVel        + velchg
            log(string.format("Item #%d: removed PC=%d, removed CC1=%d, stamped=%d, velocity-changed notes=%d",
                itidx+1, rPC, rCC1, stamps, velchg))
            end
    end

    reaper.Undo_EndBlock("ArticMaps (unmapped): clear PCs/CC1, dynamics->velocity, stamp", -1)
    log(string.format("=== UNMAPPED DONE. Removed PCs=%d, CC1=%d, Stamps=%d, VelChanged=%d ===",
      totalRemovedPC, totalRemovedCC1, totalStamped, totalVel))
    --show_toast_from_log()
    return
  end

  -- ===== MAPPED PATH =====
  log("Instrument: "..articCfg.instKey.." -> map: "..articCfg.mapName)
  reaper.Undo_BeginBlock()

  -- Pass 1: scan & (optionally) delete unmapped/disabled articulations
  local itemCount = reaper.CountTrackMediaItems(tr)
  local pending_deletes, total_unmapped = {}, 0
  for itidx = 0, itemCount-1 do
    local item = reaper.GetTrackMediaItem(tr, itidx)
    local take = item and reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local idxs, cnt = scan_unmapped_articulations_on_take(take, articCfg)
      if cnt > 0 then
        pending_deletes[#pending_deletes+1] = {take=take, idxs=idxs}
        total_unmapped = total_unmapped + cnt
      end
    end
  end

  if total_unmapped > 0 then
    local q = string.format(
      "Found %d articulation marks not in or disabled by the current map:\n\nMap: %s\nInstrument: %s\n\nDelete these articulation text events now?\n(Notes will NOT be deleted.)",
      total_unmapped, articCfg.mapName, articCfg.instKey)
    local ret = reaper.MB(q, "Artic/Dyn -> PC/CC1 - Unmapped articulations", 4) -- 4=Yes/No
    if ret == 6 then
      for _, pack in ipairs(pending_deletes) do
        local take = pack.take
        local idxs = pack.idxs
        table.sort(idxs, function(a,b) return a>b end)
        for _, idx in ipairs(idxs) do reaper.MIDI_DeleteTextSysexEvt(take, idx) end
        reaper.MIDI_Sort(take)
      end
      log(string.format("Deleted %d unmapped/disabled articulation text events.", total_unmapped))
    else
      log("User chose to keep unmapped articulation text.")
    end
  else
    log("No unmapped/disabled articulation text found (whitelist only).")
  end

  -- Pass 2: PCs (with pre-roll) + CC1 dynamics
  local totalPC, totalCC, totalRemovedPC, totalRemovedCC1 = 0,0,0,0

  for itidx = 0, itemCount-1 do
    local item = reaper.GetTrackMediaItem(tr, itidx)
    local take = item and reaper.GetActiveTake(item)
    if take and reaper.TakeIsMIDI(take) then
      local textsAt = collect_texts_by_ppq(take)

      -- used channels (fallback: map default-1)
      local usedChanSet, usedChans = {}, {}
      local _, noteCount = reaper.MIDI_CountEvts(take)
      for i=0, noteCount-1 do
        local _, _, _, _, _, chan = reaper.MIDI_GetNote(take, i)
        chan = chan or 0
        if not usedChanSet[chan] then usedChanSet[chan]=true; usedChans[#usedChans+1]=chan end
      end
      if #usedChans == 0 then usedChans[1] = (articCfg.channel-1) & 0x0F end

      -- PCs from articulation at NOTE starts (per channel, change-only) with PRE-ROLL
        local groups, ppqsByChan = {}, {}
        for i=0, noteCount-1 do
          local _, _, _, ppqStart, _, chan = reaper.MIDI_GetNote(take, i)
          chan = chan or 0
          if not groups[chan] then groups[chan] = {} end
          if not groups[chan][ppqStart] then
            groups[chan][ppqStart] = true
            if not ppqsByChan[chan] then ppqsByChan[chan] = {} end
            ppqsByChan[chan][#ppqsByChan[chan]+1] = ppqStart
          end
        end

        local pc_inserts = {}
          for chan, ppqs in pairs(ppqsByChan) do
            table.sort(ppqs)
            local lastPC = nil
            for _, ppq in ipairs(ppqs) do
              local pc = choose_pc_for_ppq(articCfg, textsAt[ppq])
              if pc ~= lastPC then
                if ppq == 0 then
                  -- Check for adjacent previous item
                  local prev_item, prev_take = find_adjacent_previous_item(tr, item)
                  if prev_item and prev_take then
                    insert_preroll_in_previous_item(prev_item, prev_take, pc, chan)
                    log(string.format("Inserted pre-roll PC=%d in previous item on channel %d", pc, chan))
                  end
                  -- Still insert PC at current item start
                  pc_inserts[#pc_inserts+1] = {ppq=0, chan=chan, pc=pc}
                else
                  local adj_ppq = pc_preroll_ppq(take, ppq)
                  pc_inserts[#pc_inserts+1] = {ppq=adj_ppq, chan=chan, pc=pc}
                end
                lastPC = pc
              end
            end
          end

      -- CC1 from dynamics at TEXT times (per used channel, change-only) + crescendo/diminuendo ramps + accents
      local cc1_inserts = {}
      local ppq_list = {}
      for ppq,_ in pairs(textsAt) do ppq_list[#ppq_list+1] = ppq end
      table.sort(ppq_list)

      -- Build dynamic state by processing all dynamics first
      local dynamic_state = {}
      for _, ch in ipairs(usedChans) do dynamic_state[ch] = nil end
      
      for _, ppq in ipairs(ppq_list) do
        local dynVal = choose_dyn_for_ppq(textsAt[ppq])
        if dynVal then
          for _, ch in ipairs(usedChans) do
            dynamic_state[ch] = dynVal
          end
        end
      end
      
      -- Process accented notes first
      local _, noteCount = reaper.MIDI_CountEvts(take)
      for i = 0, noteCount-1 do
        local _, _, _, ppqStart, ppqEnd, chan = reaper.MIDI_GetNote(take, i)
        chan = chan or 0
        
        -- Check if there's an accent at this note start
        if textsAt[ppqStart] and is_accent(textsAt[ppqStart]) then
          -- Find current dynamic level at this position
          local current_dynamic = nil
          for j = #ppq_list, 1, -1 do
            local check_ppq = ppq_list[j]
            if check_ppq <= ppqStart then
              local dynVal = choose_dyn_for_ppq(textsAt[check_ppq])
              if dynVal then
                current_dynamic = dynVal
                break
              end
            end
          end
          
          if current_dynamic then
            local accented_level = get_accented_dynamic_level(current_dynamic)
            if accented_level then
              log(string.format("Found accent at PPQ %d: %d -> %d", ppqStart, current_dynamic, accented_level))
              
              -- Add CC1 events for the accent: start and end
              for _, ch in ipairs(usedChans) do
                -- Accent start: accented level with square flag
                cc1_inserts[#cc1_inserts+1] = {ppq=ppqStart, chan=ch, val=accented_level, is_accent_start=true}
                -- Accent end: back to normal level with square flag  
                cc1_inserts[#cc1_inserts+1] = {ppq=ppqEnd, chan=ch, val=current_dynamic, is_accent_end=true}
              end
            else
              log(string.format("Accent at PPQ %d ignored (already at maximum dynamic)", ppqStart))
            end
          else
            log(string.format("Accent at PPQ %d ignored (no current dynamic level)", ppqStart))
          end
        end
      end
      
      -- Process crescendo/diminuendo with proper state tracking
      for i, ppq in ipairs(ppq_list) do
        if is_crescendo_diminuendo(textsAt[ppq]) then
          log(string.format("Found crescendo/diminuendo at PPQ %d", ppq))
          
          -- Find the current dynamic level at this point (look backwards)
          local current_dynamic_levels = {}
          for _, ch in ipairs(usedChans) do current_dynamic_levels[ch] = nil end
          
          for j = 1, i do
            local check_ppq = ppq_list[j]
            if check_ppq < ppq then -- Only look at earlier positions
              local dynVal = choose_dyn_for_ppq(textsAt[check_ppq])
              if dynVal then
                for _, ch in ipairs(usedChans) do
                  current_dynamic_levels[ch] = dynVal
                end
              end
            end
          end
          
          -- Check if there's any dynamic after this crescendo/diminuendo
          local has_target = false
          local target_value = nil
          local target_in_different_item = false
          
          -- Check within the current item first
          for j = i + 1, #ppq_list do
            local next_ppq = ppq_list[j]
            local dyn = choose_dyn_for_ppq(textsAt[next_ppq])
            if dyn then
              has_target = true
              target_value = dyn
              target_in_different_item = false
              log("Found target dynamic in same item")
              break
            end
          end
          
          -- If not found in current item, check across track
          if not has_target then
            local item_start = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
            local crescendo_time = item_start + reaper.MIDI_GetProjTimeFromPPQPos(take, ppq) - reaper.MIDI_GetProjTimeFromPPQPos(take, 0)
            local next_dyn_val, next_item_idx = find_next_dynamic_info_on_track(tr, crescendo_time)
            if next_dyn_val then
              has_target = true
              target_value = next_dyn_val
              target_in_different_item = (next_item_idx ~= itidx)
              log(string.format("Found target dynamic on track: value=%d, different_item=%s", next_dyn_val, tostring(target_in_different_item)))
            end
          end
          
          -- If we found a target dynamic somewhere, place CC1 at current level
          if has_target then
            for _, ch in ipairs(usedChans) do
              local current_val = current_dynamic_levels[ch]
              if current_val then
                log(string.format("Placing CC1=%d at crescendo/diminuendo on channel %d", current_val, ch))
                cc1_inserts[#cc1_inserts+1] = {ppq=ppq, chan=ch, val=current_val, is_crescendo=true}
                
                -- If target is in different item, add bridge point at end of current item
                if target_in_different_item then
                  -- Get item length in PPQ (simplified calculation)
                  local item_length_sec = reaper.GetMediaItemInfo_Value(item, "D_LENGTH")
                  local item_end_qn = reaper.MIDI_GetProjQNFromPPQPos(take, 0) + (item_length_sec * reaper.Master_GetTempo() / 60)
                  local item_len_ppq = reaper.MIDI_GetPPQPosFromProjQN(take, item_end_qn)
                  local bridge_ppq = math.floor(item_len_ppq - 10) -- 10 PPQ before item end for safety
                  
                  if bridge_ppq > ppq then -- Make sure bridge is after crescendo
                    log(string.format("Adding bridge point CC1=%d at PPQ %d on channel %d (cross-item ramp)", target_value, bridge_ppq, ch))
                    cc1_inserts[#cc1_inserts+1] = {ppq=bridge_ppq, chan=ch, val=target_value, is_crescendo=false, is_bridge=true}
                  end
                end
              else
                log(string.format("No current dynamic level on channel %d, skipping", ch))
              end
            end
          else
            log("No target dynamic found after crescendo/diminuendo, skipping")
          end
        end
      end

      -- Finally process regular dynamics normally
      local lastDynByChan = {}
      for _, ch in ipairs(usedChans) do lastDynByChan[ch] = nil end
      
      for _, ppq in ipairs(ppq_list) do
        local dynVal = choose_dyn_for_ppq(textsAt[ppq])
        if dynVal then
          log(string.format("Found regular dynamic: %d at PPQ %d", dynVal, ppq))
          for _, ch in ipairs(usedChans) do
            if lastDynByChan[ch] ~= dynVal then
              cc1_inserts[#cc1_inserts+1] = {ppq=ppq, chan=ch, val=dynVal, is_crescendo=false}
              lastDynByChan[ch] = dynVal
            end
          end
        end
      end

      -- Commit
      local ok, addedPC, addedCC, removedPC, removedCC1 =
        apply_inserts_stream(take, pc_inserts, cc1_inserts, articCfg.bankMSB, articCfg.bankLSB)
      if not ok then
        reaper.MB("Raw stream insert failed.", "Artic/Dyn -> PC/CC1", 0)
        reaper.Undo_EndBlock("Artic/Dyn -> PC/CC1 (FAILED)", -1)
        return
      else
        totalPC = totalPC + (addedPC or 0)
        totalCC = totalCC + (addedCC or 0)
        totalRemovedPC  = totalRemovedPC  + (removedPC  or 0)
        totalRemovedCC1 = totalRemovedCC1 + (removedCC1 or 0)
        log(string.format("Item #%d: removed PC=%d, removed CC1=%d, inserted PCs=%d, CC1=%d",
          itidx+1, removedPC or 0, removedCC1 or 0, addedPC or 0, addedCC or 0))
      end
    end
  end

  reaper.Undo_EndBlock("Articulation & Dynamics -> PC & CC1 (raw stream)", -1)
  log(string.format("=== DONE. Removed PCs=%d, Removed CC1=%d, Inserted PCs=%d, CC1=%d ===",
    totalRemovedPC, totalRemovedCC1, totalPC, totalCC))
  --show_toast_from_log()
end

main()