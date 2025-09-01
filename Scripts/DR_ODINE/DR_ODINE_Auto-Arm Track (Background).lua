-- @description DR_ODINE_Auto-Arm Track (Background)
-- @author DR_ODINE
-- @version 1.0
-- @provides [main] DR_ODINE_Auto-Arm Track (Background).lua
-- @about
--   # Auto-Arm Track (Background)
--   
--   Continuously monitors track selection and manages record-arming.
--   Single track selected: arms that track, disarms all others.
--   Multiple tracks selected: checks MIDI editor note input track, arms only that one.

-- Track Selection Record Arm Script
-- Continuously monitors track selection and manages record-arming
-- Single track selected: arms that track, disarms all others
-- Multiple tracks selected: checks MIDI editor note input track, arms only that one
-- If MIDI editor closed with multiple selected: disarms all tracks

local last_selection_hash = ""
local last_midi_target_track = nil
local script_should_run = true

function get_selection_hash()
    -- Create a hash of currently selected tracks to detect changes
    local hash = ""
    local track_count = reaper.CountTracks(0)
    
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        if reaper.IsTrackSelected(track) then
            hash = hash .. tostring(i) .. ","
        end
    end
    
    return hash
end

function get_selected_tracks()
    -- Get all currently selected tracks
    local selected_tracks = {}
    local track_count = reaper.CountTracks(0)
    
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        if reaper.IsTrackSelected(track) then
            table.insert(selected_tracks, track)
        end
    end
    
    return selected_tracks
end

function disarm_all_tracks()
    -- Disarm all tracks in the project
    local track_count = reaper.CountTracks(0)
    
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 0)
    end
end

function arm_track(track)
    -- Arm a specific track for recording
    reaper.SetMediaTrackInfo_Value(track, "I_RECARM", 1)
end

function get_midi_editor_note_input_track()
    -- Get the track selected for note input in the MIDI editor
    local midi_editor = reaper.MIDIEditor_GetActive()
    
    if not midi_editor then
        return nil -- MIDI editor is not open
    end
    
    -- Get the active take (this is the target for MIDI input)
    local active_take = reaper.MIDIEditor_GetTake(midi_editor)
    
    if not active_take then
        return nil
    end
    
    -- Get the track that contains this take
    local target_track = reaper.GetMediaItemTake_Track(active_take)
    
    return target_track
end

function process_track_selection()
    local selected_tracks = get_selected_tracks()
    local num_selected = #selected_tracks
    
    if num_selected == 0 then
        -- No tracks selected, disarm all
        disarm_all_tracks()
        
    elseif num_selected == 1 then
        -- Single track selected: arm it, disarm all others
        disarm_all_tracks()
        arm_track(selected_tracks[1])
        
    else
        -- Multiple tracks selected
        local midi_note_input_track = get_midi_editor_note_input_track()
        
        -- Always disarm all tracks first
        disarm_all_tracks()
        
        if midi_note_input_track ~= nil then
            -- Check if the MIDI editor note input track is among selected tracks
            local should_arm_midi_track = false
            
            for _, selected_track in ipairs(selected_tracks) do
                if selected_track == midi_note_input_track then
                    should_arm_midi_track = true
                    break
                end
            end
            
            if should_arm_midi_track then
                arm_track(midi_note_input_track)
            end
        end
        -- If MIDI editor is closed or note input track not in selection, 
        -- all tracks remain disarmed (as per requirements)
    end
end

function main()
    -- Check if we should continue running
    if not script_should_run then
        return
    end
    
    -- Get current selection state
    local current_selection_hash = get_selection_hash()
    local current_midi_target_track = get_midi_editor_note_input_track()
    
    -- Check if selection has changed OR MIDI target track has changed
    local selection_changed = current_selection_hash ~= last_selection_hash
    local midi_target_changed = current_midi_target_track ~= last_midi_target_track
    
    -- Only process if something relevant has changed
    if selection_changed or midi_target_changed then
        last_selection_hash = current_selection_hash
        last_midi_target_track = current_midi_target_track
        
        process_track_selection()
        
        -- Update the arrange view to reflect changes
        reaper.UpdateArrange()
    end
    
    -- Schedule next run
    reaper.defer(main)
end

function exit()
    script_should_run = false
end

-- Register exit function
reaper.atexit(exit)

-- Start the script
main()