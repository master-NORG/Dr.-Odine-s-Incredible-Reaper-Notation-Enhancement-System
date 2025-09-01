-- @description DR_ODINE_MIDI Note Selection Cursor Sync (Background)
-- @author DR_ODINE
-- @version 1.0
-- @provides [main] DR_ODINE_Cursor to Selection (Background).lua
-- @about
--   # MIDI Note Selection Cursor Sync
--   
--   Moves cursor to the start position of selected MIDI notes.
--   Runs in background with step-input detection.

-- MIDI Note Selection Cursor Sync (Toggleable with Debug)
-- Moves cursor to the start position of selected MIDI notes
-- Runs in background with minimal CPU impact

local script_name = "MIDI Note Selection Cursor Sync"
local update_interval = 0.05 -- Reduced to 50ms for more responsive detection
local last_cursor_pos = -1
local last_selection_hash = ""
local last_play_state = -1
local debug_mode = false -- Set to true for console debugging
local last_external_cursor_pos = nil
local last_external_cursor_time = 0
local cursor_move_threshold = 0.2 -- If cursor moved externally recently, likely step-input

function debug_print(msg)
    if debug_mode then
        reaper.ShowConsoleMsg(msg .. "\n")
    end
end

function is_step_input_active()
    -- Check if cursor was moved externally (not by our script) recently
    local current_time = reaper.time_precise()
    local time_since_external_move = current_time - last_external_cursor_time
    
    -- If cursor moved externally very recently, likely step-input
    if time_since_external_move < cursor_move_threshold then
        debug_print(string.format("Step-input detected: external cursor move %.3f seconds ago", time_since_external_move))
        return true
    end
    
    return false
end

-- Check if script is already running
local ext_section = "midi_cursor_sync"
local ext_key = "is_running"
local is_running = reaper.GetExtState(ext_section, ext_key) == "1"

function cleanup()
    -- Set state to not running when script stops
    reaper.SetExtState(ext_section, ext_key, "0", false)
    debug_print("Script stopped")
end

function toggle_script()
    if is_running then
        -- Script is running, stop it
        reaper.SetExtState(ext_section, ext_key, "0", false)
        reaper.ShowMessageBox("MIDI Cursor Sync: OFF", "Status", 0)
        return -- Exit script
    else
        -- Script is not running, start it
        reaper.SetExtState(ext_section, ext_key, "1", false)
        --reaper.ShowMessageBox("MIDI Cursor Sync: ON\n\nSet debug_mode = true in script for console output", "Status", 0)
        is_running = true
    end
end

function is_midi_editor_focused()
    -- Check if any MIDI editor window is open and focused
    local midi_editor = reaper.MIDIEditor_GetActive()
    return midi_editor ~= nil
end

function get_selected_tracks()
    -- Get all selected tracks in the project
    local selected_tracks = {}
    local track_count = reaper.CountTracks(0)
    
    for track_idx = 0, track_count - 1 do
        local track = reaper.GetTrack(0, track_idx)
        if reaper.IsTrackSelected(track) then
            table.insert(selected_tracks, track)
        end
    end
    
    debug_print(string.format("Found %d selected tracks", #selected_tracks))
    return #selected_tracks, selected_tracks
end

function get_most_recent_selection_track(selected_tracks)
    -- Find which track has the most recently selected notes
    -- This is a simplified approach - we'll use the track with selected notes that has the highest GUID
    -- In practice, this is hard to detect perfectly, so we'll use a heuristic
    
    local track_note_counts = {}
    
    for _, track in ipairs(selected_tracks) do
        local item_count = reaper.CountTrackMediaItems(track)
        local selected_note_count = 0
        
        for item_idx = 0, item_count - 1 do
            local item = reaper.GetTrackMediaItem(track, item_idx)
            local take = reaper.GetActiveTake(item)
            
            if take and reaper.TakeIsMIDI(take) then
                local retval, note_count = reaper.MIDI_CountEvts(take)
                
                for note_idx = 0, note_count - 1 do
                    local retval, selected, muted, start_ppq, end_ppq, chan, pitch, vel = 
                        reaper.MIDI_GetNote(take, note_idx)
                    if selected then
                        selected_note_count = selected_note_count + 1
                    end
                end
            end
        end
        
        if selected_note_count > 0 then
            track_note_counts[track] = selected_note_count
        end
    end
    
    -- Return the track with the most selected notes (simple heuristic for "most recent")
    local best_track = nil
    local max_notes = 0
    for track, count in pairs(track_note_counts) do
        if count > max_notes then
            max_notes = count
            best_track = track
        end
    end
    
    return best_track
end

function get_selected_notes_earliest_pos()
    local earliest_pos = nil
    local selection_data = {}
    local notes_found = 0
    
    -- Check how many tracks are selected in the project
    local selected_track_count, selected_tracks = get_selected_tracks()
    local single_track_mode = (selected_track_count == 1)
    
    if single_track_mode then
        debug_print("Single track selected - only considering notes from selected track")
    else
        debug_print(string.format("Multi-track mode - %d tracks selected, considering all selected notes", selected_track_count))
    end
    
    -- Create a lookup table for selected tracks for faster checking
    local selected_track_lookup = {}
    for _, track in ipairs(selected_tracks) do
        selected_track_lookup[track] = true
    end
    
    -- Iterate through all tracks
    local track_count = reaper.CountTracks(0)
    for track_idx = 0, track_count - 1 do
        local track = reaper.GetTrack(0, track_idx)
        
        -- Skip this track if we're in single-track mode and this isn't a selected track
        if single_track_mode and not selected_track_lookup[track] then
            goto continue
        end
        
        -- Iterate through all media items on track
        local item_count = reaper.CountTrackMediaItems(track)
        for item_idx = 0, item_count - 1 do
            local item = reaper.GetTrackMediaItem(track, item_idx)
            local take = reaper.GetActiveTake(item)
            
            if take and reaper.TakeIsMIDI(take) then
                local retval, note_count = reaper.MIDI_CountEvts(take)
                
                -- Check each note in the MIDI take
                for note_idx = 0, note_count - 1 do
                    local retval, selected, muted, start_ppq, end_ppq, chan, pitch, vel = 
                        reaper.MIDI_GetNote(take, note_idx)
                    
                    if selected then
                        notes_found = notes_found + 1
                        -- Convert PPQ to absolute project time
                        local absolute_pos = reaper.MIDI_GetProjTimeFromPPQPos(take, start_ppq)
                        
                        -- Additional validation - ensure position is reasonable
                        if absolute_pos and absolute_pos >= 0 then
                            -- Track selection for hash (include take info for uniqueness)
                            local take_guid = reaper.BR_GetMediaItemTakeGUID(take)
                            local track_guid = reaper.GetTrackGUID(track)
                            table.insert(selection_data, string.format("%.6f_%d_%d_%s_%s", absolute_pos, chan, pitch, take_guid or "", track_guid))
                            
                            -- Find earliest position
                            if not earliest_pos or absolute_pos < earliest_pos then
                                earliest_pos = absolute_pos
                            end
                        end
                    end
                end
            end
        end
        ::continue::
    end
    
    -- Create hash of current selection
    table.sort(selection_data)
    local selection_hash = table.concat(selection_data, "|")
    
    debug_print(string.format("Found %d selected notes, earliest: %s", notes_found, earliest_pos and string.format("%.6f", earliest_pos) or "none"))
    
    return earliest_pos, selection_hash
end

function main()
    -- Check if we should still be running
    local current_state = reaper.GetExtState(ext_section, ext_key)
    if current_state ~= "1" then
        -- Script has been toggled off, clean up and exit
        cleanup()
        return
    end
    
    local current_play_state = reaper.GetPlayState()
    local play_state_changed = (current_play_state ~= last_play_state)
    last_play_state = current_play_state
    
    -- Only run the selection checking if MIDI editor is focused AND not playing
    if not is_midi_editor_focused() or current_play_state ~= 0 then
        -- Reset tracking when MIDI editor is not focused or during playback
        if current_play_state ~= 0 and debug_mode then
            debug_print("Skipping - playback active")
        end
        last_selection_hash = ""
        last_cursor_pos = -1
        reaper.defer(main)
        return
    end
    
    -- Small delay after playback stops to ensure MIDI state is stable
    if play_state_changed and current_play_state == 0 then
        debug_print("Playback just stopped, waiting for state to stabilize...")
        reaper.defer(main)
        return
    end
    
    local current_cursor_pos = reaper.GetCursorPosition()
    local earliest_note_pos, selection_hash = get_selected_notes_earliest_pos()
    
    -- Track external cursor movements (not caused by our script)
    if last_external_cursor_pos and 
       math.abs(current_cursor_pos - last_external_cursor_pos) > 0.001 and
       current_cursor_pos ~= last_cursor_pos then
        -- Cursor moved, but not to where we last set it - external movement
        last_external_cursor_time = reaper.time_precise()
        debug_print(string.format("External cursor movement detected: %.6f", current_cursor_pos))
    end
    last_external_cursor_pos = current_cursor_pos
    
    -- Skip cursor movement if step-input is likely active
    if is_step_input_active() then
        debug_print("Skipping cursor movement - step-input mode detected")
        -- Still update selection tracking to avoid issues when step-input ends
        if selection_hash ~= last_selection_hash then
            last_selection_hash = selection_hash
        end
        reaper.defer(main)
        return
    end
    
    -- Only debug when something interesting happens
    local selection_changed = (selection_hash ~= last_selection_hash)
    if debug_mode and selection_changed then
        debug_print(string.format("Selection changed! Cursor: %.6f, New earliest: %s", 
            current_cursor_pos, earliest_note_pos and string.format("%.6f", earliest_note_pos) or "none"))
        debug_print(string.format("Old hash: %s", last_selection_hash:sub(1, 50)))
        debug_print(string.format("New hash: %s", selection_hash:sub(1, 50)))
    end
    
    -- Only move cursor if:
    -- 1. There are selected notes
    -- 2. Selection has changed (NEW selection only)
    -- 3. Cursor is not already at the target position (with larger tolerance for cross-track selections)
    local position_tolerance = 0.01 -- Increased tolerance for better cross-track detection
    if earliest_note_pos and 
       selection_hash ~= last_selection_hash and
       selection_hash ~= "" and
       math.abs(current_cursor_pos - earliest_note_pos) > position_tolerance then
        
        debug_print(string.format("Moving cursor from %.6f to %.6f", current_cursor_pos, earliest_note_pos))
        reaper.SetEditCurPos(earliest_note_pos, false, false)
        last_cursor_pos = earliest_note_pos
        last_selection_hash = selection_hash
    elseif earliest_note_pos and selection_hash ~= last_selection_hash and selection_hash ~= "" then
        -- Selection changed but cursor is already close to target position
        debug_print(string.format("Selection changed but cursor already at target (%.6f vs %.6f)", current_cursor_pos, earliest_note_pos))
        last_selection_hash = selection_hash
    elseif not earliest_note_pos then
        -- No notes selected, reset tracking
        if last_selection_hash ~= "" and debug_mode then
            debug_print("No notes selected, resetting")
        end
        last_selection_hash = ""
        last_cursor_pos = -1
    elseif selection_hash ~= last_selection_hash then
        -- Selection changed but cursor move not needed, still update tracking
        debug_print("Selection changed but no cursor move needed")
        last_selection_hash = selection_hash
    end
    
    -- Schedule next run
    reaper.defer(main)
end

-- Initialize and start
reaper.atexit(cleanup)
toggle_script()
if is_running then
    main()
end