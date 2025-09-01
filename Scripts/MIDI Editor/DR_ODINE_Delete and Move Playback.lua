-- @description DR_ODINE_Delete Selected MIDI Notes and Move Cursor
-- @author DR_ODINE
-- @version 1.0
-- @provides [main=midi_editor] DR_ODINE_Delete and Move Playback.lua
-- @about
--   # Delete Selected MIDI Notes and Move Cursor
--   
--   Deletes selected MIDI notes and moves cursor to first note position.

-- Delete Selected MIDI Notes and Move Cursor to First Note Position
-- ReaScript for Reaper by Claude

function main()
    -- Start undo block
    reaper.Undo_BeginBlock()
    
    -- Get the active MIDI editor
    local midi_editor = reaper.MIDIEditor_GetActive()
    if not midi_editor then
        return
    end
    
    -- Get the active take in the MIDI editor
    local take = reaper.MIDIEditor_GetTake(midi_editor)
    if not take then
        return
    end
    
    -- Variables to track the first selected note
    local first_note_pos = nil
    local notes_deleted = 0
    
    -- Get the number of MIDI events in the take
    local _, num_notes, _, _ = reaper.MIDI_CountEvts(take)
    
    -- Loop through all notes backwards to avoid index shifting issues when deleting
    for i = num_notes - 1, 0, -1 do
        local retval, selected, muted, start_pos, end_pos, chan, pitch, vel = reaper.MIDI_GetNote(take, i)
        
        if retval and selected then
            -- Store the position of the first selected note (earliest in time)
            if not first_note_pos or start_pos < first_note_pos then
                first_note_pos = start_pos
            end
            
            -- Delete the selected note
            reaper.MIDI_DeleteNote(take, i)
            notes_deleted = notes_deleted + 1
        end
    end
    
    if notes_deleted > 0 then
        -- Convert MIDI ticks to project time
        if first_note_pos then
            local project_time = reaper.MIDI_GetProjTimeFromPPQPos(take, first_note_pos)
            
            -- Move the edit cursor to the position of the first selected note
            reaper.SetEditCurPos(project_time, true, false)
        end
        
        -- Sort the MIDI events after deletion
        reaper.MIDI_Sort(take)
        
        -- Mark the item as changed
        local item = reaper.GetMediaItemTake_Item(take)
        reaper.UpdateItemInProject(item)
    end
    
    -- End undo block
    reaper.Undo_EndBlock("Delete Selected Notes and Move Cursor", -1)
end

-- Run the main function
main()