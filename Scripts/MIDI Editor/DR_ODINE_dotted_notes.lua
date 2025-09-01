-- @description DR_ODINE_Dot Selected Notes
-- @author DR_ODINE
-- @version 1.0
-- @provides [main=midi_editor] DR_ODINE_dotted_notes.lua
-- @about
--   # Dot Selected Notes
--   
--   Makes selected MIDI notes dotted (increases length by 50%).

-- ReaScript: Dot Selected Notes
-- Makes selected MIDI notes dotted (increases length by 50%)
-- Author: Custom Script
-- Version: 1.0

function main()
    -- Get the active MIDI editor
    local hwnd = reaper.MIDIEditor_GetActive()
    if not hwnd then
        reaper.ShowMessageBox("No active MIDI editor found!", "Error", 0)
        return
    end
    
    -- Get the take being edited
    local take = reaper.MIDIEditor_GetTake(hwnd)
    if not take then
        reaper.ShowMessageBox("No MIDI take found in editor!", "Error", 0)
        return
    end
    
    -- Count total notes and selected notes
    local _, num_notes = reaper.MIDI_CountEvts(take)
    local selected_count = 0
    
    -- First pass: count selected notes
    for i = 0, num_notes - 1 do
        local _, selected = reaper.MIDI_GetNote(take, i)
        if selected then
            selected_count = selected_count + 1
        end
    end
    
    if selected_count == 0 then
        reaper.ShowMessageBox("No notes selected!", "Info", 0)
        return
    end
    
    -- Begin undo block
    reaper.Undo_BeginBlock()
    
    -- Process selected notes (work backwards to avoid index issues)
    local processed_count = 0
    local cursor_advance = 0
    
    for i = num_notes - 1, 0, -1 do
        local retval, selected, muted, startppq, endppq, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
        
        if selected then
            -- Calculate dotted length (original length * 1.5)
            local original_length = endppq - startppq
            local dotted_length = math.floor(original_length * 1.5 + 0.5) -- Round to nearest integer
            local new_endppq = startppq + dotted_length
            
            -- Calculate the extension amount (the "dot" part = 50% of original)
            local extension = dotted_length - original_length
            
            -- Track the maximum extension for cursor movement
            if extension > cursor_advance then
                cursor_advance = extension
            end
            
            -- Set the new note length
            reaper.MIDI_SetNote(take, i, selected, muted, startppq, new_endppq, chan, pitch, vel, false)
            processed_count = processed_count + 1
        end
    end
    
    -- Move cursor forward by the extension amount
    if cursor_advance > 0 then
        local current_pos = reaper.GetCursorPosition()
        local ppq_per_beat = reaper.MIDI_GetPPQPosFromProjTime(take, current_pos + 60/reaper.Master_GetTempo()) - reaper.MIDI_GetPPQPosFromProjTime(take, current_pos)
        local time_advance = reaper.MIDI_GetProjTimeFromPPQPos(take, reaper.MIDI_GetPPQPosFromProjTime(take, current_pos) + cursor_advance) - current_pos
        reaper.SetEditCurPos(current_pos + time_advance, true, true)
    end
    
    -- Refresh the MIDI editor
    reaper.MIDI_Sort(take)
    
    -- End undo block
    reaper.Undo_EndBlock("Dot Selected Notes", -1)
    
    -- Completion message removed for silent operation
end

-- Run the script
main()