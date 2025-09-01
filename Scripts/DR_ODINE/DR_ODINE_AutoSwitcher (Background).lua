-- @description DR_ODINE_AutoSwitcher
-- @author DR_ODINE  
-- @version 1.0
-- @provides [main] DR_ODINE_AutoSwitcher (Background).lua
-- @about
--   # DR_ODINE_AutoSwitcher
--   
--   Automatically switches between mapped and unmapped modes based on instrument presets.
--   Monitors tracks for preset changes and configures Dr_ODINE Notation Translator JSFX accordingly.
-- DR_ODINE_AutoSwitcher — with Note Shortener toggle support

----------------- CONFIG -----------------
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
local SLOTS_PATH = ARTICMAPS_DIR .. "DR_ODINE_Maps_Slots.ini"
local JSFX_NAME_MATCH      = "DR_ODINE_Translator"      -- substring to find the Key Switch JSFX
local SHORTENER_NAME_MATCH = "Note Shortener" -- substring to find Note Shortener JSFX
local MAP_SLOT_PARAM       = 0                -- JSFX slider1
local PASSTHRU_PARAM       = 1                -- JSFX slider2
local UNMAPPED_MODE_PARAM  = 10               -- JSFX slider11
local SHORTENER_ENABLE_PARAM = 6              -- Shortener JSFX slider7
local SLOT_MAX             = 31               -- 0..31
local DEBUG                = false
------------------------------------------

-- utils
local function trim(s) return (s or ""):gsub("^%s+",""):gsub("%s+$","") end
local function norm(s) s = trim(s):lower(); return s:gsub("[^%w]+","") end
local function read_file(p) local f=io.open(p,"rb"); if not f then return nil end local t=f:read("*a"); f:close(); return t end
local function split_kv(line) local k,v=line:match("^%s*([^=]+)%s*=%s*(.-)%s*$"); if k then return trim(k),trim(v) end end

-- roman/digit tail normalization
local function roman_tail_to_digit(s)
  local rmap = {["viii"]="8",["vii"]="7",["vi"]="6",["ix"]="9",["iv"]="4",["iii"]="3",["ii"]="2",["x"]="10",["v"]="5",["i"]="1"}
  for r,d in pairs(rmap) do local head=s:match("^(.-)"..r.."$"); if head then return head..d end end
  return s
end
local function digit_tail_to_roman(s)
  local dmap = {["10"]="x",["9"]="ix",["8"]="viii",["7"]="vii",["6"]="vi",["5"]="v",["4"]="iv",["3"]="iii",["2"]="ii",["1"]="i"}
  local head = s:match("^(.-)(10)$"); if head then return head..dmap["10"] end
  local h,d = s:match("^(.-)(%d)$"); if h and dmap[d] then return h..dmap[d] end
  return s
end

-- registry
local function load_registry(path)
  local txt = read_file(path); if not txt then return nil,"No slots registry: "..path end
  local normidx, inst2slot, slots = {}, {}, {}
  local sec=nil
  for line in txt:gmatch("[^\r\n]+") do
    line = trim(line)
    if line=="" or line:match("^;") or line:match("^#") then goto cont end
    local s = line:match("^%[(.-)%]$")
    if s then sec=s:lower(); goto cont end
    local k,v = split_kv(line); if not k then goto cont end
    if     sec=="slots"              then slots[k]=tonumber(v)
    elseif sec=="instrument_to_slot" then inst2slot[k]=tonumber(v)
    elseif sec=="normidx"            then normidx[norm(k)]=tonumber(v)
    end
    ::cont::
  end
  return {slots=slots, inst2slot=inst2slot, nidx=normidx}
end

local REG,ERR = load_registry(SLOTS_PATH)
if not REG then reaper.MB(ERR, "DR_ODINE_Maps AutoSwitcher", 0) return end

-- match logic
local function best_match_slot(REG, preset_raw)
  if not preset_raw or preset_raw=="" then return nil,"empty" end
  local preset = trim(preset_raw)

  if REG.inst2slot[preset] then return REG.inst2slot[preset], "exact" end

  local pnorm = norm(preset)
  if REG.nidx[pnorm] then return REG.nidx[pnorm], "norm" end

  local p_r2d = roman_tail_to_digit(pnorm)
  if REG.nidx[p_r2d] then return REG.nidx[p_r2d], "rom→dig" end
  local p_d2r = digit_tail_to_roman(pnorm)
  if REG.nidx[p_d2r] then return REG.nidx[p_d2r], "dig→rom" end

  local best_slot, best_len = nil, 0
  for k,slot in pairs(REG.nidx) do
    if k~="" then
      if pnorm:find(k,1,true) or k:find(pnorm,1,true)
         or p_r2d:find(k,1,true) or k:find(p_r2d,1,true)
         or p_d2r:find(k,1,true) or k:find(p_d2r,1,true)
      then
        local L=#k; if L>best_len then best_len, best_slot = L, slot end
      end
    end
  end
  if best_slot then return best_slot, "substring" end
  return nil, "no-match"
end

-- FX helpers
local function find_fx(track, match)
  local fxcount = reaper.TrackFX_GetCount(track)
  for fx=0,fxcount-1 do
    local ok, name = reaper.TrackFX_GetFXName(track, fx, "")
    if ok and name and name:lower():find(match:lower(), 1, true) then
      return fx
    end
  end
  return nil
end

local function get_instrument_preset(track)
  local fx = reaper.TrackFX_GetInstrument(track)
  if fx == -1 then return nil,nil end
  local ok, preset = reaper.TrackFX_GetPreset(track, fx)
  if ok and preset and preset~="" then return trim(preset), fx end
  local _, fxname = reaper.TrackFX_GetFXName(track, fx, "")
  return trim(fxname), fx
end

local function set_param_norm(track, fx, param_idx, normv)
  reaper.TrackFX_SetParamNormalized(track, fx, param_idx, math.max(0, math.min(1, normv or 0)))
end

local function set_slot_param(track, fx, slot)
  slot = math.max(0, math.min(SLOT_MAX, slot or 0))
  set_param_norm(track, fx, MAP_SLOT_PARAM, slot / SLOT_MAX)
end

-- main loop
local function tick()
  for i=0, reaper.CountTracks(0)-1 do
    local tr = reaper.GetTrack(0, i)
    local ks_fx = find_fx(tr, JSFX_NAME_MATCH)
    local short_fx = find_fx(tr, SHORTENER_NAME_MATCH)

    if ks_fx then
      local preset = select(1, get_instrument_preset(tr))
      local want_slot = best_match_slot(REG, preset)

      if want_slot and want_slot >= 0 then
        -- Mapped
        set_slot_param(tr, ks_fx, want_slot)
        set_param_norm(tr, ks_fx, UNMAPPED_MODE_PARAM, 0.0)
        set_param_norm(tr, ks_fx, PASSTHRU_PARAM,      0.0)
        if short_fx then set_param_norm(tr, short_fx, SHORTENER_ENABLE_PARAM, 0.0) end
      else
        -- Unmapped
        set_param_norm(tr, ks_fx, UNMAPPED_MODE_PARAM, 1.0)
        set_param_norm(tr, ks_fx, PASSTHRU_PARAM,      1.0)
        if short_fx then set_param_norm(tr, short_fx, SHORTENER_ENABLE_PARAM, 1.0) end
      end
    end
  end
  reaper.defer(tick)
end

reaper.defer(tick)
