-- Timber Player
-- 1.0.0 Beta 7 @markeats
-- llllllll.co/t/timber
--
-- Trigger samples with a grid
-- or MIDI keyboard.
--
-- E1 : Page
-- K1+E1 : Sample slot
-- K1 (Hold) : Shift / Fine
--
-- GLOBAL PAGE:
--  K2 : Play / Stop
--  K3 : Load folder
--  K1+K3 : Add folder
--  E2 : BPM
--
-- SAMPLE PAGES:
--  K2 : Focus
--  K3 : Action
--  E2/3 : Params
--

local Timber = include("timber/lib/timber_engine")
local MusicUtil = require "musicutil"
local UI = require "ui"
local Formatters = require "formatters"
local BeatClock = require "beatclock"
local cube_midi
engine.name = "Timber"

local options = {}
options.OFF_ON = {"Off", "On"}
options.QUANTIZATION = {"None", "1/32", "1/24", "1/16", "1/12", "1/8", "1/6", "1/4", "1/3", "1/2", "1 bar"}
options.QUANTIZATION_DIVIDERS = {nil, 32, 24, 16, 12, 8, 6, 4, 3, 2, 1}

local SCREEN_FRAMERATE = 15
local screen_dirty = true
local GRID_FRAMERATE = 30
local grid_dirty = true
local grid_w, grid_h = 16, 8

local midi_in_device
local midi_clock_in_device
local midi_song_in_device
local grid_device

local NUM_SAMPLES = 52

local beat_clock
local note_queue = {}

local sample_status = {}
local STATUS = {
  STOPPED = 0,
  STARTING = 1,
  PLAYING = 2,
  STOPPING = 3
}
for i = 0, NUM_SAMPLES - 1 do sample_status[i] = STATUS.STOPPED end

local pages
local global_view
local sample_setup_view
local waveform_view
local filter_amp_view
local amp_env_view
local mod_env_view
local lfos_view
local mod_matrix_view

local current_sample_id = 0
local shift_mode = false
local file_select_active = false

-- Sequencer Settings
local sequins = require 'sequins'
local sequence_trigger_count = 10
local sequence_note_count = 8
local sequence_data = {}
local sequence_types = {"holder", "step back", "reset", "repeat"}

-- Gordey settings
local draw_song_name = false
local song_count = 10
local song_max_count = 100
local current_song = 1
local current_song_name = "--"
local current_pset_file = _path.data.."timber/player/player-01.pset"
local current_song_index = 1
local can_switch_song = false
local on_song_load_press = false
local songs_file = _path.data.."timber/songs.data"
local songs_data = {}

local function load_folder(file, add)
  
  local sample_id = 0
  if add then
    for i = NUM_SAMPLES - 1, 0, -1 do
      if Timber.samples_meta[i].num_frames > 0 then
        sample_id = i + 1
        break
      end
    end
  end
  
  Timber.clear_samples(sample_id, NUM_SAMPLES - 1)
  
  local split_at = string.match(file, "^.*()/")
  local folder = string.sub(file, 1, split_at)
  file = string.sub(file, split_at + 1)
  
  local found = false
  for k, v in ipairs(Timber.FileSelect.list) do
    if v == file then found = true end
    if found then
      if sample_id > 255 then
        print("Max files loaded")
        break
      end
      -- Check file type
      local lower_v = v:lower()
      if string.find(lower_v, ".wav") or string.find(lower_v, ".aif") or string.find(lower_v, ".aiff") or string.find(lower_v, ".ogg") then
        Timber.load_sample(sample_id, folder .. v)
        sample_id = sample_id + 1
      else
        print("Skipped", v)
      end
    end
  end
end

local function set_sample_id(id)
  current_sample_id = id
  while current_sample_id >= NUM_SAMPLES do current_sample_id = current_sample_id - NUM_SAMPLES end
  while current_sample_id < 0 do current_sample_id = current_sample_id + NUM_SAMPLES end
  sample_setup_view:set_sample_id(current_sample_id)
  waveform_view:set_sample_id(current_sample_id)
  filter_amp_view:set_sample_id(current_sample_id)
  amp_env_view:set_sample_id(current_sample_id)
  mod_env_view:set_sample_id(current_sample_id)
  lfos_view:set_sample_id(current_sample_id)
  mod_matrix_view:set_sample_id(current_sample_id)
end

local function id_to_x(id)
  return (id - 1) % grid_w + 1
end
local function id_to_y(id)
  return math.ceil(id / grid_w)
end

local function note_on(sample_id, vel)
  if Timber.samples_meta[sample_id].num_frames > 0 then
    -- print("note_on", sample_id)
    vel = vel or 1

    local mute_group = params:get("mute_group_" .. sample_id)
    if mute_group == -1  then
      mute_group = sample_id
    end

    engine.noteOn(mute_group, MusicUtil.note_num_to_freq(60), vel, sample_id)
    sample_status[sample_id] = STATUS.PLAYING
    global_view:add_play_visual()
    screen_dirty = true
    grid_dirty = true
  end
end

local function note_off(sample_id)
  -- print("note_off", sample_id)
  local mute_group = params:get("mute_group_" .. sample_id)
  if mute_group == -1  then
    mute_group = sample_id
  end

  engine.noteOff(mute_group)
  screen_dirty = true
  grid_dirty = true
end

local function clear_queue()
  
  for k, v in pairs(note_queue) do
    if Timber.samples_meta[v.sample_id].playing then
      sample_status[v.sample_id] = STATUS.PLAYING
    else
      sample_status[v.sample_id] = STATUS.STOPPED
    end
  end
  
  note_queue = {}
end

local function queue_note_event(event_type, sample_id, vel)
  
  local quant = options.QUANTIZATION_DIVIDERS[params:get("quantization_" .. sample_id)]
  if params:get("quantization_" .. sample_id) > 1 then
    
    -- Check for already queued
    for i = #note_queue, 1, -1 do
      if note_queue[i].sample_id == sample_id then
        if note_queue[i].event_type ~= event_type then
          table.remove(note_queue, i)
          if Timber.samples_meta[sample_id].playing then
            sample_status[sample_id] = STATUS.PLAYING
          else
            sample_status[sample_id] = STATUS.STOPPED
          end
          grid_dirty = true
        end
        return
      end
    end
    
    if event_type == "on" or sample_status[sample_id] == STATUS.PLAYING then
      if Timber.samples_meta[sample_id].num_frames > 0 then
        local note_event = {
          event_type = event_type,
          sample_id = sample_id,
          vel = vel,
          quant = quant
        }
        table.insert(note_queue, note_event)
        
        if event_type == "on" then
          sample_status[sample_id] = STATUS.STARTING
        else
          sample_status[sample_id] = STATUS.STOPPING
        end
      end
    end
    
  else
    if event_type == "on" then
      note_on(sample_id, vel)
    else
      note_off(sample_id)
    end
  end
  grid_dirty = true
end

local function note_off_all()
  engine.noteOffAll()
  clear_queue()
  screen_dirty = true
  grid_dirty = true
end

local function note_kill_all()
  engine.noteKillAll()
  clear_queue()
  screen_dirty = true
  grid_dirty = true
end

local function set_pressure_voice(voice_id, pressure)
  engine.pressureVoice(voice_id, pressure)
end

local function set_pressure_sample(sample_id, pressure)
  engine.pressureSample(sample_id, pressure)
end

local function set_pressure_all(pressure)
  engine.pressureAll(pressure)
end

local function set_pitch_bend_voice(voice_id, bend_st)
  engine.pitchBendVoice(voice_id, MusicUtil.interval_to_ratio(bend_st))
end

local function set_pitch_bend_sample(sample_id, bend_st)
  engine.pitchBendSample(sample_id, MusicUtil.interval_to_ratio(bend_st))
end

local function set_pitch_bend_all(bend_st)
  engine.pitchBendAll(MusicUtil.interval_to_ratio(bend_st))
end

local function key_down(sample_id, vel)
  
  if pages.index == 2 then
    sample_setup_view:sample_key(sample_id)
  end
  
  if params:get("launch_mode_" .. sample_id) == 1 then
    queue_note_event("on", sample_id, vel)
    
  else
    if (sample_status[sample_id] ~= STATUS.PLAYING and sample_status[sample_id] ~= STATUS.STARTING) or sample_status[sample_id] == STATUS.STOPPING then
      queue_note_event("on", sample_id, vel)
    else
      queue_note_event("off", sample_id)
    end
  end
  
end

local function key_up(sample_id)
  if params:get("launch_mode_" .. sample_id) == 1 and params:get("play_mode_" .. sample_id) ~= 4 then
    queue_note_event("off", sample_id)
  end
end


-- Clock callbacks

local function advance_step()
  
  local tick = (beat_clock.beat * 24) + beat_clock.step -- 0-95
  
  -- Fire quantized note on/offs
  for i = #note_queue, 1, -1 do
    local note_event = note_queue[i]
    if tick % (96 / note_event.quant) == 0 then
      if note_event.event_type == "on" then
        note_on(note_event.sample_id, note_event.vel)
      else
        note_off(note_event.sample_id)
      end
      table.remove(note_queue, i)
    end
  end
  
  -- Every beat
  if beat_clock.step == 0 then
    if pages.index == 1 then screen_dirty = true end
  end
end

local function stop()
  note_kill_all()
end


-- Encoder input
function enc(n, delta)
  
  -- Global
  if n == 1 then
    if shift_mode then
      if pages.index > 1 then
        set_sample_id(current_sample_id + delta)
      end
    else
      pages:set_index_delta(delta, false)
    end
  
  else
    
    if pages.index == 1 then
      global_view:enc(n, delta)
    elseif pages.index == 2 then
      sample_setup_view:enc(n, delta)
    elseif pages.index == 3 then
      waveform_view:enc(n, delta)
    elseif pages.index == 4 then
      filter_amp_view:enc(n, delta)
    elseif pages.index == 5 then
      amp_env_view:enc(n, delta)
    elseif pages.index == 6 then
      mod_env_view:enc(n, delta)
    elseif pages.index == 7 then
      lfos_view:enc(n, delta)
    elseif pages.index == 8 then
      mod_matrix_view:enc(n, delta)
    end
    
  end
  screen_dirty = true
end

-- Key input
function key(n, z)
  
  if n == 1 then
    
    -- Shift
    if z == 1 then
      shift_mode = true
      Timber.shift_mode = shift_mode
    else
      shift_mode = false
      Timber.shift_mode = shift_mode
    end
    
  else
    
    if pages.index == 1 then
      global_view:key(n, z)
    elseif pages.index == 2 then
      sample_setup_view:key(n, z)
    elseif pages.index == 3 then
      waveform_view:key(n, z)
    elseif pages.index == 4 then
      filter_amp_view:key(n, z)
    elseif pages.index == 5 then
      amp_env_view:key(n, z)
    elseif pages.index == 6 then
      mod_env_view:key(n, z)
    elseif pages.index == 7 then
      lfos_view:key(n, z)
    elseif pages.index == 8 then
      mod_matrix_view:key(n, z)
    end
  end
  
  screen_dirty = true
end


local load_first_pset_counter = 0
local load_first_pset_metro
local loading_song = false
local loading_first_pset = false

local function load_first_pset()
  load_first_pset_counter = load_first_pset_counter + 1
  
  if load_first_pset_counter == 2 then
    if can_switch_song then
      on_song_load_press = true
      local pset_file = _path.data.."timber/player/player-01.pset"
      loading_song = true
      loading_first_pset = true
      params:read(pset_file)
      load_first_pset_counter = 0
    end
  end
  
end


local function setup_song()
  local song_to_load = songs_data[current_song_index]
  local song_number = song_to_load.pset_number
  local name = song_to_load.name
    
  local pset_num = string.format("%02d",song_number)
  local pset_file = _path.data.."timber/player/player-"..pset_num..".pset"
  
  if file_exists(pset_file) then
    draw_song_name = true
    on_song_load_press = false
    current_pset_file = pset_file
    current_song_name = name
    can_switch_song = true
  else 
    can_switch_song = false
  end
end

-- Gordey Midi Event
local function midi_song_event(device_id, data)
  local msg = midi.to_msg(data)
  if msg.type == "note_on" then
    if loading_song then
      return
    end
    
    local song_to_load = songs_data[current_song_index]
    local song_number = song_to_load.pset_number
    
    if song_number == song_max_count then
      current_song_index = 1
      setup_song()
    else
      setup_song()
      current_song_index = current_song_index + 1
    end
      
    load_first_pset_counter = 0
    load_first_pset_metro:stop()
    load_first_pset_metro.time = 0.5
    load_first_pset_metro.count = 2
    load_first_pset_metro.event = load_first_pset
    load_first_pset_metro:start()
    draw_song()
    
  elseif msg.type == "note_off" then

  end  
end

local delay_counter = 0
local counter

function count()
  delay_counter = delay_counter + 1
  draw_song()
  if delay_counter == 2 then
    print("-------- delay "..delay_counter.." file"..current_pset_file)
    loading_song = true
    params:read(current_pset_file)
    loading_song = false
    draw_song_name = false 
    screen.font_size(8)
  end
end

-- Gordey Load Next
function on_action_read()
  params.action_read = function(filename,silent,number)
    if loading_first_pset then
      loading_first_pset = false
      
      if can_switch_song then
        can_switch_song = false
        loading_song = true
        
        print("--- load next")
        delay_counter = 0
        counter:stop()
        counter.time = 0.5
        counter.count = 2
        counter.event = count
        counter:start()
      end
    else 
      loading_song = false
    end
  end
end


-- MIDI input
local function midi_event(device_id, data)
  
  local msg = midi.to_msg(data)
  local channel_param = params:get("midi_in_channel")
  
  -- MIDI In
  if device_id == params:get("midi_in_device") then
    if channel_param == 1 or (channel_param > 1 and msg.ch == channel_param - 1) then

      -- Note off
      if msg.type == "note_off" then
        
        local trigger = get_trigger(msg.note)
        local note = -1
        if trigger == nil then
          note = msg.note
        else
          note = trigger.current_note
        end

        key_up(note)

        cube_midi:note_off(msg.note)

      -- Note on
      elseif msg.type == "note_on" then
        local note = get_note(msg.note)
        if note == -1 then
          note = msg.note
          key_down(note, msg.vel / 127)
        else
          key_down(note, 1)
        end


        
        
        if params:get("follow") >= 3 then
          set_sample_id(msg.note)
        end
        
        cube_midi:note_on(msg.note, msg.vel)
        
        -- Key pressure
        elseif msg.type == "key_pressure" then
          set_pressure_voice(msg.note, msg.val / 127)
          
        -- Channel pressure
        elseif msg.type == "channel_pressure" then
          set_pressure_all(msg.val / 127)
          
        -- Pitch bend
        elseif msg.type == "pitchbend" then
          local bend_st = (util.round(msg.val / 2)) / 8192 * 2 -1 -- Convert to -1 to 1
          local bend_range = params:get("bend_range")
          set_pitch_bend_all(bend_st * bend_range)    
      end
    end
  end
  
  -- MIDI Clock In
  if device_id == params:get("midi_clock_in_device") then
    beat_clock:process_midi(data)
    if not beat_clock.playing then
      screen_dirty = true
    end
  end
end

local function reconnect_midi_ins()
  midi_in_device.event = nil
  midi_clock_in_device.event = nil
  midi_in_device = midi.connect(params:get("midi_in_device"))
  midi_clock_in_device = midi.connect(params:get("midi_clock_in_device"))
  midi_in_device.event = function(data) midi_event(params:get("midi_in_device"), data) end
  midi_clock_in_device.event = function(data) midi_event(params:get("midi_clock_in_device"), data) end

end

-- Grid event
local function grid_key(x, y, z)
  local sample_id = (y - 1) * grid_w + x - 1
  if z == 1 then
    key_down(sample_id)
    if params:get("follow") == 2 or params:get("follow") == 4 then
      set_sample_id(sample_id)
    end
  else
    key_up(sample_id)
  end
end

local function update()
  global_view:update()
  waveform_view:update()
  lfos_view:update()
end

function grid_redraw()
  
  if grid_device then
    grid_w = grid_device.cols
    grid_h = grid_device.rows
    if grid_w ~= 8 and grid_w ~= 16 then grid_w = 16 end
    if grid_h ~= 8 and grid_h ~= 16 then grid_h = 8 end
  end
  
  local leds = {}
  local num_leds = grid_w * grid_h
  
  for i = 1, num_leds do
    if sample_status[i - 1] == STATUS.STOPPING then
      leds[i] = 8
    elseif sample_status[i - 1] == STATUS.STARTING or sample_status[i - 1] == STATUS.PLAYING then
      leds[i] = 15
    elseif Timber.samples_meta[i - 1].num_frames > 0 then
      leds[i] = 4
    end
  end
  
  grid_device:all(0)
  for k, v in pairs(leds) do
    grid_device:led(id_to_x(k), id_to_y(k), v)
  end
  grid_device:refresh()
end


local function callback_set_screen_dirty(id)
  if id == nil or id == current_sample_id or pages.index == 1 then
    screen_dirty = true
  end
end

local function callback_set_waveform_dirty(id)
  if (id == nil or id == current_sample_id) and pages.index == 3 then
    screen_dirty = true
  end
end


-- Views

local GlobalView = {}
GlobalView.__index = GlobalView

function GlobalView.new()
  local global = {
    play_visuals = {}
  }
  setmetatable(GlobalView, {__index = GlobalView})
  setmetatable(global, GlobalView)
  return global
end

function GlobalView:add_play_visual()
  local visual = {
    level = math.random(8, 10),
    x = math.random(68, 115),
    y = math.random(8, 55),
    size = 2,
  }
  table.insert(self.play_visuals, visual)
end

function GlobalView:enc(n, delta)
  if n == 2 and beat_clock.external == false then
    params:delta("bpm", delta)
  end
  callback_set_screen_dirty(nil)
end

function GlobalView:key(n, z)
  if z == 1 then
    if n == 2 then
      if not beat_clock.external then
        if beat_clock.playing then
          beat_clock:stop()
          beat_clock:reset()
        else
          beat_clock:start()
        end
      end
      
    elseif n == 3 then
      file_select_active = true
      local add = shift_mode
      shift_mode = false
      Timber.shift_mode = shift_mode
      Timber.FileSelect.enter(_path.audio, function(file)
        file_select_active = false
        screen_dirty = true
        if file ~= "cancel" then
          load_folder(file, add)
        end
      end)
      
    end
    callback_set_screen_dirty(nil)
  end
end

function GlobalView:update()
  for i = #self.play_visuals, 1, -1 do
    self.play_visuals[i].size = self.play_visuals[i].size + 1.5
    self.play_visuals[i].level = self.play_visuals[i].level - 1.5
    if self.play_visuals[i].level < 1 then
      table.remove(self.play_visuals, i)
    end
    callback_set_screen_dirty(nil)
  end
end

function GlobalView:redraw()

  -- Beat visual
  for i = 1, 4 do
    
    if beat_clock.playing and i == beat_clock.beat + 1 then
      screen.level(15)
      screen.rect(3 + (i - 1) * 12, 19, 4, 4)
    else
      screen.level(3)
      screen.rect(4 + (i - 1) * 12, 20, 2, 2)
    end
    screen.fill()
  end
  
  -- Grid or text prompt
  
  local num_to_draw = 128
  
  if grid_device.device then
    num_to_draw = grid_w * grid_h
  end
  
  local draw_grid = false
  for i = 1, num_to_draw do
    if Timber.samples_meta[i - 1].num_frames > 0 then
      draw_grid = true
      break
    end
  end
  
  if draw_grid then
    
    local LEFT = 68
    local top = 20
    local SIZE = 2
    local GUTTER = 1
    
    if grid_device.device and grid_h == 16 then top = top - 12 end
    
    local x, y = LEFT, top
    for i = 1, num_to_draw do
      
      if sample_status[i - 1] == STATUS.STOPPING then
        screen.level(8)
      elseif sample_status[i - 1] == STATUS.STARTING or sample_status[i - 1] == STATUS.PLAYING then
        screen.level(15)
      elseif Timber.samples_meta[i - 1].num_frames > 0 then
        screen.level(3)
      else
        screen.level(1)
      end
      screen.rect(x, y, SIZE, SIZE)
      screen.fill()
      
      x = x + SIZE + GUTTER
      if i % grid_w == 0 then
        x = LEFT
        y = y + SIZE + GUTTER
      end
    end
    
  else
    
    screen.level(3)
    screen.move(68, 28)
    screen.text("K3 to")
    screen.move(68, 37)
    if shift_mode then
      screen.text("add folder")
    else
      screen.text("load folder")
    end
    screen.fill()
    
  end
  
  -- Info
  screen.move(4, 37)
  if beat_clock.external then
    screen.level(3)
    screen.text("External")
  else
    screen.level(15)
    screen.text(params:get("bpm") .. " BPM")
  end
  screen.fill()
  
  screen.line_width(0.75)
  for k, v in pairs(self.play_visuals) do
    screen.level(util.round(v.level))
    screen.circle(v.x, v.y, v.size)
    screen.stroke()
  end
  screen.line_width(1)
  
end


-- Drawing functions

local function draw_background_rects()
  -- 4px edge margins. 8px gutter.
  screen.level(1)
  screen.rect(4, 22, 56, 38)
  screen.rect(68, 22, 56, 38)
  screen.fill()
end

function redraw()
  
  screen.clear()
  
  if draw_song_name then
    draw_song()
    return
  end
  
  
  if file_select_active or Timber.file_select_active then
    Timber.FileSelect.redraw()
    return
  end
  
  -- draw_background_rects()
  
  pages:redraw()
  
  if pages.index == 1 then
    global_view:redraw()
  elseif pages.index == 2 then
    sample_setup_view:redraw()
  elseif pages.index == 3 then
    waveform_view:redraw()
  elseif pages.index == 4 then
    filter_amp_view:redraw()
  elseif pages.index == 5 then
    amp_env_view:redraw()
  elseif pages.index == 6 then
    mod_env_view:redraw()
  elseif pages.index == 7 then
    lfos_view:redraw()
  elseif pages.index == 8 then
    mod_matrix_view:redraw()
  end
  
  screen.update()
end

function load_songs()
  songs_data = tab.load(songs_file)
  for i = 1, #songs_data do
    local song = songs_data[i]
    params:set("song_"..i, song.pset_number)
  end
end

function file_exists(name)
   local f=io.open(name,"r")
   if f~=nil then io.close(f) return true else return false end
end

function draw_song()
  screen.clear()
  screen.font_size(17)
  screen.level(15)
  screen.move(0,40)
  screen.text(current_song_name)
  screen.update()
end



function get_line(filename, line_number)
  local i = 0
  for line in io.lines(filename) do
    i = i + 1
    if i == line_number then
      return line
    end
  end
  return nil -- line not found
end

-- Sequencer Init
function init_sequencer()
  params:add_separator("Sequencer")
  for trigger_index=1, sequence_trigger_count do
    params:add_group("Sequence Trigger " .. trigger_index, sequence_note_count+3)
    
    params:add{
      type = "number", 
      id = "sequence_trigger_"..trigger_index, 
      name = "Sequence Trigger ", 
      min = -1, 
      max = 127, 
      default = -1, 
      allow_pmap = false,
      action = function() setup_sequencer() end
    }
    params:add{
      type = "option", 
      id = "sequence_type_"..trigger_index, 
      name = "Sequence Type", options = sequence_types
    }
    params:add{
      type = "number", 
      id = "sequence_holder_"..trigger_index, 
      name = "Sequence Holder", 
      min = -1, 
      max = 127, 
      default = -1, 
      allow_pmap = false,
      action = function() setup_sequencer() end
    }
    for note_index=1, sequence_note_count do
      params:add{
        type = "number", 
        id = "sequence_note_"..trigger_index.."_"..note_index, 
        name = "Sequence Note "..note_index, 
        min = -1, 
        max = 127, 
        default = -1, 
        allow_pmap = false,
        action = function() setup_sequencer() end
      }
    end
  end
end

-- Sequencer Setup
function setup_sequencer()
  print("Setup Sequencer")
  sequence_data = {}
  for trigger_index=1, sequence_trigger_count do
    local trigger_note = params:get("sequence_trigger_"..trigger_index)
    
    if trigger_note ~= -1 then
      local trigger_data = {}
      trigger_data.trigger_note = trigger_note
      trigger_data.current_note = -1
      trigger_data.type = sequence_types[params:get("sequence_type_"..trigger_index)]
      trigger_data.holder_note = params:get("sequence_holder_"..trigger_index)
      local sequence = {}

      for note_index=1, sequence_note_count do
        local sequence_note = params:get("sequence_note_"..trigger_index.."_"..note_index)
        if sequence_note ~= -1 then
          table.insert(sequence, sequence_note)
        end
      end
      
      if #sequence > 0 then
        trigger_data.sequence = sequins(sequence)
        trigger_data.sequence_exist = true
        trigger_data.current_note = trigger_data.sequence()
      else 
        trigger_data.sequence_exist = false
      end

      table.insert(sequence_data, trigger_data)
    end
  end
  for i = 1, #sequence_data do
    local trigger = sequence_data[i]
    if trigger.type == "step back" or trigger.type == "reset" or trigger.type == "repeat" then
      trigger.holder = get_trigger(trigger.holder_note)
    end
  end
  -- debug_sequencer()
end

-- Get Note
function get_note(note)
  for i = 1, #sequence_data do
    local trigger = sequence_data[i]
    if trigger.trigger_note == note then
      if trigger.type == "step back" then
        trigger.holder.sequence:step(-1)
        trigger.holder.current_note = trigger.holder.sequence()
        return trigger.holder.current_note
      elseif trigger.type == "reset" then
        trigger.holder.sequence:reset()
        trigger.holder.sequence:step(1)
        trigger.holder.current_note = trigger.holder.sequence()
        return trigger.holder.current_note
      elseif trigger.type == "repeat" then
        return trigger.holder.current_note
      end
      trigger.sequence:step(1)
      trigger.current_note = trigger.sequence()
      return trigger.current_note
    end
  end
  return -1
end

-- Get Trigger
function get_trigger(note)
  for i = 1, #sequence_data do
    local trigger = sequence_data[i]
    if trigger.trigger_note == note then
      if trigger.type == "step back" or trigger.type == "reset" or trigger.type == "repeat" then
        return trigger.holder
      end
      return trigger
    end
  end
  return nil
end

-- Sequence Next
function progress_sequence(trigger)
  trigger.sequence:step(1)
  trigger.current_note = trigger.sequence()
end

function debug_sequencer()
  for i = 1, #sequence_data do
    local trigger = sequence_data[i]
    
    print("- trigger "..trigger.trigger_note)
    print("- type "..trigger.type)
    if trigger.sequence_exist then
      local val = trigger.sequence()
      print("-- value "..val)
      local val = trigger.sequence()
      print("-- value "..val)
      local val = trigger.sequence()
      print("-- value "..val)
    end
  end
end


-- Init
function init()
  counter = metro.init()
  load_first_pset_metro = metro.init()
  
  midi_in_device = midi.connect(1)
  midi_in_device.event = function(data) midi_event(1, data) end
  
  midi_clock_in_device = midi.connect(1)
  midi_clock_in_device.event = function(data) midi_event(1, data) end
  
  midi_song_in_device = midi.connect(3)
  midi_song_in_device.event = function(data) midi_song_event(3, data) end
  
  local grid = util.file_exists(_path.code.."midigrid") and include "midigrid/lib/mg_128" or grid
  grid_device = grid.connect(1)
  grid_device.key = grid_key
  
  pages = UI.Pages.new(1, 8)
  
  -- Clock
  beat_clock = BeatClock.new()
  
  beat_clock.on_step = advance_step
  beat_clock.on_stop = stop
  beat_clock.on_select_internal = function()
    beat_clock:start()
    if pages.index == 1 then screen_dirty = true end
  end
  beat_clock.on_select_external = function()
    beat_clock:reset()
    if pages.index == 1 then screen_dirty = true end
  end
  
  beat_clock.ticks_per_step = 1
  beat_clock.steps_per_beat = 96 / 4 -- 96ths
  beat_clock:bpm_change(beat_clock.bpm)
  Timber.set_bpm(beat_clock.bpm)
  
  -- Timber callbacks
  Timber.sample_changed_callback = function(id)
    
    -- Set loop default based on sample length or name
    if Timber.samples_meta[id].manual_load and Timber.samples_meta[id].streaming == 0 and Timber.samples_meta[id].num_frames / Timber.samples_meta[id].sample_rate < 1 and string.find(string.lower(params:get("sample_" .. id)), "loop") == nil then
      params:set("play_mode_" .. id, 3) -- One shot
    end
    
    grid_dirty = true
    callback_set_screen_dirty(id)
  end
  Timber.meta_changed_callback = function(id)
    if Timber.samples_meta[id].playing and sample_status[id] ~= STATUS.STOPPING then
      sample_status[id] = STATUS.PLAYING
    elseif not Timber.samples_meta[id].playing and sample_status[id] ~= STATUS.STARTING then
      sample_status[id] = STATUS.STOPPED
    end
    grid_dirty = true
    callback_set_screen_dirty(id)
  end
  Timber.waveform_changed_callback = callback_set_waveform_dirty
  Timber.play_positions_changed_callback = callback_set_waveform_dirty
  Timber.views_changed_callback = callback_set_screen_dirty

  init_sequencer()

  -- Songs Params
  params:add_separator("Songs")
  
  for i=1, song_count do
    params:add{type = "number", id = "song_"..i, name = "Song "..i, min = 1, max = song_max_count, default = song_max_count, allow_pmap = false}
  end
  
  params:add{type ="trigger", id = "save_songs", name = "save songs", default = 0, 
    action = function()
      songs_data = {}
      local songs_file = _path.data.."timber/songs.data"
      
      print("save to: "..songs_file) 
      
      for i=1, song_count do
        local song = {}
        song.pset_number = params:get("song_"..i)
        local pset_num = string.format("%02d",song.pset_number)
        
        song.name = "Not Found"
        
        local file_name = _path.data.."timber/player/player-"..pset_num..".pset"
        local file = io.open(file_name, "r")
        if file then
          local n = get_line(file_name, 1)
          song.name = string.sub(n, 4)
          io.close(file)
        end
     
        
        table.insert(songs_data, song)
      end
     
      tab.save(songs_data, songs_file)  
      
      print("save data")
    end 
  }
  
  params:add_separator("In/Out")
  
  params:add{type = "number", id = "grid_device", name = "Grid Device", min = 1, max = 4, default = 1,
    action = function(value)
      grid_device:all(0)
      grid_device:refresh()
      grid_device.key = nil
      grid_device = grid.connect(value)
      grid_device.key = grid_key
    end}
  params:add{type = "number", id = "midi_in_device", name = "MIDI In Device", min = 1, max = 4, default = 1, action = reconnect_midi_ins}
  local channels = {"All"}
  for i = 1, 16 do table.insert(channels, i) end
  params:add{type = "option", id = "midi_in_channel", name = "MIDI In Channel", options = channels}
    
  params:add{type = "number", id = "midi_clock_in_device", name = "MIDI Clock In Device", min = 1, max = 4, default = 1, action = reconnect_midi_ins}
  
  params:add{type = "number", id = "midi_song_in_device", name = "MIDI Song Change Device", min = 1, max = 4, default = 1, action = reconnect_midi_ins}
  
  params:add{type = "option", id = "clock", name = "Clock", options = {"Internal", "External"}, default = beat_clock.external or 2 and 1,
    action = function(value)
      beat_clock:clock_source_change(value)
    end}
  
  params:add{type = "option", id = "clock_out", name = "Clock Out", options = options.OFF_ON, default = beat_clock.send or 2 and 1,
    action = function(value)
      if value == 1 then beat_clock.send = false
      else beat_clock.send = true end
    end}
  
  params:add_separator("Player")
  
  params:add{type = "number", id = "bpm", name = "BPM", min = 1, max = 240, default = beat_clock.bpm,
    action = function(value)
      beat_clock:bpm_change(value)
      Timber.set_bpm(beat_clock.bpm)
      if pages.index == 1 then screen_dirty = true end
    end}
    
  params:add{type = "number", id = "bend_range", name = "Pitch Bend Range", min = 1, max = 48, default = 2}
  
  params:add{type = "option", id = "follow", name = "Follow", options = {"Off", "Grid", "MIDI", "Both"}, default = 4}
  
  params:add{type = "option", id = "display", name = "Display", options = {"IDs", "Notes"}, default = 1, action = function(value)
    if value == 1 then Timber.display = "id"
    else Timber.display = "note" end
  end}
  
  params:add{type = "trigger", id = "launch_mode_all_gate", name = "Launch Mode: All Gate", action = function()
    for i = 0, NUM_SAMPLES - 1 do
      params:set("launch_mode_" .. i, 1)
    end
  end}
  
  params:add{type = "trigger", id = "launch_mode_all_toggle", name = "Launch Mode: All Toggle", action = function()
    for i = 0, NUM_SAMPLES - 1 do
      params:set("launch_mode_" .. i, 2)
    end
  end}
  
  Timber.add_params()
  params:add_separator()
  -- Index zero to align with MIDI note numbers
  for i = 0, NUM_SAMPLES - 1 do
    local extra_params = {
      {type = "option", id = "launch_mode_" .. i, name = "Launch Mode", options = {"Gate", "Toggle"}, default = 1, action = function(value)
        Timber.setup_params_dirty = true
      end},
      {type = "option", id = "quantization_" .. i, name = "Quantization", options = options.QUANTIZATION, default = 1, action = function(value)
        if value == 1 then
          for n = #note_queue, 1, -1 do
            if note_queue[n].sample_id == i then
              table.remove(note_queue, n)
              if Timber.samples_meta[i].playing then
                sample_status[i] = STATUS.PLAYING
              else
                sample_status[i] = STATUS.STOPPED
              end
              grid_dirty = true
            end
          end
        end
        Timber.setup_params_dirty = true
      end}
    }
    Timber.add_sample_params(i, true, extra_params)
  end
  
  
  -- UI
  
  global_view = GlobalView.new()
  sample_setup_view = Timber.UI.SampleSetup.new(current_sample_id, nil)
  waveform_view = Timber.UI.Waveform.new(current_sample_id)
  filter_amp_view = Timber.UI.FilterAmp.new(current_sample_id)
  amp_env_view = Timber.UI.AmpEnv.new(current_sample_id)
  mod_env_view = Timber.UI.ModEnv.new(current_sample_id)
  lfos_view = Timber.UI.Lfos.new(current_sample_id)
  mod_matrix_view = Timber.UI.ModMatrix.new(current_sample_id)
  
  screen.aa(1)
  
  local screen_redraw_metro = metro.init()
  screen_redraw_metro.event = function()
    update()
    if screen_dirty then
      redraw()
      screen_dirty = false
    end
  end
  
  local grid_redraw_metro = metro.init()
  grid_redraw_metro.event = function()
    if grid_dirty and grid_device.device then
      grid_dirty = false
      grid_redraw()
    end
  end
  
  screen_redraw_metro:start(1 / SCREEN_FRAMERATE)
  grid_redraw_metro:start(1 / GRID_FRAMERATE)
  
  beat_clock:start()
  on_action_read()
  load_songs()
  
  cube_midi = midi.connect(2)
  cube_midi.event = nil
end

function r()
  norns.script.load(norns.state.script)
end