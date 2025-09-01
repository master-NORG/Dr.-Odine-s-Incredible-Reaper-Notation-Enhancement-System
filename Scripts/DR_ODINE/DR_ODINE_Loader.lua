-- @description DR_ODINE_Loader
-- @author DR_ODINE
-- @version 1.0
-- @provides
--   [data] DR_ODINE_Maps.ini > DR_ODINE Maps/
--   [main] DR_ODINE_Loader.lua
-- @about
--   # DR_ODINE Loader
--   
--   Preloads all maps to gmem and writes slots registry.
--   Run this first to initialize the ArticMaps system.
--   
-- DR_ODINE_Loader — Preload all maps to gmem + write slots registry
-- Loads maps into slots (0..N) and writes DR_ODINE_Maps_Slots.ini (map->slot, instrument->map, instrument->slot)
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
local INI_PATH = ARTICMAPS_DIR .. "DR_ODINE_Maps.ini"  
local SLOTS_PATH = ARTICMAPS_DIR .. "DR_ODINE_Maps_Slots.ini"
local GMEM_NAME = "DR_ODINE_Maps"
local BLOCK = 1024         -- MUST match JSFX
local VERSION = 1
local SLOT_START = 0       -- first slot to use
------------------------------------------

local function log(...) reaper.ShowConsoleMsg((string.format(...)).."\n") end
reaper.ClearConsole()

-- helpers
local function trim(s) return (s:gsub("^%s+",""):gsub("%s+$","")) end
local function norm(s) s = s:lower(); return s:gsub("[^%w]+","") end
local function read_file(p) local f=io.open(p,"rb"); if not f then return nil end local t=f:read("*a"); f:close(); return t end
local function write_file(p,t) local f=io.open(p,"wb"); if not f then return false,"Cannot write "..p end f:write(t); f:close(); return true end
local function split_kv(line) local k,v=line:match("^%s*([^=]+)%s*=%s*(.-)%s*$"); if k then return trim(k),trim(v) end end

-- note name to number (C-2 = 0)
local NOTE_IDX = {c=0,["c#"]=1,db=1,d=2,["d#"]=3,eb=3,e=4,f=5,["f#"]=6,gb=6,g=7,["g#"]=8,ab=8,a=9,["a#"]=10,bb=10,b=11}
local function note_to_num(tok)
  tok = tok:gsub("%s+","")
  local n,acc,oct = tok:match("^([A-Ga-g])([#b]?)(%-?%d+)$"); if not n then return nil end
  local k = (n:lower())..acc
  local semi = NOTE_IDX[k]; if not semi then return nil end
  local o = tonumber(oct); if not o then return nil end
  local v = (o+2)*12 + semi
  if v < 0 or v > 127 then return nil end
  return v
end

-- parse pc spec like: "off" | "note=C0 [ch=1] [len=25] [vel=100]" | "cc=32 val=3" | "pc=12"
local function parse_pc_spec(spec)
  spec = spec:lower()
  if spec=="off" then return {typ=0} end
  local t = {typ=0,p1=0,p2=0,ch=0,len=0}
  for key,val in spec:gmatch("([%w_]+)%s*=%s*([^%s]+)") do
    key = key:lower()
    if key=="note" then
      local n = note_to_num(val) or tonumber(val)
      if not n then return nil,"Bad note: "..tostring(val) end
      t.typ=1; t.p1=n
    elseif key=="cc" then
      local n = tonumber(val); if not n or n<0 or n>127 then return nil,"Bad CC" end
      t.typ=2; t.p1=n
    elseif key=="val" or key=="value" or key=="vel" then
      local n = tonumber(val); if not n or n<0 or n>127 then return nil,"Bad val/vel" end
      t.p2=n
    elseif key=="pc" then
      local n = tonumber(val); if not n or n<0 or n>127 then return nil,"Bad PC" end
      t.typ=3; t.p1=n
    elseif key=="ch" or key=="channel" then
      local n = tonumber(val); if not n or n<0 or n>16 then return nil,"Bad ch" end
      t.ch=n
    elseif key=="len" or key=="len_ms" then
      local n = tonumber(val); if not n or n<0 then return nil,"Bad len" end
      t.len=n
    end
  end
  return t
end

-- Parse INI
local function parse_ini(txt)
  local maps, instruments = {}, {}
  local curT, curN
  for line in txt:gmatch("[^\r\n]+") do
    line = trim(line)
    if line=="" or line:match("^;") or line:match("^#") then goto cont end
    local sec = line:match("^%[(.-)%]$")
    if sec then
      local t,n = sec:match("^(%w+)%s*:%s*(.+)$")
      curT, curN = t and t:lower() or nil, n and trim(n) or nil
      if curT=="map" and not maps[curN] then maps[curN]={def_ch=1,def_len_ms=30,pc={}} end
      if curT=="instrument" and not instruments[curN] then instruments[curN]={use=nil} end
      goto cont
    end
    if not curT or not curN then goto cont end
    local k,v = split_kv(line); if not k then goto cont end
    k=k:lower()
    if curT=="map" then
      if k=="channel" then maps[curN].def_ch = math.max(1, math.min(16, tonumber(v) or 1))
      elseif k=="len_ms" then maps[curN].def_len_ms = math.max(1, tonumber(v) or 30)
      elseif k=="bank" then local a,b=v:match("^(%d+)%s*:%s*(%d+)$"); if a then maps[curN].bankMSB=tonumber(a) maps[curN].bankLSB=tonumber(b) end
      elseif k:sub(1,3)=="pc." then
        local n = tonumber(k:sub(4)); if n and n>=0 and n<=127 then
          local rec,err = parse_pc_spec(v); if not rec then return nil,err end
          maps[curN].pc[n] = rec
        end
      end
    elseif curT=="instrument" then
      if k=="use" then instruments[curN].use = trim(v) end
    end
    ::cont::
  end
  return maps, instruments
end

-- choose maps to load (all referenced by instruments first, then any extra maps)
local function assign_slots(maps, instruments)
  local needed = {} -- set of maps referenced by instruments
  for inst,obj in pairs(instruments) do if obj.use and maps[obj.use] then needed[obj.use]=true end end
  local list = {}
  for m,_ in pairs(needed) do list[#list+1]=m end
  table.sort(list) -- deterministic
  local has = {}; for _,m in ipairs(list) do has[m]=true end
  for m,_ in pairs(maps) do if not has[m] then list[#list+1]=m end end
  -- assign
  local slots = {}
  local slot = SLOT_START
  for _,m in ipairs(list) do slots[m]=slot; slot=slot+1 end
  return slots, list
end

-- write one map into a slot
-- inside your existing write_map_to_slot(slot, map, ...)
local function write_map_to_slot(slot, map, map_name)
  local base = slot*BLOCK
  reaper.gmem_write(base+2, 0) -- commit=0

  reaper.gmem_write(base+0, 0xA17C)
  reaper.gmem_write(base+1, VERSION)
  reaper.gmem_write(base+3, map.def_ch or 1)
  reaper.gmem_write(base+4, map.def_len_ms or 30)

  -- [NEW] write map title at base+650
  local title = tostring(map_name or "")
  local L = math.min(#title, (BLOCK-651))  -- stay in-block
  reaper.gmem_write(base+650, L)
  for i=1,L do
    reaper.gmem_write(base+650+i, string.byte(title, i))
  end
  -- optional: clear a little tail
  for i=L+1,L+32 do reaper.gmem_write(base+650+i, 0) end

  -- clear & fill pc table as before...
  local ptr = base+10
  for i=0,127 do
    for k=0,4 do reaper.gmem_write(ptr+k, 0) end
    ptr = ptr + 5
  end
  for n,rec in pairs(map.pc) do
    local p = base+10 + n*5
    reaper.gmem_write(p+0, rec.typ or 0)
    reaper.gmem_write(p+1, rec.p1 or 0)
    reaper.gmem_write(p+2, rec.p2 or 0)
    reaper.gmem_write(p+3, rec.ch or 0)
    reaper.gmem_write(p+4, rec.len or 0)
  end

  reaper.gmem_write(base+2, 1) -- commit=1
end


-- MAIN
local txt = read_file(INI_PATH)
if not txt then reaper.MB("Cannot read INI:\n"..INI_PATH, "ArticMaps Loader", 0) return end
local maps, instruments = parse_ini(txt)
if not maps then reaper.MB("Parse error in INI.", "ArticMaps Loader", 0) return end

-- attach gmem
reaper.gmem_attach(GMEM_NAME)

-- assign and write
local slots, ordered = assign_slots(maps, instruments)
local wrote = 0
for _, mname in ipairs(ordered) do
  local slot = slots[mname]
  write_map_to_slot(slot, maps[mname], mname)  -- pass name
end


-- build registry text
local out = {}
out[#out+1] = ("[meta]\ngenerated=%s\nversion=%d\n"):format(os.date("!%Y-%m-%dT%H:%M:%SZ"), VERSION)

out[#out+1] = "\n[slots]\n"
for _,mname in ipairs(ordered) do
  out[#out+1] = ("%s=%d\n"):format(mname, slots[mname])
end

out[#out+1] = "\n[instrument_to_map]\n"
for inst,obj in pairs(instruments) do
  if obj.use and maps[obj.use] then
    out[#out+1] = ("%s=%s\n"):format(inst, obj.use)
  end
end

out[#out+1] = "\n[instrument_to_slot]\n"
for inst,obj in pairs(instruments) do
  local map = obj.use
  local slot = map and slots[map]
  if slot then
    out[#out+1] = ("%s=%d\n"):format(inst, slot)
  end
end

-- normalized lookup (case/spacing-insensitive)
out[#out+1] = "\n[normidx]\n"
for inst,_ in pairs(instruments) do
  local nkey = norm(inst)
  local map = instruments[inst].use
  local slot = map and slots[map] or -1
  out[#out+1] = ("%s=%d\n"):format(nkey, slot)
end

local ok,err = write_file(SLOTS_PATH, table.concat(out))
if not ok then reaper.MB("Failed to write registry:\n"..tostring(err), "ArticMaps Loader", 0) end

--uncomment this if you want to have the popup confirm the maps loaded at startup

--reaper.MB(("Loaded %d maps into slots %d..%d\nRegistry: %s"):format(
  --wrote, SLOT_START, SLOT_START + wrote - 1, SLOTS_PATH), "ArticMaps Loader", 0)
