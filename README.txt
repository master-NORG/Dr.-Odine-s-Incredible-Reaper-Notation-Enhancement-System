# Dr. Odine's Incredible Reaper Notation Enhancement System v1.0

## Overview
A comprehensive orchestral template system for REAPER that automatically handles articulation switching and dynamics processing for orchestral libraries. It provides intelligent mapping between text articulations and MIDI events (Program Changes, CC1, velocities).

## Features
- **Automatic Articulation Switching**: Converts text events to keyswitches/program changes
- **Dynamic Dynamics Processing**: Handles crescendos, diminuendos, and accents
- **Mapped/Unmapped Modes**: Works with configured libraries or provides intelligent fallback
- **Background Automation**: Auto-arm tracks, cursor sync, preset switching
- **Cross-Platform**: Works on Windows, Mac, and Linux

## Installation via ReaPack

### 1. Add Repository
1. Open REAPER
2. Go to **Extensions → ReaPack → Import repositories**
3. Add this URL: https://raw.githubusercontent.com/master-NORG/Dr.-Odine-s-Incredible-Reaper-Notation-Enhancement-System/refs/heads/main/index.xml
4. Click **OK**

### 2. Install Packages
1. Go to **Extensions → ReaPack → Browse packages**
2. Search for "DR_ODINE" 
3. Install the packages you need:
   - **ArticMaps Core** (required)
   - **Background Scripts** (recommended)
   - **MIDI Editor Tools** (optional)

### 3. Initial Setup
1. Run **Scripts → DR_ODINE → DR_ODINE_ArticMaps Loader.lua** once to initialize
2. The system will create `REAPER/DR_ODINE Maps/` folder automatically
3. Edit `ArticMaps.ini` to configure your instruments (optional)

## Manual Installation

### File Structure
```
REAPER/
├── Scripts/
│   ├── DR_ODINE/
│   │   ├── ArticPC.lua
│   │   ├── AutoSwitcher.lua  
│   │   ├── Loader.lua
│   │   ├── Auto-Arm Track (Background).lua
│   │   ├── Cursor to Selection (Background).lua
│   │   ├── Preset Browse.lua
│   │   └── Toggle All_Target Track.lua
│   └── MIDI Editor/
│       ├── Delete and Move Playback.lua
│       ├── dotted_notes.lua
│       └── cfillion_Step sequencing (replace mode).lua
├── Effects/
│   └── DR_ODINE/
│       ├── Key Switch (gmem).jsfx
│       └── Unmapped Note Shortener.jsfx
└── ArticMaps/
    └── ArticMaps.ini
```

## Usage

### Basic Workflow
1. **Load JSFX**: Add "DR_ODINE_Key Switch (gmem)" and optionally "Note Shortener" to instrument tracks
2. **Start Background Scripts**: Run DR_ODINE_AutoSwitcher and DR_ODINE_Auto-Arm Track scripts
3. **Write Music**: Use text events for articulations (sustain, staccato, legato, etc.) and dynamics (pp, mf, f, etc.)
4. **Process**: Run DR_ODINE_ArticPC.lua to convert text to MIDI events

### Text Event Format
- **Articulations**: `articulation.sustain`, `articulation.staccato`, `articulation.legato`
- **Dynamics**: `dynamic.pp`, `dynamic.mf`, `dynamic.f`, `dynamic.ff`
- **Special**: `crescendo`, `diminuendo`, `articulation.accent`

### Configuration
Edit `REAPER/DR_ODINE Maps/ArticMaps.ini` to:
- Define instrument mappings
- Set keyswitch assignments  
- Configure channel routing
- Add new articulations

## Key Scripts

### Core Processing
- **ArticPC.lua**: Main processor (text → PC/CC1)
- **Dynamics to Velocity**: Alternative velocity-based processing
- **Loader.lua**: Initialize system and load maps

### Background Automation  
- **AutoSwitcher.lua**: Auto-switch mapped/unmapped modes
- **Auto-Arm Track.lua**: Smart track arming
- **Cursor to Selection.lua**: MIDI editor cursor sync

### MIDI Editing
- **Delete and Move Playback.lua**: Delete notes and move cursor
- **dotted_notes.lua**: Make selected notes dotted
- **Step sequencing**: Advanced step input with replace mode

### Utilities
- **Preset Browse.lua**: VSTi preset browser
- **Toggle All_Target Track.lua**: Smart track selection

## Troubleshooting

### Common Issues
1. **"No preset file found"**: Save some presets for your VSTi in REAPER first
2. **"No maps found"**: Run Loader.lua to initialize the system  
3. **Scripts not working**: Check that file paths are correct and JSFX are loaded

### Getting Help
- Check REAPER console for error messages
- Verify ArticMaps.ini syntax
- Ensure JSFX are properly loaded on tracks

## Customization
The system is highly customizable through:
- INI file configuration
- JSFX parameter adjustment
- Script modification for specific workflows

## Credits
- **Core System**: DR_ODINE
- **Step Sequencing**: Based on cfillion's original script
- **Concept**: Designed for professional orchestral template workflows, making the notation editor actually usable for composing with
notation with articulation, performance variations, and dynamics
---
For more information and updates: https://github.com/master-NORG/Dr.-Odine-s-Incredible-Reaper-Notation-Enhancement-System