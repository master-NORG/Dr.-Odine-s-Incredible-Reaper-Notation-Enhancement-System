-- @description DR_ODINE_VSTi Preset Browser
-- @author DR_ODINE
-- @version 1.0
-- @provides [main] DR_ODINE_Preset Browser.lua
-- @about
--   # DR_ODINE_VSTi Preset Browser
--   
--   Scrollable, searchable preset browser for any VSTi with saved REAPER presets.

--[[
Preset Browser (scrollable) for VSTi on selected track
- Dynamically reads preset names from REAPER preset .ini files
- Shows a searchable, scrollable list
- Double-click a preset to load it (or press Enter)
- Targets the INSTRUMENT (first VSTi) on the SELECTED track
- Works with any VSTi that has presets saved in REAPER

Tested: REAPER 7.x, Lua
]]--

local function msg(s) reaper.ShowConsoleMsg((s or "").."\n") end

-- Resolve instrument (VSTi) on selected track
local tr = reaper.GetSelectedTrack(0,0)
if not tr then reaper.MB("Select a track with your instrument (VSTi).","Preset Browser",0) return end
local fx = reaper.TrackFX_GetInstrument(tr)
if fx < 0 then reaper.MB("No instrument (VSTi) found on the selected track.","Preset Browser",0) return end

-- Dynamic preset file detection
local function get_preset_file_for_plugin(tr, fx)
    -- Try multiple methods to get the plugin name
    local fx_name = reaper.TrackFX_GetFXName(tr, fx, "")
    local fx_name_buf = ""
    
    -- Alternative method if first one fails
    if type(fx_name) ~= "string" or fx_name == "" then
        local retval, buf = reaper.TrackFX_GetFXName(tr, fx, fx_name_buf)
        if retval and buf and buf ~= "" then
            fx_name = buf
        end
    end
    
    -- Check if we got a valid string
    if type(fx_name) ~= "string" or fx_name == "" then 
        return nil, "Unknown Plugin"
    end
    
    -- Extract clean plugin name - handle different formats
    local clean_name = fx_name
    
    -- Remove VST type prefixes: "VST3i: ", "VST2: ", "VST: ", etc.
    clean_name = clean_name:gsub("^VST[23]?i?:%s*", "")
    
    -- Remove everything in parentheses (like manufacturer info)
    clean_name = clean_name:gsub("%s*%([^%)]*%)%s*", "")
    
    -- Trim whitespace
    clean_name = clean_name:gsub("^%s+", ""):gsub("%s+$", "")
    
    -- Try different possible preset file formats
    local preset_dir = reaper.GetResourcePath() .. "/presets/"
    local possible_files = {
        preset_dir .. "vst3-" .. clean_name .. ".ini",
        preset_dir .. "vst2-" .. clean_name .. ".ini", 
        preset_dir .. "vst-" .. clean_name .. ".ini",
        preset_dir .. clean_name .. ".ini"
    }
    
    for _, path in ipairs(possible_files) do
        local f = io.open(path, "r")
        if f then 
            f:close()
            return path, clean_name
        end
    end
    
    return nil, clean_name
end

local PRESET_FILE, plugin_name = get_preset_file_for_plugin(tr, fx)
if not PRESET_FILE then
    -- Get plugin name for error message (with safe handling)
    local fx_name = reaper.TrackFX_GetFXName(tr, fx, "")
    if type(fx_name) ~= "string" then fx_name = "Unknown Plugin" end
    
    reaper.MB("No preset file found for: " .. (plugin_name or fx_name) .. "\n\n" ..
              "Expected locations:\n" ..
              reaper.GetResourcePath() .. "/presets/" .. (plugin_name or "PluginName") .. ".ini\n" ..
              reaper.GetResourcePath() .. "/presets/vst3-" .. (plugin_name or "PluginName") .. ".ini\n\n" ..
              "Make sure you have saved some presets for this plugin in REAPER first.", "Preset Browser", 0)
    return
end

-- Parse [PresetN] Name=... from the .ini file
local list = {}  -- { {index=0, name="..."}, ... }   index is 0-based (REAPER preset index)
do
  local f = io.open(PRESET_FILE,"r")
  local current_idx = nil
  for line in f:lines() do
    local idx = line:match("^%[Preset(%d+)%]")
    if idx then current_idx = tonumber(idx) end
    local nm = line:match("^Name=(.+)")
    if nm and current_idx then list[#list+1] = {index=current_idx, name=nm} end
  end
  f:close()
  table.sort(list, function(a,b) return a.index < b.index end)
end

if #list == 0 then
  reaper.MB("No presets parsed from:\n"..PRESET_FILE.."\n\nMake sure it contains [PresetN] sections with Name=... entries.\n\nTip: Save some presets for this plugin in REAPER first.","Preset Browser",0)
  return
end

-- ---------- GFX UI ----------
local W,H = 520,640
gfx.init("Preset Browser - " .. (plugin_name or "Plugin"), W, H)

-- UI state
local search = ""
local filtered = list
local row_h = 22
local pad = 10
local search_h = 28
local footer_h = 18
local bar_w = 12 -- scrollbar width
local sel = 1 -- 1-based index into filtered
local top_row = 0 -- integer offset (0-based) of first visible row
local last_mouse_down = false
local last_click_time, last_click_row = 0, -1
local dragging_bar = false
local drag_bar_offset = 0
local user_scrolled = false -- Track if user manually scrolled

-- Helpers
local function clamp(v,a,b) if v<a then return a elseif v>b then return b else return v end end
local function set_font()
  gfx.setfont(1, "Arial", 16)
end
local function set_font_small()
  gfx.setfont(2, "Arial", 12)
end

local function refilter()
  local q = search:lower()
  if q == "" then
    filtered = list
  else
    filtered = {}
    for _,it in ipairs(list) do
      if it.name:lower():find(q, 1, true) then table.insert(filtered, it) end
    end
  end
  if #filtered == 0 then sel = 0 else sel = clamp(sel, 1, #filtered) end
  top_row = clamp(top_row, 0, math.max(0, #filtered - 1))
end

local function ensure_sel_visible(visible_rows)
  -- Only auto-scroll to selection if user hasn't manually scrolled
  if user_scrolled then return end
  if sel < 1 or #filtered == 0 then return end
  if sel-1 < top_row then top_row = sel-1 end
  if sel-1 >= top_row + visible_rows then top_row = sel-1 - visible_rows + 1 end
end

local function draw_rect(x,y,w,h) gfx.rect(x,y,w,h,1) end
local function draw_outlined_rect(x,y,w,h) gfx.rect(x,y,w,h,0) end

local function load_selected()
  if sel < 1 or sel > #filtered then return end
  local idx = filtered[sel].index -- 0-based
  reaper.Undo_BeginBlock()
  reaper.TrackFX_SetPresetByIndex(tr, fx, idx)
  reaper.Undo_EndBlock("Load instrument preset: "..(filtered[sel].name or ""), -1)
  
  -- Close the browser window after loading
  gfx.quit()
end

local function handle_keyboard()
  -- getchars returns one char at a time; loop to consume all queued input
  while true do
    local c = gfx.getchar()
    if c == 0 then break end
    if c == -1 then return false end -- window closed
    if c == 27 then return false end -- ESC closes
    if c == 13 then -- Enter
      load_selected()
    elseif c == 8 then -- Backspace
      search = search:sub(1, #search-1)
      refilter()
    elseif c == 30064 or c == 328 then
      -- Up (REAPER returns 30064 on mac/win in many builds; 328 is another code seen)
      sel = clamp(sel-1, 1, #filtered)
      user_scrolled = false -- Reset when using keyboard nav
    elseif c == 1685026670 or c == 336 then
      -- Down (varies by platform/build)
      sel = clamp(sel+1, 1, #filtered)
      user_scrolled = false -- Reset when using keyboard nav
    elseif c >= 32 and c <= 126 then
      search = search .. string.char(c)
      refilter()
    end
  end
  return true
end

local function handle_mouse(list_x, list_y, list_w, list_h, visible_rows)
  local mx, my, cap = gfx.mouse_x, gfx.mouse_y, gfx.mouse_cap
  local ldown = (cap & 1) == 1
  local wheel = gfx.mouse_wheel or 0

  -- Mouse wheel scroll
  if wheel ~= 0 then
    local step = (wheel > 0) and -3 or 3
    top_row = clamp(top_row + step, 0, math.max(0, #filtered - visible_rows))
    user_scrolled = true -- Mark that user has manually scrolled
    gfx.mouse_wheel = 0
  end

  -- Scrollbar geometry
  local sb_x = list_x + list_w
  local sb_y = list_y
  local sb_h = list_h
  local sb_w = bar_w

  local total_rows = #filtered
  local max_top = math.max(0, total_rows - visible_rows)
  local handle_h = math.max(20, math.floor(sb_h * math.min(1, visible_rows / math.max(1, total_rows))))
  local handle_y = sb_y
  if max_top > 0 and total_rows > visible_rows then
    handle_y = sb_y + math.floor((top_row / max_top) * (sb_h - handle_h))
  end

  local total_rows = #filtered
  local max_top = math.max(0, total_rows - visible_rows)

  -- Calculate handle size - make sure we use the same calculation as drawing
  local handle_h = 30 -- default minimum
  if total_rows > visible_rows then
    local handle_ratio = visible_rows / total_rows
    handle_h = math.max(30, math.min(sb_h * 0.8, math.floor(sb_h * handle_ratio)))
  end
  
  local handle_y = sb_y
  if max_top > 0 and total_rows > visible_rows then
    handle_y = sb_y + math.floor((top_row / max_top) * (sb_h - handle_h))
  end

  -- Scrollbar dragging
  if dragging_bar then
    if not ldown then
      dragging_bar = false
    else
      local new_y = my - drag_bar_offset
      new_y = clamp(new_y, sb_y, sb_y + sb_h - handle_h)
      if (sb_h - handle_h) > 0 then
        local ratio = (new_y - sb_y) / (sb_h - handle_h)
        top_row = clamp(math.floor(ratio * max_top + 0.5), 0, max_top)
      end
    end
  else
    if ldown and not last_mouse_down then
      -- Check if clicking on scrollbar area
      if mx >= sb_x and mx <= sb_x + sb_w and my >= sb_y and my <= sb_y + sb_h then
        -- Only allow interaction if scrolling is needed
        if total_rows > visible_rows then
          -- Check if clicking specifically on the handle
          if my >= handle_y and my <= handle_y + handle_h then
            dragging_bar = true
            drag_bar_offset = my - handle_y
          else
            -- Clicking on track - jump to position
            local click_ratio = clamp((my - sb_y) / sb_h, 0, 1)
            top_row = clamp(math.floor(click_ratio * max_top), 0, max_top)
          end
        end
      end
    end
  end

  -- Click in list
  if mx >= list_x and mx <= list_x + list_w and my >= list_y and my <= list_y + list_h then
    if ldown and not last_mouse_down then
      local row = math.floor((my - list_y) / row_h) + 1
      local idx = top_row + row
      if idx >= 1 and idx <= #filtered then
        -- select
        sel = idx
        user_scrolled = false -- Reset when clicking on items
        -- double-click detection
        local now = reaper.time_precise()
        if last_click_row == sel and (now - last_click_time) < 0.30 then
          load_selected()
        end
        last_click_time, last_click_row = now, sel
      end
    end
  end

  last_mouse_down = ldown
end

local function draw()
  gfx.set(0.12,0.12,0.12,1)  draw_rect(0,0,gfx.w,gfx.h) -- background

  -- Search box
  local x = pad
  local y = pad
  local w = gfx.w - pad*2
  set_font()
  gfx.set(0.2,0.2,0.2,1); draw_rect(x, y, w, search_h)
  gfx.set(1,1,1,1); draw_outlined_rect(x, y, w, search_h)
  gfx.x = x + 8; gfx.y = y + (search_h-16)/2
  gfx.drawstr("Search: "..search)

  -- List area
  local list_x = pad
  local list_y = y + search_h + 6
  local list_w = gfx.w - pad*2 - bar_w
  local list_h = gfx.h - list_y - pad - footer_h

  -- Visible rows
  local visible_rows = math.max(1, math.floor(list_h / row_h))
  ensure_sel_visible(visible_rows)

  -- Items
  set_font()
  local start_idx = top_row + 1
  local end_idx = math.min(#filtered, start_idx + visible_rows - 1)
  
  for row = 0, (end_idx - start_idx) do
    local idx = start_idx + row
    local it = filtered[idx]
    local iy = list_y + row * row_h
    local isSel = (idx == sel)

    if isSel then
      gfx.set(0.28,0.45,0.80,1) -- selection bg
      draw_rect(list_x, iy, list_w, row_h)
      gfx.set(1,1,1,1)
    else
      gfx.set(0.9,0.9,0.9,1)
    end

    gfx.x = list_x + 8; gfx.y = iy + (row_h-16)/2
    local label = string.format("%3d  %s", it.index, it.name or "")
    gfx.drawstr(label)
  end

  -- Scrollbar
  local sb_x = list_x + list_w
  local sb_y = list_y
  local sb_h = list_h
  gfx.set(0.18,0.18,0.18,1); draw_rect(sb_x, sb_y, bar_w, sb_h)
  gfx.set(0.5,0.5,0.5,1); draw_outlined_rect(sb_x, sb_y, bar_w, sb_h)

  local total_rows = #filtered
  local max_top = math.max(0, total_rows - visible_rows)
  
  -- Only show scrollbar if there are more items than visible
  if total_rows <= visible_rows then
    -- No scrolling needed - don't draw scrollbar handle
    gfx.set(0.18,0.18,0.18,1); draw_rect(sb_x, sb_y, bar_w, sb_h)
    gfx.set(0.5,0.5,0.5,1); draw_outlined_rect(sb_x, sb_y, bar_w, sb_h)
  else
    -- Calculate handle size - ensure it's not too big or too small
    local handle_ratio = visible_rows / total_rows
    local handle_h = math.max(30, math.min(sb_h * 0.8, math.floor(sb_h * handle_ratio)))
    
    local handle_y = sb_y
    if max_top > 0 then
      handle_y = sb_y + math.floor((top_row / max_top) * (sb_h - handle_h))
    end
    
    -- Draw scrollbar
    gfx.set(0.18,0.18,0.18,1); draw_rect(sb_x, sb_y, bar_w, sb_h)
    gfx.set(0.5,0.5,0.5,1); draw_outlined_rect(sb_x, sb_y, bar_w, sb_h)
    gfx.set(0.65,0.65,0.65,1); draw_rect(sb_x+2, handle_y+2, bar_w-4, handle_h-4)
  end

  -- Footer with status
  set_font_small()
  gfx.set(1,1,1,0.8)
  gfx.x = pad; gfx.y = gfx.h - footer_h
  local status = string.format("Plugin: %s • Showing %d of %d presets • Double-click to load • Enter loads • ESC closes", 
                               plugin_name or "Unknown", #filtered, #list)
  gfx.drawstr(status)

  gfx.update()
end

local function mainloop()
  if not handle_keyboard() then return end
  
  -- Calculate layout first
  local list_x = pad
  local list_y = pad + search_h + 6
  local list_w = gfx.w - pad*2 - bar_w
  local list_h = gfx.h - list_y - pad - footer_h
  local visible_rows = math.max(1, math.floor(list_h / row_h))
  
  -- Handle mouse interactions
  handle_mouse(list_x, list_y, list_w, list_h, visible_rows)
  
  -- Always try to ensure selection is visible (but can be overridden by user_scrolled)
  ensure_sel_visible(visible_rows)
  
  -- Draw everything
  draw()
  
  reaper.defer(mainloop)
end

-- Initial filter + go
refilter()
mainloop()