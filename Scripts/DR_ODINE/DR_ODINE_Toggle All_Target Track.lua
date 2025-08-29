-- @description DR_ODINE_Smart MIDI Track Selector  
-- @author DR_ODINE
-- @version 1.0
-- @provides [main] DR_ODINE_Toggle All_Target Track.lua
-- @about
--   # DR_ODINE_Smart MIDI Track Selector
--   
--   Toggles between all tracks selected and MIDI editor target track only.

-- Smart MIDI Track Selector
-- If all tracks are selected: select only the MIDI input target track
-- If not all tracks are selected: select all tracks

-- Function to get track name with fallback
function GetTrackName(track, track_number)
    local retval, track_name = reaper.GetSetMediaTrackInfo_String(track, "P_NAME", "", false)
    if track_name == "" then
        return "Track " .. track_number
    else
        return track_name
    end
end

-- Function to get track number from track pointer
function GetTrackNumber(target_track)
    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        if track == target_track then
            return i + 1
        end
    end
    return -1
end

-- Function to check if all tracks are selected
function AreAllTracksSelected()
    local track_count = reaper.CountTracks(0)
    if track_count == 0 then
        return false
    end
    
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        if not reaper.IsTrackSelected(track) then
            return false
        end
    end
    return true
end

-- Function to select all tracks
function SelectAllTracks()
    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        reaper.SetTrackSelected(track, true)
    end
end

-- Function to deselect all tracks
function DeselectAllTracks()
    local track_count = reaper.CountTracks(0)
    for i = 0, track_count - 1 do
        local track = reaper.GetTrack(0, i)
        reaper.SetTrackSelected(track, false)
    end
end

-- Function to select only the MIDI input target track
function SelectMIDITargetTrack()
    -- Check if MIDI editor is open
    local midi_editor = reaper.MIDIEditor_GetActive()
    
    if not midi_editor then
        return false
    end
    
    -- Get the active take (this is the target for MIDI input)
    local active_take = reaper.MIDIEditor_GetTake(midi_editor)
    
    if not active_take then
        return false
    end
    
    -- Get the track that contains this take
    local target_track = reaper.GetMediaItemTake_Track(active_take)
    
    if not target_track then
        return false
    end
    
    -- Deselect all tracks first
    DeselectAllTracks()
    
    -- Select only the target track
    reaper.SetTrackSelected(target_track, true)
    
    return true
end

-- Main execution
function main()
    local track_count = reaper.CountTracks(0)
    
    if track_count == 0 then
        return
    end
    
    if AreAllTracksSelected() then
        -- All tracks are selected, so select only the MIDI input target track
        SelectMIDITargetTrack()
    else
        -- Not all tracks are selected, so select all tracks
        SelectAllTracks()
    end
    
    -- Update the track list and arrange view
    reaper.TrackList_AdjustWindows(false)
    reaper.UpdateArrange()
end

-- Execute the script
reaper.Undo_BeginBlock()
main()
reaper.Undo_EndBlock("Smart MIDI Track Selector", -1)