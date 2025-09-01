-- @description DR_ODINE_Step sequencing (replace mode)
-- @author cfillion, modified by DR_ODINE
-- @version 1.1.4
-- @provides [main=midi_editor] DR_ODINE_Step sequencing (replace mode).lua
-- @screenshot
--   Inserting and replacing notes https://i.imgur.com/4azf7CN.gif
--   Options menu https://i.imgur.com/YFHLRWM.png
-- @donation https://reapack.com/donate
-- @about
--   ## Step sequencing (replace mode)
--
--   This script is an alternative to the native step recording feature. Existing notes under the edit cursor are replaced (lowest first). The MIDI editor's active note row is updated as new notes are played.
--
--   An options action is provided to individually toggle replacing channel/pitch/velocity and skipping unselected notes.
--
--   Note that this script automatically inserts and removes an helper JSFX in the active track's input FX chain in order to receive live MIDI input.

local ImGui
if reaper.ImGui_GetBuiltinPath then
  package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'
  ImGui = require 'imgui' '0.9'
end

local MB_OK = 0
local MIDI_EDITOR_SECTION = 32060
local NATIVE_STEP_RECORD  = 40481
local NOTE_BUFFER_START   = 1

local EXT_SECTION = 'DR_ODINE_stepRecordReplace'
local EXT_MODE_KEY = 'mode'

local MODE_CHAN  = 1<<0
local MODE_PITCH = 1<<1
local MODE_VEL   = 1<<2
local MODE_SEL   = 1<<3

local UNDO_STATE_FX    = 1<<1
local UNDO_STATE_ITEMS = 1<<2

local jsfx
local jsfxName = 'ReaTeam Scripts/MIDI Editor/cfillion_Step sequencing (replace mode).jsfx'
local scriptName, scriptSection, scriptId = select(2, reaper.get_action_context())
scriptName = scriptName:match("([^/\\_]+)%.lua$")
local debug = false

local function printf(...)
  if debug then
    reaper.ShowConsoleMsg(string.format(...))
  end
end

-- returns the active midi take and the editor handle
local function getActiveTake()
  local me = reaper.MIDIEditor_GetActive()

  if me then
    return reaper.MIDIEditor_GetTake(me), me
  end
end

-- something to do with namespace

local function getMode()
  local mode

  if reaper.HasExtState(EXT_SECTION, EXT_MODE_KEY) then
    mode = tonumber(reaper.GetExtState(EXT_SECTION, EXT_MODE_KEY))
  end

  if not mode then
    mode = MODE_CHAN | MODE_PITCH | MODE_VEL
  end

  return mode
end

-- sets the current project (in case you are working on multiple projects in Reaper)
local function projects()
  local i = -1

  return function()
    i = i + 1
    return reaper.EnumProjects(i)
  end
end

local function findJSFX()
  local i, offset = 0, 0x1000000
  local guid = reaper.TrackFX_GetFXGUID(jsfx.track, offset + i)

  while guid do
    if guid == jsfx.guid then
      return i
    end

    i = i + 1
    guid = reaper.TrackFX_GetFXGUID(jsfx.track, offset + i)
  end
end

local function findNotesAtTime(take, ppqTime, onlySelected)
  local notes, ni = {}, onlySelected and -1 or 0

  while true do
    if onlySelected then
      ni = reaper.MIDI_EnumSelNotes(take, ni)
      if ni < 0 then break end
    end

    local note = {reaper.MIDI_GetNote(take, ni)}
    if not note[1] then break end

    note[1] = ni
    if not onlySelected then
      ni = ni + 1
    end

    if note[4] <= ppqTime and note[5] > ppqTime then
      table.insert(notes, note)
    end
  end

  -- sort notes by ascending pitch
  table.sort(notes, function(a, b) return a[7] < b[7] end)

  return notes
end

-- NEW: Find notes that start within a time range (start to end)
-- Only deletes notes that START at or after ppqStart, not notes that were already playing
local function findNotesInRange(take, ppqStart, ppqEnd, onlySelected)
  local notes, ni = {}, onlySelected and -1 or 0

  while true do
    if onlySelected then
      ni = reaper.MIDI_EnumSelNotes(take, ni)
      if ni < 0 then break end
    end

    local note = {reaper.MIDI_GetNote(take, ni)}
    if not note[1] then break end

    note[1] = ni
    if not onlySelected then
      ni = ni + 1
    end

    -- Only include notes that START within our range
    -- This excludes notes that started before ppqStart (even if they extend into our range)
    if note[4] >= ppqStart and note[4] < ppqEnd then
      table.insert(notes, note)
    end
  end

  -- sort notes by ascending pitch
  table.sort(notes, function(a, b) return a[7] < b[7] end)

  return notes
end

local function findNextSelNotePos(take, ni, ppqTime)
  while true do
    ni = reaper.MIDI_EnumSelNotes(take, ni)
    if ni < 0 then break end

    local note = {reaper.MIDI_GetNote(take, ni)}
    if not note[1] then break end

    if note[4] > ppqTime then
      return note[4]
    end
  end
end

local function getParentProject(track)
  local search = reaper.GetMediaTrackInfo_Value(track, 'P_PROJECT')

  for project in projects() do
    local master = reaper.GetMasterTrack(project)
    if search == reaper.GetMediaTrackInfo_Value(master, 'P_PROJECT') then
      return project
    end
  end
end

local function updateJSFXCursor(ppq)
  local index = findJSFX()
  reaper.TrackFX_SetParam(jsfx.track, index | 0x1000000, 0, ppq)
  jsfx.ppqTime = ppq
end

local function teardownJSFX()
  if not jsfx or not reaper.ValidatePtr2(nil, jsfx.project, 'ReaProject*') or
    not reaper.ValidatePtr2(jsfx.project, jsfx.track, 'MediaTrack*') then return end

  local index = findJSFX()
  if index then
    reaper.TrackFX_Delete(jsfx.track, index | 0x1000000)
  end

  jsfx = nil
end

local function installJSFX(take)
  local track = reaper.GetMediaItemTake_Track(take)
  if jsfx and track == jsfx.track then return true end

  local project = getParentProject(track)
  reaper.Undo_BeginBlock2(project)

  teardownJSFX()

  local index = reaper.TrackFX_AddByName(track, jsfxName, true, 1)
  jsfx = {
    guid  = reaper.TrackFX_GetFXGUID(track, index | 0x1000000),
    project = project,
    track = track,
  }
  reaper.gmem_write(0, NOTE_BUFFER_START)

  -- Initialize JSFX with current cursor position for undo.
  local curPos = reaper.GetCursorPositionEx(project)
  local ppqTime = reaper.MIDI_GetPPQPosFromProjTime(take, curPos)
  updateJSFXCursor(ppqTime)

  reaper.Undo_EndBlock2(jsfx.project,
    'Install step sequencing (replace mode) input FX', UNDO_STATE_FX)

  return index >= 0
end

local function readNoteBuffer()
  local chords = {}

  local bi = NOTE_BUFFER_START
  local be = reaper.gmem_read(0) - 1
  local function nextIndex()
    local i = bi
    bi = bi + 1
    return i
  end

  while bi < be do
    local noteSize  = 4
    local noteCount = reaper.gmem_read(nextIndex()) / noteSize
    printf("received chord\tnotes=%s\n", noteCount)

    local notes = {}
    for ni = 1, noteCount do
      local note = {
        chan   = reaper.gmem_read(nextIndex()),
        pitch  = reaper.gmem_read(nextIndex()),
        vel    = reaper.gmem_read(nextIndex()),
        isDown = reaper.gmem_read(nextIndex()), -- unused
      }

      printf(">\tnote %d\tchan=%s vel=%s\n", note.pitch, note.chan, note.vel)
      table.insert(notes, note)
    end

    table.sort(notes, function(a, b) return a.pitch < b.pitch end)
    table.insert(chords, notes)
  end

  reaper.gmem_write(0, NOTE_BUFFER_START)

  return chords
end

-- REPLACE the whole function with this:
local function insertReplaceNotes(take, newNotes)
  local updated = false
  local qnGrid = reaper.MIDI_GetGrid(take)
  local curPos = reaper.GetCursorPositionEx(jsfx.project)
  local ppqTime = reaper.MIDI_GetPPQPosFromProjTime(take, curPos)
  local mode = getMode()

  -- end of one grid unit from the cursor
  local qnTime = reaper.MIDI_GetProjQNFromPPQPos(take, ppqTime)
  local ppqEndByGrid = reaper.MIDI_GetPPQPosFromProjQN(take, qnTime + qnGrid)

  -- NEW: Find notes that overlap with the entire duration of the new note
  local notesToDelete = findNotesInRange(take, ppqTime, ppqEndByGrid, mode & MODE_SEL ~= 0)

  if ppqTime ~= jsfx.ppqTime then
    -- store current cursor position for proper undo behavior
    reaper.Undo_BeginBlock2(jsfx.project)
    updateJSFXCursor(ppqTime)
    reaper.Undo_EndBlock2(jsfx.project,
      'Move cursor before step sequencing input', UNDO_STATE_FX)
  end

  reaper.Undo_BeginBlock2(jsfx.project)

  -- 1) REMOVE all notes that overlap with the new note's duration
  if #notesToDelete > 0 then
    -- delete from highest index to lowest so indices don't shift
    table.sort(notesToDelete, function(a, b) return a[1] > b[1] end)
    for _, note in ipairs(notesToDelete) do
      reaper.MIDI_DeleteNote(take, note[1])
      updated = true
    end
  end

  -- 2) INSERT the new notes, each one grid unit long
  if #newNotes > 0 then
    for i = 1, #newNotes do
      local n = newNotes[i]
      reaper.MIDI_InsertNote(
        take,         -- take
        true,         -- selected
        false,        -- muted
        ppqTime,      -- start
        ppqEndByGrid, -- end (exactly one grid unit)
        n.chan,
        n.pitch,
        n.vel,
        true          -- noSort
      )
      updated = true
    end
  end

  -- 3) Finalize changes and move the cursor
  if updated then
    reaper.MIDI_Sort(take)
    -- move JSFX cursor param & edit cursor to the end of the new note (if any)
    local ppqNextTime = (#newNotes > 0) and ppqEndByGrid or ppqTime
    updateJSFXCursor(ppqNextTime)

    local item = reaper.GetMediaItemTake_Item(take)
    reaper.UpdateItemInProject(item)
    reaper.MarkTrackItemsDirty(jsfx.track, item)

    if ppqNextTime > ppqTime then
      local nextTime = reaper.MIDI_GetProjTimeFromPPQPos(take, ppqNextTime)
      reaper.SetEditCurPos2(jsfx.project, nextTime, false, false)
    end
  end

  reaper.Undo_EndBlock2(jsfx.project,
    'Insert notes via step sequencing (replace mode)',
    UNDO_STATE_FX | UNDO_STATE_ITEMS)
end



local function loop()
  local take, me = getActiveTake()
  if not take then
    reaper.defer(loop)
    teardownJSFX()
    return
  end

  if not installJSFX(take) then
    reaper.MB('Fatal error: Failed to install helper effect in the input chain.',
      scriptName, MB_OK)
    return
  end

  if 0 < reaper.GetToggleCommandStateEx(MIDI_EDITOR_SECTION, NATIVE_STEP_RECORD) then
    return -- terminate the script
  end

  local index = findJSFX()
  if not index then
    -- The JSFX instance we think is installed is invalid.  It was likely removed via
    -- undo. Terminate the script.
    return
  end
  local fxPPQTime = reaper.TrackFX_GetParam(jsfx.track, index | 0x1000000, 0)
  if fxPPQTime > -1 and jsfx.ppqTime and jsfx.ppqTime ~= fxPPQTime then
    -- Note insertion was undone.  Restore cursor position based on undo point.
    local curPos = reaper.GetCursorPositionEx(jsfx.project)
    local fxTime = reaper.MIDI_GetProjTimeFromPPQPos(take, fxPPQTime)
    reaper.MoveEditCursor(fxTime - curPos, false)
    jsfx.ppqTime = fxPPQTime
  end

  local chords, lastNote = readNoteBuffer()
  for _, newNotes in ipairs(chords) do
    insertReplaceNotes(take, newNotes)
    lastNote = newNotes[1]
  end

  if lastNote then
    reaper.MIDIEditor_SetSetting_int(me, 'active_note_row', lastNote.pitch)
  end

  reaper.defer(loop)
end

local function gfxdo(callback)
  local app = reaper.GetAppVersion()
  if app:match('OSX') or app:match('linux') then
    return callback()
  end

  local curx, cury = reaper.GetMousePosition()
  gfx.init("", 0, 0, 0, curx, cury)

  if reaper.JS_Window_SetStyle then
    local window = reaper.JS_Window_GetFocus()
    local winx, winy = reaper.JS_Window_ClientToScreen(window, 0, 0)
    gfx.x = gfx.x - (winx - curx)
    gfx.y = gfx.y - (winy - cury)
    reaper.JS_Window_SetStyle(window, "POPUP")
    reaper.JS_Window_SetOpacity(window, 'ALPHA', 0)
  end

  local value = callback()
  gfx.quit()
  return value
end

local function optionsMenu(mode, items)
  local ctx = ImGui.CreateContext(scriptName,
    ImGui.ConfigFlags_NavEnableKeyboard | ImGui.ConfigFlags_NoSavedSettings)

  local size = reaper.GetAppVersion():match('OSX') and 12 or 14
  local font = ImGui.CreateFont('sans-serif', size)
  ImGui.Attach(ctx, font)

  local function loop()
    if ImGui.IsWindowAppearing(ctx) then
      ImGui.SetNextWindowPos(ctx,
        ImGui.PointConvertNative(ctx, reaper.GetMousePosition()))
      ImGui.OpenPopup(ctx, scriptName)
    end

    if ImGui.BeginPopup(ctx, scriptName, ImGui.WindowFlags_TopMost) then
      ImGui.PushFont(ctx, font)

      for id, item in ipairs(items) do
        if type(item) == 'table' then
          if ImGui.MenuItem(ctx, item[2], nil, mode & item[1]) then
            mode = mode ~ item[1]
            reaper.SetExtState(EXT_SECTION, EXT_MODE_KEY, mode, true)
          end
        else
          ImGui.Separator(ctx)
        end
      end
      ImGui.PopFont(ctx)
      ImGui.EndPopup(ctx)
      reaper.defer(loop)
    end
  end

  reaper.defer(loop)
end

local function legacyOptionsMenu(mode, items)
  local menu, values = {}, {}

  for id, item in ipairs(items) do
    if type(item) == 'table' then
      local checkbox = mode & item[1] ~= 0 and '!' or ''
      table.insert(values, item[1])
      table.insert(menu, checkbox .. item[2])
    else
      table.insert(menu, item)
    end
  end

  local choice = gfx.showmenu(table.concat(menu, '|'))
  if not values[choice] then return end

  mode = mode ~ values[choice]
  reaper.SetExtState(EXT_SECTION, EXT_MODE_KEY, mode, true)
end

if scriptName:match('%(options%)') then
  local mode, items = getMode(), {
    {MODE_CHAN,  'Replace channel'},
    {MODE_PITCH, 'Replace pitch'},
    {MODE_VEL,   'Replace velocity'},
    '',
    {MODE_SEL,   'Skip unselected notes'},
  }

  if ImGui then
    optionsMenu(mode, items)
  else
    gfxdo(function() legacyOptionsMenu(mode, items) end)
  end

  return
end

if reaper.GetToggleCommandStateEx(scriptSection, scriptId) > 0 then
  return
end

if 0 < reaper.GetToggleCommandStateEx(MIDI_EDITOR_SECTION, NATIVE_STEP_RECORD) then
  reaper.MIDIEditor_LastFocused_OnCommand(NATIVE_STEP_RECORD, false)
end

reaper.gmem_attach('cfillion_stepRecordReplace')
reaper.SetToggleCommandState(scriptSection, scriptId, 1)
reaper.RefreshToolbar2(scriptSection, scriptId)
reaper.atexit(function()
  reaper.SetToggleCommandState(scriptSection, scriptId, 0)
  reaper.RefreshToolbar2(scriptSection, scriptId)
  teardownJSFX()
  reaper.gmem_write(0, 0) -- disable the global note buffer
end)

loop()