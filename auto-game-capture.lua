--[[
Auto Game Capture

Follows the focused window: when its executable is a known game (custom list or
JSON database), a Game Capture (or Window Capture, for "Window" database entries
and listed executables) source is pointed at that exact window and shown.
Otherwise a screen capture source is shown. The screen source stays visible
until the capture source reports it is hooked, so switching never shows an
empty frame.

Saved replays are moved into a folder named after the game. It goes inside the
recording folder, after any fixed leading folders of the filename formatting
(e.g. "/OBS/%CCYY %B%DD" -> <recording folder>/OBS/<game>/2026 November01), and
the rest of the replay buffer's formatting is kept below it.
Optionally, every saved replay is also hard linked into a configurable folder
(same drive only), e.g. a folder another app imports from. No extra disk space.
Apps in "Keep current capture when focused" behave like OBS itself: focusing
them leaves the current capture (and replay game folder) unchanged.

Database format:
  { "<lowercase exe name without .exe>": { "name": "<display name>", "capture": "Game" | "Window" }, ... }
"capture" picks the default capture source; "Use Window Capture for" overrides it.
If no database is set, games_database.json next to this script is used.
Custom games: "<exe> = <display name>" entries in the script settings.
]]

local obs = obslua
local ffi = require("ffi")

pcall(ffi.cdef, [[
void *GetForegroundWindow(void);
uint32_t GetWindowThreadProcessId(void *hwnd, uint32_t *pid);
int GetWindowTextLengthW(void *hwnd);
int GetWindowTextW(void *hwnd, uint16_t *buf, int max_count);
int GetClassNameW(void *hwnd, uint16_t *buf, int max_count);
void *OpenProcess(uint32_t access, int inherit, uint32_t pid);
int QueryFullProcessImageNameW(void *process, uint32_t flags, uint16_t *buf, uint32_t *size);
int CloseHandle(void *handle);
uint32_t GetCurrentProcessId(void);
int WideCharToMultiByte(uint32_t code_page, uint32_t flags, const uint16_t *src, int src_len,
                        char *dst, int dst_len, const char *default_char, int *used_default);
int MultiByteToWideChar(uint32_t code_page, uint32_t flags, const char *src, int src_len,
                        uint16_t *dst, int dst_len);
int CreateHardLinkW(const uint16_t *new_path, const uint16_t *existing_path, void *security);
uint32_t GetLastError(void);
]])

local user32 = ffi.load("user32")
local kernel32 = ffi.load("kernel32")

local CP_UTF8 = 65001
local PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
local WINDOW_PRIORITY_TITLE = 1
local WINDOW_PRIORITY_EXE = 2
local MKDIR_ERROR = -1
local MOVE_RETRY_MS = 500
local MOVE_MAX_TRIES = 20

-- Transient shell windows that appear while switching focus; keep the current
-- capture instead of flashing to the screen source.
local HOLD_CLASSES = {
	XamlExplorerHostIslandWindow = true, -- Windows 11 Alt+Tab / Task View
	MultitaskingViewFrame = true, -- Windows 10 Alt+Tab
	TaskSwitcherWnd = true, -- classic Alt+Tab
	ForegroundStaging = true, -- shown briefly during focus changes
}

local MODE_LABELS = { game = "Game Capture", window = "Window Capture", screen = "Screen" }

local WIDE_BUF_LEN = 32768
local wide_buf = ffi.new("uint16_t[?]", WIDE_BUF_LEN)
local pid_buf = ffi.new("uint32_t[1]")
local size_buf = ffi.new("uint32_t[1]")
local own_pid = kernel32.GetCurrentProcessId()

local cfg = {
	enabled = true,
	db_path = "",
	scene = "",
	sources = { game = "", window = "", screen = "" },
	window_exes = {},
	excluded = {},
	held = {}, -- exes that keep the current capture when focused, like OBS itself
	custom_games = {}, -- normalized exe -> display name; overrides the database
	sort_replays = true,
	link_replays = false,
	link_dir = "",
	interval = 250,
}

local db = nil -- obs_data_t loaded from cfg.db_path
local warned = {}

local state = {
	last_hwnd = nil, -- foreground window handle seen on the previous poll
	mode = nil, -- "game" | "window" | "screen"
	target = {}, -- kind -> window handle the capture source is pointed at
	winstr = {}, -- kind -> window string last written to the capture source
	game = nil, -- display name of the game being captured, nil on screen
	last_game = nil, -- previous value of game, for replays saved after leaving it
	last_game_left = 0, -- os.time() when last_game lost focus
}

local pending_moves = {} -- replays whose move failed and will be retried

local function log(msg)
	obs.script_log(obs.LOG_INFO, msg)
end

local function warn_once(key, msg)
	if not warned[key] then
		warned[key] = true
		obs.script_log(obs.LOG_WARNING, msg)
	end
end

-- Win32 helpers ---------------------------------------------------------------

local function wide_to_utf8(buf, len)
	if len <= 0 then
		return ""
	end
	local n = kernel32.WideCharToMultiByte(CP_UTF8, 0, buf, len, nil, 0, nil, nil)
	if n <= 0 then
		return ""
	end
	local out = ffi.new("char[?]", n)
	kernel32.WideCharToMultiByte(CP_UTF8, 0, buf, len, out, n, nil, nil)
	return ffi.string(out, n)
end

local function window_title(hwnd)
	local len = user32.GetWindowTextLengthW(hwnd)
	if len <= 0 then
		return ""
	end
	local buf = wide_buf
	if len >= WIDE_BUF_LEN then
		buf = ffi.new("uint16_t[?]", len + 1)
	end
	return wide_to_utf8(buf, user32.GetWindowTextW(hwnd, buf, len + 1))
end

local function window_class(hwnd)
	return wide_to_utf8(wide_buf, user32.GetClassNameW(hwnd, wide_buf, 256))
end

-- Executable file name (e.g. "Game.exe") of a process, or nil.
local function process_exe(pid)
	local process = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
	if process == nil then
		return nil
	end
	size_buf[0] = WIDE_BUF_LEN
	local ok = kernel32.QueryFullProcessImageNameW(process, 0, wide_buf, size_buf) ~= 0
	kernel32.CloseHandle(process)
	if not ok then
		return nil
	end
	return wide_to_utf8(wide_buf, size_buf[0]):match("[^\\]+$")
end

-- Database and settings helpers --------------------------------------------------

local function normalize_exe(name)
	name = name:lower():match("^%s*(.-)%s*$")
	return (name:gsub("%.exe$", ""))
end

local DEFAULT_DB_NAME = "games_database.json"

-- An empty setting means games_database.json next to this script.
local function resolve_db_path(setting)
	if setting ~= "" then
		return setting
	end
	local path = script_path() .. DEFAULT_DB_NAME
	if obs.os_file_exists(path) then
		return path
	end
	warn_once("no-default-db", "No game database set and " .. DEFAULT_DB_NAME .. " not found next to the script")
	return ""
end

local function load_db(path)
	if db ~= nil then
		obs.obs_data_release(db)
		db = nil
	end
	if path == "" then
		return
	end
	db = obs.obs_data_create_from_json_file(path)
	if db == nil then
		obs.script_log(obs.LOG_WARNING, "Could not load game database: " .. path)
	else
		log("Loaded game database: " .. path)
	end
end

-- Returns the display name and default capture kind ("game" or "window") of a
-- database entry, or nil when the exe isn't listed.
local function db_entry(key)
	if db == nil then
		return nil
	end
	local entry = obs.obs_data_get_obj(db, key)
	if entry == nil then
		return nil
	end
	local title = obs.obs_data_get_string(entry, "name")
	local capture = obs.obs_data_get_string(entry, "capture"):lower()
	obs.obs_data_release(entry)
	return title ~= "" and title or key, capture == "window" and "window" or "game"
end

local function each_list_value(settings, name, fn)
	local arr = obs.obs_data_get_array(settings, name)
	if arr == nil then
		return
	end
	for i = 0, obs.obs_data_array_count(arr) - 1 do
		local item = obs.obs_data_array_item(arr, i)
		fn(obs.obs_data_get_string(item, "value"))
		obs.obs_data_release(item)
	end
	obs.obs_data_array_release(arr)
end

local function read_exe_set(settings, name)
	local set = {}
	each_list_value(settings, name, function(value)
		local key = normalize_exe(value)
		if key ~= "" then
			set[key] = true
		end
	end)
	return set
end

-- Entries look like "game.exe = Display Name"; the name defaults to the exe.
local function read_custom_games(settings)
	local games = {}
	each_list_value(settings, "custom_games", function(value)
		local exe, title = value:match("^(.-)=(.*)$")
		local key = normalize_exe(exe or value)
		title = (title or ""):match("^%s*(.-)%s*$")
		if key ~= "" then
			games[key] = title ~= "" and title or key
		end
	end)
	return games
end

-- OBS window strings are "title:class:exe" with '#' and ':' escaped.
local function encode_window_part(s)
	return (s:gsub("#", "#22"):gsub(":", "#3A"))
end

-- Capture control ---------------------------------------------------------------

local function get_source(kind)
	local name = cfg.sources[kind]
	if name == "" then
		return nil
	end
	local src = obs.obs_get_source_by_name(name)
	if src == nil then
		warn_once("missing-source:" .. name, "Source not found: " .. name)
	end
	return src
end

local function is_hooked(src)
	local cd = obs.calldata_create()
	local ph = obs.obs_source_get_proc_handler(src)
	local hooked = obs.proc_handler_call(ph, "get_hooked", cd) and obs.calldata_bool(cd, "hooked")
	obs.calldata_destroy(cd)
	return hooked
end

local function update_capture(src, kind, winstr, priority)
	local s = obs.obs_data_create()
	if kind == "game" then
		obs.obs_data_set_string(s, "capture_mode", "window")
	end
	obs.obs_data_set_string(s, "window", winstr)
	obs.obs_data_set_int(s, "priority", priority)
	obs.obs_source_update(src, s)
	obs.obs_data_release(s)
end

-- Point a capture source at one specific window. OBS resolves the window string
-- to the first exact match in z-order, which is the focused window, so a fresh
-- search lands on the right instance even when several share the same string.
local function retarget(kind, winstr)
	local src = get_source(kind)
	if src == nil then
		return false
	end
	if kind == "game" and state.winstr.game == winstr then
		-- Game Capture only re-searches when its config changes, so flip the
		-- match priority to force a reset. Window Capture resets on any update.
		update_capture(src, kind, winstr, WINDOW_PRIORITY_TITLE)
	end
	update_capture(src, kind, winstr, WINDOW_PRIORITY_EXE)
	obs.obs_source_release(src)
	state.winstr[kind] = winstr
	return true
end

local function set_item_visible(scene, name, visible)
	if name == "" then
		return
	end
	local item = obs.obs_scene_find_source_recursive(scene, name)
	if item == nil then
		warn_once("missing-item:" .. name, "Source '" .. name .. "' is not in scene '" .. cfg.scene .. "'")
		return
	end
	if obs.obs_sceneitem_visible(item) ~= visible then
		obs.obs_sceneitem_set_visible(item, visible)
	end
end

local function apply_visibility()
	local mode = state.mode
	if mode == nil or cfg.scene == "" then
		return
	end

	local capture_hooked = false
	if mode ~= "screen" then
		local src = get_source(mode)
		if src ~= nil then
			capture_hooked = is_hooked(src)
			obs.obs_source_release(src)
		end
	end

	local scene_src = obs.obs_get_source_by_name(cfg.scene)
	if scene_src == nil then
		warn_once("missing-scene:" .. cfg.scene, "Scene not found: " .. cfg.scene)
		return
	end
	local scene = obs.obs_scene_from_source(scene_src)
	if scene ~= nil then
		set_item_visible(scene, cfg.sources.game, mode == "game")
		set_item_visible(scene, cfg.sources.window, mode == "window")
		set_item_visible(scene, cfg.sources.screen, not capture_hooked)
	end
	obs.obs_source_release(scene_src)
end

-- game: display name of the captured game, nil when showing the screen.
local function set_mode(mode, label, game)
	if state.mode ~= mode then
		log(string.format("%s -> %s", label, MODE_LABELS[mode]))
	end
	if state.game ~= nil and state.game ~= game then
		state.last_game = state.game
		state.last_game_left = os.time()
	end
	state.mode = mode
	state.game = game
end

local function on_focus(hwnd, key)
	user32.GetWindowThreadProcessId(hwnd, pid_buf)
	local pid = pid_buf[0]
	if pid == 0 or pid == own_pid then
		return -- OBS itself: keep whatever is showing
	end

	local class = window_class(hwnd)
	if HOLD_CLASSES[class] then
		return
	end

	local exe = process_exe(pid)
	if exe == nil then
		set_mode("screen", "(unknown process)")
		return
	end

	local name = normalize_exe(exe)
	if cfg.held[name] then
		return
	end
	local title, capture = db_entry(name)
	local game = cfg.custom_games[name] or title
	local kind = "screen"
	if not cfg.excluded[name] then
		if cfg.window_exes[name] then
			kind = "window"
			game = game or name
		elseif game ~= nil then
			kind = capture or "game"
		end
	end

	local label = string.format("%s (%s)", game or name, exe)
	if kind == "screen" then
		set_mode("screen", label, nil)
		return
	end

	if state.target[kind] ~= key then
		local winstr = encode_window_part(window_title(hwnd))
			.. ":"
			.. encode_window_part(class)
			.. ":"
			.. encode_window_part(exe)
		if not retarget(kind, winstr) then
			warn_once("no-source:" .. kind, "No " .. MODE_LABELS[kind] .. " source configured")
			set_mode("screen", label, nil)
			return
		end
		state.target[kind] = key
		log(string.format("%s: targeting %s", MODE_LABELS[kind], label))
	end
	set_mode(kind, label, game)
end

local function poll()
	local hwnd = user32.GetForegroundWindow()
	if hwnd ~= nil then
		local key = tonumber(ffi.cast("uintptr_t", hwnd))
		if key ~= state.last_hwnd then
			state.last_hwnd = key
			on_focus(hwnd, key)
		end
	end
	apply_visibility()
end

-- Replay sorting ------------------------------------------------------------------

local RESERVED_NAMES = { CON = true, PRN = true, AUX = true, NUL = true }

local function folder_name(name)
	name = name:gsub('[%c<>:"/\\|%?%*]', ""):gsub("[%s%.]+$", ""):gsub("^%s+", "")
	local stem = name:match("^[^%.]*"):upper()
	if RESERVED_NAMES[stem] or stem:match("^COM%d$") or stem:match("^LPT%d$") then
		name = "_" .. name
	end
	return name
end

local function replay_buffer_seconds()
	local output = obs.obs_frontend_get_replay_buffer_output()
	if output == nil then
		return 0
	end
	local settings = obs.obs_output_get_settings(output)
	local seconds = obs.obs_data_get_int(settings, "max_time_sec")
	obs.obs_data_release(settings)
	obs.obs_output_release(output)
	return seconds
end

-- The game a replay belongs to: the one being captured, or the previous one if
-- it lost focus recently enough to still be inside the replay buffer.
local function replay_game()
	if state.game ~= nil then
		return state.game
	end
	if state.last_game ~= nil and os.time() - state.last_game_left <= replay_buffer_seconds() then
		return state.last_game
	end
	return nil
end

-- Recording folders from the current profile; the replay buffer saves under one
-- of them depending on output mode.
local RECORDING_PATH_KEYS = {
	{ "SimpleOutput", "FilePath" },
	{ "AdvOut", "RecFilePath" },
	{ "AdvOut", "FFFilePath" },
}

-- Split a saved replay path into the profile's recording folder and the part
-- produced by the filename formatting (which may contain subfolders). Falls back
-- to the file's own folder when no recording folder contains it.
local function split_replay_path(path)
	path = path:gsub("\\", "/")
	local lower = path:lower()
	local best = nil
	local config = obs.obs_frontend_get_profile_config()
	for _, key in ipairs(RECORDING_PATH_KEYS) do
		local root = config ~= nil and obs.config_get_string(config, key[1], key[2]) or nil
		if root ~= nil and root ~= "" then
			root = root:gsub("\\", "/"):gsub("/+$", "")
			if lower:sub(1, #root + 1) == root:lower() .. "/" and (best == nil or #root > #best) then
				best = path:sub(1, #root)
			end
		end
	end
	if best == nil then
		best = path:match("^(.*)/[^/]+$")
		if best == nil then
			return nil, nil
		end
	end
	return best, (path:sub(#best + 2):gsub("/+", "/"):gsub("^/", ""))
end

-- Split the formatted part of a replay path into the fixed leading folders of the
-- filename formatting (folders without % codes, e.g. "OBS/" in
-- "/OBS/%CCYY %B%DD") and the rest, so the game folder can go between them.
local function split_format_prefix(relative)
	local config = obs.obs_frontend_get_profile_config()
	local format = config ~= nil and obs.config_get_string(config, "Output", "FilenameFormatting") or nil
	local dirs = {}
	for part in (format or ""):gsub("\\", "/"):gmatch("[^/]+") do
		dirs[#dirs + 1] = part
	end
	dirs[#dirs] = nil -- the last part is the file name
	local prefix = ""
	for _, dir in ipairs(dirs) do
		local head, tail = relative:match("^([^/]+)/(.+)$")
		if dir:find("%", 1, true) or head == nil or head:lower() ~= dir:lower() then
			break
		end
		prefix = prefix .. head .. "/"
		relative = tail
	end
	return prefix, relative
end

-- Adds " (n)" before the extension until the path is free.
local function unique_path(path)
	local stem, ext = path:match("^(.*)(%.[^%./]*)$")
	stem, ext = stem or path, ext or ""
	local candidate = path
	local n = 2
	while obs.os_file_exists(candidate) do
		candidate = string.format("%s (%d)%s", stem, n, ext)
		n = n + 1
	end
	return candidate
end

local function utf8_to_wide(s)
	local n = kernel32.MultiByteToWideChar(CP_UTF8, 0, s, -1, nil, 0)
	local buf = ffi.new("uint16_t[?]", math.max(n, 1))
	kernel32.MultiByteToWideChar(CP_UTF8, 0, s, -1, buf, n)
	return buf
end

-- Hard links a saved replay into the configured folder (e.g. a folder another
-- app watches), without using extra disk space.
local function link_replay(path)
	if not cfg.link_replays or cfg.link_dir == "" then
		return
	end
	local dir = cfg.link_dir:gsub("\\", "/"):gsub("/+$", "")
	local file_dir, file = path:gsub("\\", "/"):match("^(.*)/([^/]+)$")
	if file == nil or file_dir:lower() == dir:lower() then
		return -- already in the link folder
	end
	if obs.os_mkdirs(dir) == MKDIR_ERROR then
		obs.script_log(obs.LOG_WARNING, "Could not create link folder " .. dir)
		return
	end
	local link = unique_path(dir .. "/" .. file)
	if kernel32.CreateHardLinkW(utf8_to_wide(link), utf8_to_wide(path), nil) ~= 0 then
		log("Linked replay into " .. link)
		return
	end
	local err = kernel32.GetLastError()
	local reason = err == 17 and "the link folder must be on the same drive as the replay"
		or string.format("error %d", err)
	obs.script_log(obs.LOG_WARNING, "Could not hard link replay into " .. dir .. ": " .. reason)
end

-- Returns true when the move is finished (succeeded or given up).
local function try_move(move)
	if obs.os_rename(move.src, move.dst) == 0 then
		log("Moved replay to " .. move.dst)
		link_replay(move.dst)
		return true
	end
	move.tries = move.tries + 1
	if move.tries >= MOVE_MAX_TRIES then
		obs.script_log(obs.LOG_WARNING, "Could not move replay " .. move.src .. " to " .. move.dst)
		link_replay(move.src)
		return true
	end
	return false
end

local function retry_moves()
	local remaining = {}
	for _, move in ipairs(pending_moves) do
		if not try_move(move) then
			remaining[#remaining + 1] = move
		end
	end
	pending_moves = remaining
	if #pending_moves == 0 then
		obs.remove_current_callback()
	end
end

-- Destination inside the game folder for a saved replay, or nil to leave it.
local function sorted_path(path)
	local game = replay_game()
	if game == nil then
		return nil
	end
	local root, relative = split_replay_path(path)
	local folder = folder_name(game)
	if root == nil or folder == "" then
		return nil
	end
	local prefix, rest = split_format_prefix(relative)
	local dst = unique_path(root .. "/" .. prefix .. folder .. "/" .. rest)
	local dst_dir = dst:match("^(.*)/")
	if obs.os_mkdirs(dst_dir) == MKDIR_ERROR then
		obs.script_log(obs.LOG_WARNING, "Could not create replay folder " .. dst_dir)
		return nil
	end
	return dst
end

local function on_replay_saved()
	local path = obs.obs_frontend_get_last_replay()
	if path == nil or path == "" then
		return
	end
	local dst = cfg.sort_replays and sorted_path(path) or nil
	if dst == nil then
		link_replay(path)
		return
	end
	local move = { src = path, dst = dst, tries = 0 }
	-- The muxer can still hold the file for a moment after the save event.
	if not try_move(move) then
		pending_moves[#pending_moves + 1] = move
		if #pending_moves == 1 then
			obs.timer_add(retry_moves, MOVE_RETRY_MS)
		end
	end
end

local function on_frontend_event(event)
	if event == obs.OBS_FRONTEND_EVENT_REPLAY_BUFFER_SAVED then
		on_replay_saved()
	end
end

-- OBS script interface ------------------------------------------------------------

function script_description()
	return [[<b>Auto Game Capture</b><br>
Shows a Game Capture source pointed at the focused game, a Window Capture source for
games marked <code>"capture": "Window"</code> in the database or listed under "Use Window
Capture for", and a screen source for everything else.<br><br>
Put all three sources in one scene. The script controls their visibility and
rewrites the capture sources' window settings. Games are matched by executable name
against the custom games list, then the JSON database.<br><br>
Custom games use <code>game.exe = Display Name</code> (the name is optional).
Saved replays are moved into a folder named after the game, placed after any fixed
leading folders of the filename formatting (e.g. <code>OBS/&lt;game&gt;/...</code>).<br><br>
Apps under "Keep current capture when focused" behave like OBS itself: focusing them
doesn't switch away from the game.]]
end

local function add_source_list(props, setting, label, source_id)
	local p = obs.obs_properties_add_list(props, setting, label, obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(p, "(none)", "")
	local sources = obs.obs_enum_sources()
	if sources ~= nil then
		for _, src in ipairs(sources) do
			if obs.obs_source_get_unversioned_id(src) == source_id then
				local name = obs.obs_source_get_name(src)
				obs.obs_property_list_add_string(p, name, name)
			end
		end
	end
	obs.source_list_release(sources)
end

function script_properties()
	local props = obs.obs_properties_create()

	obs.obs_properties_add_bool(props, "enabled", "Enabled")
	local p = obs.obs_properties_add_path(props, "db_path", "Game database", obs.OBS_PATH_FILE, "JSON files (*.json)", nil)
	obs.obs_property_set_long_description(p, "Leave empty to use " .. DEFAULT_DB_NAME .. " in the script's folder.")

	p = obs.obs_properties_add_list(props, "scene", "Scene", obs.OBS_COMBO_TYPE_LIST, obs.OBS_COMBO_FORMAT_STRING)
	obs.obs_property_list_add_string(p, "(none)", "")
	for _, name in ipairs(obs.obs_frontend_get_scene_names() or {}) do
		obs.obs_property_list_add_string(p, name, name)
	end

	add_source_list(props, "game_source", "Game Capture source", "game_capture")
	add_source_list(props, "window_source", "Window Capture source", "window_capture")
	add_source_list(props, "screen_source", "Screen source", "monitor_capture")

	obs.obs_properties_add_editable_list(props, "custom_games", "Custom games (exe = name)",
		obs.OBS_EDITABLE_LIST_TYPE_STRINGS, nil, nil)
	obs.obs_properties_add_editable_list(props, "window_exes", "Use Window Capture for",
		obs.OBS_EDITABLE_LIST_TYPE_STRINGS, nil, nil)
	obs.obs_properties_add_editable_list(props, "excluded_exes", "Never treat as a game",
		obs.OBS_EDITABLE_LIST_TYPE_STRINGS, nil, nil)
	obs.obs_properties_add_editable_list(props, "held_exes", "Keep current capture when focused",
		obs.OBS_EDITABLE_LIST_TYPE_STRINGS, nil, nil)

	obs.obs_properties_add_bool(props, "sort_replays", "Move saved replays into game folders")
	obs.obs_properties_add_bool(props, "link_replays", "Also hard link saved replays into folder")
	obs.obs_properties_add_path(props, "link_dir", "Hard link folder", obs.OBS_PATH_DIRECTORY, nil, nil)

	obs.obs_properties_add_int(props, "interval", "Focus check interval (ms)", 50, 2000, 50)
	return props
end

function script_defaults(settings)
	obs.obs_data_set_default_bool(settings, "enabled", true)
	obs.obs_data_set_default_bool(settings, "sort_replays", true)
	obs.obs_data_set_default_int(settings, "interval", 250)
end

function script_load(settings)
	obs.obs_frontend_add_event_callback(on_frontend_event)
end

function script_update(settings)
	obs.timer_remove(poll)

	local db_path = resolve_db_path(obs.obs_data_get_string(settings, "db_path"))
	if db_path ~= cfg.db_path then
		cfg.db_path = db_path
		load_db(db_path)
	end

	cfg.enabled = obs.obs_data_get_bool(settings, "enabled")
	cfg.scene = obs.obs_data_get_string(settings, "scene")
	cfg.sources.game = obs.obs_data_get_string(settings, "game_source")
	cfg.sources.window = obs.obs_data_get_string(settings, "window_source")
	cfg.sources.screen = obs.obs_data_get_string(settings, "screen_source")
	cfg.window_exes = read_exe_set(settings, "window_exes")
	cfg.excluded = read_exe_set(settings, "excluded_exes")
	cfg.held = read_exe_set(settings, "held_exes")
	cfg.custom_games = read_custom_games(settings)
	cfg.sort_replays = obs.obs_data_get_bool(settings, "sort_replays")
	cfg.link_replays = obs.obs_data_get_bool(settings, "link_replays")
	cfg.link_dir = obs.obs_data_get_string(settings, "link_dir")
	cfg.interval = obs.obs_data_get_int(settings, "interval")

	warned = {}
	if state.game ~= nil then
		state.last_game = state.game
		state.last_game_left = os.time()
	end
	state.last_hwnd = nil
	state.mode = nil
	state.game = nil
	state.target = {}
	state.winstr = {}

	if cfg.enabled then
		obs.timer_add(poll, cfg.interval)
	end
end

function script_unload()
	obs.timer_remove(poll)
	obs.timer_remove(retry_moves)
	obs.obs_frontend_remove_event_callback(on_frontend_event)
	if db ~= nil then
		obs.obs_data_release(db)
		db = nil
	end
end
