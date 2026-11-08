local ui = require "ui"
local options = require "mp.options"
local utils = require "mp.utils"
local assdraw = require "mp.assdraw"
local input = require "mp.input"

local opts = {
    backend = "mpv-splice-backend",
    cancel_key = "C",
    output_prefix = "cut_",
}
options.read_options(opts, "mpv-splice")

local task, started, progress_path, percent
local job_serial = 0
local editing, prompting = false, false
local first, last, crop, settings, output_name, message
local capabilities, loading
local saved, drag, edge_capture = {}, nil, false
local W, H = 1280, 720
local overlay = mp.create_osd_overlay("ass-events")
local handles_overlay = mp.create_osd_overlay("ass-events")
handles_overlay.z = 1001
local draw, layout, start_export, cancel, reset, bindings, dismiss
local accent, fg = "3282FF", "FFFFFF"

local function notify(text, duration)
    mp.msg.info(text)
    mp.osd_message(text, duration or 3)
end

local function clock(seconds)
    seconds = math.max(0, seconds or 0)
    return string.format("%02d:%06.3f", math.floor(seconds / 60), seconds % 60)
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function source_size()
    local p = mp.get_property_native("video-params") or {}
    local rotation = (p.rotate or 0) % 360
    if rotation == 90 or rotation == 270 then return p.h or 0, p.w or 0, rotation end
    return p.w or 0, p.h or 0, rotation
end

local function choose_output(format_name)
    local _, filename = utils.split_path(mp.get_property("path", "video.mkv"))
    local stem, extension = filename:match("^(.*)%.([^.]*)$")
    stem, extension = stem or filename, extension or "mkv"
    if format_name and format_name ~= "source" then
        extension = capabilities and capabilities.extensions[format_name] or format_name
    end
    local directory = utils.split_path(mp.get_property("path", ""))
    local name, index = opts.output_prefix .. stem .. "." .. extension, 1
    while utils.file_info(utils.join_path(directory, name)) do
        index = index + 1
        name = opts.output_prefix .. stem .. "_" .. index .. "." .. extension
    end
    return name
end

local function dialog(args, select)
    prompting = true
    bindings()
    draw()
    local submit, chosen, path = args.submit, nil, mp.get_property("path")
    args.submit = function(value) chosen = value end
    args.closed = function()
        prompting = false
        bindings()
        -- mp.input unregisters its event handler after this callback returns.
        mp.add_timeout(0, function()
            if chosen ~= nil and settings and mp.get_property("path") == path then submit(chosen) end
            draw()
        end)
    end
    if select then input.select(args) else input.get(args) end
end

local function edit_text(label, value, accept)
    dialog({prompt = label, default_text = value or "", submit = accept})
end

local function select_value(label, entries, current, accept)
    local labels, selected = {}, 1
    for i, entry in ipairs(entries) do
        labels[i] = entry.label
        if current ~= nil and entry.id == current then selected = i end
    end
    dialog({prompt = label, items = labels, default_item = selected,
        submit = function(i) accept(entries[i]) end}, true)
end

local function pick(kind)
    if not capabilities then notify("Loading export formats") return end
    local entries = {}
    if kind == "profiles" then entries = capabilities.profiles
    else
        entries = {{id = kind == "formats" and "source" or "copy", label = kind == "formats" and "Source container" or "Copy unchanged"}}
        if kind ~= "formats" then table.insert(entries, {id = "none", label = "Remove " .. kind}) end
        for _, entry in ipairs(capabilities[kind]) do entries[#entries + 1] = entry end
    end
    local key = kind == "formats" and "format" or kind == "profiles" and "profile" or kind
    select_value(kind == "profiles" and "Export preset" or "Choose " .. kind, entries, settings[key], function(entry)
        if kind == "profiles" then
            settings.profile, settings.format, settings.video, settings.audio = entry.id, entry.format, entry.video, entry.audio
            settings.label = entry.label
        else
            settings[key], settings.profile, settings.label = entry.id, "custom", "Custom"
        end
        output_name = choose_output(settings.format)
    end)
end

local function load_capabilities()
    if capabilities or loading then return end
    loading = true
    mp.command_native_async({name = "subprocess", args = {opts.backend, "--capabilities"},
        playback_only = false, capture_stdout = true, capture_stderr = true}, function(success, result)
        loading = nil
        if success and result.status == 0 then capabilities = utils.parse_json(result.stdout)
        else notify("Could not load export formats: " .. (result and result.stderr or opts.backend), 6) end
        draw()
    end)
end

local function read_progress()
    local file = progress_path and io.open(progress_path, "r")
    if not file then return end
    local completed, total = (file:read("*l") or ""):match("^(%d+),(%d+)$")
    file:close()
    if total and total ~= "0" then percent = math.floor(completed * 100 / total) end
end

local progress_timer = mp.add_periodic_timer(0.25, function()
    read_progress()
    draw()
end, true)

start_export = function(a, b, edits, name)
    if task then return end
    local path = mp.get_property("path")
    if not path or mp.get_property_bool("demuxer-via-network", false) then
        notify("Export requires a local file", 5) return
    end
    if a == b then notify("Selection is empty") return end
    job_serial = job_serial + 1
    local directory = utils.split_path(path)
    local job = utils.join_path(directory, ".editor-" .. utils.getpid() .. "-" .. job_serial)
    local output = utils.join_path(directory, name)
    local kept = utils.join_path(job, name)
    progress_path, started, percent = utils.join_path(job, "progress"), mp.get_time(), 0
    local args = {opts.backend, path, string.format("%.9f", math.min(a, b)),
        string.format("%.9f", math.max(a, b)), job, output, utils.format_json(edits)}
    task = mp.command_native_async({name = "subprocess", args = args, playback_only = false,
        capture_stderr = true}, function(success, result, error_message)
        task = nil
        progress_timer:kill()
        if result and result.killed_by_us then message = "Export cancelled"
        elseif success and result.status == 0 then
            message = "Saved " .. name
            if settings then output_name = choose_output(settings.format) end
        else
            local detail = (result and result.stderr or ""):gsub("%s+$", ""):sub(-600)
            if detail == "" then detail = error_message or result and result.error_string or "unknown error" end
            message = result and result.status == 2 and "Export kept at " .. kept or "Export failed: " .. detail
            mp.msg.error(message)
        end
        notify(message, 6)
        draw()
    end)
    message = nil
    progress_timer:resume()
    draw()
end

cancel = function()
    if task then mp.abort_async_command(task)
    elseif editing then dismiss() end
end

local function set_time(which)
    edit_text(which == "first" and "In point · seconds or MM:SS" or "Out point · seconds or MM:SS",
        clock(which == "first" and first or last), function(text)
        local minutes, seconds = text:match("^(%d+):([%d.]+)$")
        local value = minutes and tonumber(seconds) and tonumber(minutes) * 60 + tonumber(seconds) or tonumber(text)
        if not value or value < 0 or value > mp.get_property_number("duration", 0) then
            notify("Invalid timestamp") return
        end
        if which == "first" then first = math.min(value, last - 0.001)
        else last = math.max(value, first + 0.001) end
        mp.commandv("seek", value, "absolute+exact")
        draw()
    end)
end

reset = function()
    first, last, crop = 0, mp.get_property_number("duration", 0), nil
    editing, message, drag = false, nil, nil
    bindings()
    settings = {profile = "original", label = "Original quality", format = "source", video = "source", audio = "copy", quality = "high"}
    output_name = choose_output(settings.format)
    draw()
end

local function edit_mode()
    local width, height, rotation = source_size()
    if width == 0 then notify("No video to crop") return end
    if rotation % 90 ~= 0 then notify("Crop requires rotation in 90° steps") return end
    editing, drag = not editing, nil
    if editing then
        crop = crop and {unpack(crop)} or {0, 0, width, height}
    elseif crop[1] == 0 and crop[2] == 0 and crop[3] == width and crop[4] == height then
        crop = nil
    end
    bindings()
    layout()
end

local function export_edits()
    if not output_name or output_name == "" or output_name:find("[/\\]") or output_name == "." or output_name == ".." then
        notify("Choose an output filename without directories") return
    end
    local edits = {}
    for key, value in pairs(settings) do edits[key] = value end
    edits.source_width, edits.source_height, edits.rotation = source_size()
    if crop and (crop[1] ~= 0 or crop[2] ~= 0 or crop[3] ~= edits.source_width or crop[4] ~= edits.source_height) then
        edits.crop = crop
    end
    start_export(first, last, edits, output_name)
end

local function export_menu()
    local entries = {
        {label = "Export selection", action = export_edits},
        {label = "Preset · " .. settings.label, action = function() pick("profiles") end},
        {label = "Container · " .. settings.format, action = function() pick("formats") end},
        {label = "Video · " .. settings.video, action = function() pick("video") end},
        {label = "Audio · " .. settings.audio, action = function() pick("audio") end},
        {label = "Quality · " .. settings.quality, action = function()
            select_value("Encoding quality", {{id = "high", label = "High"}, {id = "balanced", label = "Balanced"},
                {id = "small", label = "Smaller file"}}, settings.quality, function(entry) settings.quality = entry.id end)
        end},
        {label = "Size · " .. (settings.size or "Source dimensions"), action = function()
            edit_text("Fit inside · WIDTHxHEIGHT, blank for source", settings.size, function(value)
                if value == "" or value:match("^%d+x%d+$") then settings.size = value ~= "" and value or nil
                else notify("Use WIDTHxHEIGHT") end
            end)
        end},
        {label = "Frame rate · " .. (settings.fps or "Source frame rate"), action = function()
            edit_text("Frames per second · blank for source", settings.fps, function(value)
                if value == "" or value:match("^[%d./]+$") then settings.fps = value ~= "" and value or nil
                else notify("Invalid frame rate") end
            end)
        end},
        {label = "Output · " .. output_name, action = function()
            edit_text("Output filename", output_name, function(value) output_name = value end)
        end},
        {label = "Advanced FFmpeg options", action = function()
            edit_text("Extra FFmpeg output arguments", settings.args, function(value) settings.args = value ~= "" and value or nil end)
        end},
        {label = "Reset edits", action = reset},
    }
    load_capabilities()
    select_value("Export", entries, nil, function(entry) entry.action() end)
end

local function video_rect()
    local d = mp.get_property_native("osd-dimensions")
    return d.ml * W / d.w, d.mt * H / d.h,
        (d.w - d.ml - d.mr) * W / d.w, (d.h - d.mt - d.mb) * H / d.h
end

local function mouse_position()
    local x, y = mp.get_mouse_pos()
    local w, h = mp.get_osd_size()
    return x * W / w, y * H / h
end

local function crop_point(x, y)
    local vx, vy, vw, vh = video_rect()
    local sw, sh = source_size()
    return math.floor(clamp((x - vx) / vw, 0, 1) * sw + 0.5),
        math.floor(clamp((y - vy) / vh, 0, 1) * sh + 0.5)
end

local function crop_target(x, y)
    local vx, vy, vw, vh = video_rect()
    local sw, sh = source_size()
    local l, t = vx + crop[1] / sw * vw, vy + crop[2] / sh * vh
    local r, b = l + crop[3] / sw * vw, t + crop[4] / sh * vh
    local near_x, near_y = x >= l - 12 and x <= r + 12, y >= t - 12 and y <= b + 12
    local horizontal = near_y and (math.abs(x - l) <= 12 and "w" or math.abs(x - r) <= 12 and "e") or ""
    local vertical = near_x and (math.abs(y - t) <= 12 and "n" or math.abs(y - b) <= 12 and "s") or ""
    if horizontal ~= "" or vertical ~= "" then return vertical .. horizontal end
    return x >= l and x <= r and y >= t and y <= b and "move" or "new"
end

local function move()
    if not drag then return end
    local x, y = mouse_position()
    local cx, cy = crop_point(x, y)
    local sw, sh = source_size()
    local l, t, w, h = unpack(drag.crop)
    local r, b = l + w, t + h
    if drag.mode == "move" then
        crop = {clamp(l + cx - drag.x, 0, sw - w), clamp(t + cy - drag.y, 0, sh - h), w, h}
    elseif drag.mode == "new" then
        l, t = math.min(drag.x, cx), math.min(drag.y, cy)
        l, t = math.min(l, sw - 2), math.min(t, sh - 2)
        crop = {l, t, math.min(sw - l, math.max(2, math.abs(cx - drag.x))),
            math.min(sh - t, math.max(2, math.abs(cy - drag.y)))}
    else
        if drag.mode:find("w") then l = clamp(cx, 0, r - 2) end
        if drag.mode:find("e") then r = clamp(cx, l + 2, sw) end
        if drag.mode:find("n") then t = clamp(cy, 0, b - 2) end
        if drag.mode:find("s") then b = clamp(cy, t + 2, sh) end
        crop = {l, t, r - l, b - t}
    end
    draw(true)
end

local function mouse(event)
    if event.event == "up" then
        if drag then move() end
        drag = nil
        ui.release()
        draw()
        return
    end
    if event.event ~= "down" or prompting or not editing then return end
    local x, y = mouse_position()
    local w, h = mp.get_osd_size()
    if ui.hit_test(x * w / W, y * h / H) then ui.press() return end
    local cx, cy = crop_point(x, y)
    drag = {mode = event.new and "new" or crop_target(x, y), x = cx, y = cy, crop = {unpack(crop)}}
end

local function nudge(dx, dy, resize)
    if not editing or drag then return end
    local sw, sh = source_size()
    if resize then
        crop[3], crop[4] = clamp(crop[3] + dx, 2, sw - crop[1]), clamp(crop[4] + dy, 2, sh - crop[2])
    else
        crop[1], crop[2] = clamp(crop[1] + dx, 0, sw - crop[3]), clamp(crop[2] + dy, 0, sh - crop[4])
    end
    draw()
end

layout = function()
    local w, h = mp.get_osd_size()
    if w <= 0 or h <= 0 then return end
    local scale = mp.get_property_number("display-hidpi-scale", 1)
    W, H = w / scale, h / scale
    draw()
end

dismiss = function()
    if editing then edit_mode() end
end

draw = function(crop_only)
    if not crop_only then
        local selected = settings and (first > 0 or last < mp.get_property_number("duration", 0))
        local controls = editing and {
            {id = "in", text = "In ", range = "a"},
            {id = "out", text = "Out ", range = "b"},
        } or {}
        ui.update({
            enabled = not prompting,
            range = (editing or selected) and {a = first, b = last, handles = editing} or nil,
            controls = controls,
        })
    end
    if not editing or prompting then handles_overlay:remove() end
    if task then
        overlay.res_x, overlay.res_y = 0, 0
        overlay.data = "{\\an8\\fs22\\bord2}" .. string.format("Exporting · %d%% · %ds · %s cancel", percent or 0,
            mp.get_time() - started, opts.cancel_key)
        overlay:update()
        return
    elseif not crop then
        overlay:remove()
        return
    end
    local a = assdraw.ass_new()
    local function box(x, y, w, h, color, alpha)
        if w <= 0 or h <= 0 then return end
        a:new_event()
        a:append(string.format("{\\an7\\bord0\\shad0\\1c&H%s&\\1a&H%s&}", color, alpha or "00"))
        a:pos(0, 0) a:draw_start() a:rect_cw(x, y, x + w, y + h) a:draw_stop()
    end
    local vx, vy, vw, vh = video_rect()
    local sw, sh = source_size()
    local l, t = vx + crop[1] / sw * vw, vy + crop[2] / sh * vh
    local r, b = l + crop[3] / sw * vw, t + crop[4] / sh * vh
    box(vx, vy, vw, t - vy, "000000", "60")
    box(vx, b, vw, vy + vh - b, "000000", "60")
    box(vx, t, l - vx, b - t, "000000", "60")
    box(r, t, vx + vw - r, b - t, "000000", "60")
    if editing and not prompting then
        box(l, t, r - l, 2, fg) box(l, b - 2, r - l, 2, fg)
        box(l, t, 2, b - t, fg) box(r - 2, t, 2, b - t, fg)
    end
    local handles = {{l,t,"nw"},{(l+r)/2,t,"n"},{r,t,"ne"},{l,(t+b)/2,"w"},
        {r,(t+b)/2,"e"},{l,b,"sw"},{(l+r)/2,b,"s"},{r,b,"se"}}
    local capture = drag ~= nil
    overlay.res_x, overlay.res_y, overlay.data = W, H, a.text
    overlay:update()
    if not editing or prompting then return end
    local mx, my = mouse_position()
    local target = drag and drag.mode or crop_target(mx, my)
    a = assdraw.ass_new()
    for _, handle in ipairs(handles) do
        local x, y = clamp(handle[1], 5, W - 5), clamp(handle[2], 5, H - 5)
        box(x - 5, y - 5, 10, 10, target == handle[3] and accent or fg)
        if math.abs(mx - x) <= 12 and math.abs(my - y) <= 12 then capture = true end
    end
    handles_overlay.res_x, handles_overlay.res_y, handles_overlay.data = W, H, a.text
    handles_overlay:update()
    local w, h = mp.get_osd_size()
    if capture ~= edge_capture then
        edge_capture = capture
        if capture then mp.enable_key_bindings("editor-crop-edge")
        else mp.disable_key_bindings("editor-crop-edge") end
    end
    local osc = mp.get_property_native("user-data/osc/margins") or {}
    mp.set_mouse_area(0, 0, w, h * (1 - (osc.b or 0)), "editor-crop")
    mp.set_mouse_area(0, 0, w, h, "editor-crop-edge")
end

bindings = function()
    for _, section in ipairs({"editor-keys", "editor-crop", "editor-crop-edge", "editor-crop-keys"}) do
        mp.disable_key_bindings(section)
    end
    edge_capture = false
    if editing and not saved.visibility then
        saved.visibility = mp.get_property_native("user-data/osc/visibility")
        if saved.visibility then mp.commandv("script-message", "osc-visibility", "always", "no-osd") end
    elseif not editing and saved.visibility then
        mp.commandv("script-message", "osc-visibility", saved.visibility, "no-osd")
        saved.visibility = nil
    end
    if editing and not prompting then
        mp.enable_key_bindings("editor-keys")
        mp.enable_key_bindings("editor-crop")
        mp.enable_key_bindings("editor-crop-keys")
    end
end

local function mark_point(which)
    local position = mp.get_property_number("time-pos", 0)
    if which == "first" then first = clamp(position, 0, last - 0.001)
    else last = clamp(position, first + 0.001, mp.get_property_number("duration", 0)) end
    draw()
end

local crop_mouse = {
    {"MBTN_LEFT", nil, function() mouse({event = "down"}) end, function() mouse({event = "up"}) end},
    {"Shift+MBTN_LEFT", nil, function() mouse({event = "down", new = true}) end, function() mouse({event = "up"}) end},
    {"MBTN_LEFT_DBL", function() end},
}
mp.set_key_bindings(crop_mouse, "editor-crop", "force")
mp.set_key_bindings(crop_mouse, "editor-crop-edge", "force")
local crop_keys = {}
for _, direction in ipairs({{"LEFT", -1, 0}, {"RIGHT", 1, 0}, {"UP", 0, -1}, {"DOWN", 0, 1}}) do
    for _, modifier in ipairs({{"", 1, false}, {"Shift+", 1, true}, {"Ctrl+", 10, false}, {"Ctrl+Shift+", 10, true}}) do
        crop_keys[#crop_keys + 1] = {modifier[1] .. direction[1], function()
            nudge(direction[2] * modifier[2], direction[3] * modifier[2], modifier[3])
        end}
    end
end
mp.set_key_bindings(crop_keys, "editor-crop-keys", "force")
mp.set_key_bindings({
    {"ESC", dismiss},
    {"ENTER", dismiss},
    {"i", function() mark_point("first") end},
    {"o", function() mark_point("last") end},
}, "editor-keys", "force")
mp.add_forced_key_binding("e", "mpv-splice-edit", function() if settings and not prompting then edit_mode() end end)
mp.add_forced_key_binding(opts.cancel_key, "mpv-splice-cancel", function() if not prompting then cancel() end end)
mp.observe_property("osd-dimensions", "native", layout)
mp.observe_property("user-data/osc/margins", "native", layout)
mp.observe_property("mouse-pos", "native", function()
    if editing and not prompting then if drag then move() else draw(true) end end
end)
mp.register_event("start-file", function()
    if prompting then input.terminate() end
    editing, drag = false, nil
    bindings()
    settings, first, last, crop = nil, nil, nil, nil
    draw()
end)
mp.register_event("file-loaded", function()
    if not mp.get_property("path") or mp.get_property_bool("demuxer-via-network", false)
        or not mp.get_property_number("duration") or source_size() == 0 then return end
    reset()
end)

-- Playback entries follow mpv contributors’ select.lua menu (LGPL-2.1-or-later).
local function player_menu()
    local counts, text_sub = {sub = 0, audio = 0, video = 0}, false
    for _, track in ipairs(mp.get_property_native("track-list", {})) do
        if counts[track.type] then counts[track.type] = counts[track.type] + 1 end
        if track.type == "sub" and track["main-selection"] == 0 and track.codec ~= "dvd_subtitle" and track.codec ~= "hdmv_pgs_subtitle" then
            text_sub = true
        end
    end
    local entries = {{label = task and "Cancel export" or "Export",
        action = function() if task then cancel() else export_menu() end end}}
    local function add(label, binding, available)
        if available == false then return end
        entries[#entries + 1] = {label = label, action = function() mp.commandv("script-binding", binding) end}
    end
    add("Subtitles", "select/select-sid", counts.sub > 0)
    add("Secondary subtitles", "select/select-secondary-sid", counts.sub > 1)
    add("Subtitle lines", "select/select-subtitle-line", text_sub)
    add("Audio tracks", "select/select-aid", counts.audio > 1)
    add("Video tracks", "select/select-vid", counts.video > 1)
    add("Playlist", "select/select-playlist", mp.get_property_number("playlist-count", 0) > 1)
    add("Chapters", "select/select-chapter", #mp.get_property_native("chapter-list", {}) > 0)
    add(mp.get_property("current-demuxer") == "disc" and "Titles" or "Editions", "select/select-edition", mp.get_property_number("edition-list/count", 0) > 1)
    add("Audio devices", "select/select-audio-device", counts.audio > 0)
    add("Key bindings", "select/select-binding")
    add("History", "select/select-watch-history")
    add("Watch later", "select/select-watch-later")
    add("Playback statistics", "stats/display-page-1-toggle")
    add("File information", "stats/display-page-5-toggle")
    add("Edit config file", "select/edit-config-file")
    add("Edit key bindings", "select/edit-input-conf")
    add("Help", "stats/display-page-4-toggle")
    add("Online documentation", "select/open-docs")
    select_value("", entries, nil, function(entry) entry.action() end)
end

ui.action = function(id, value)
    if prompting then return end
    if id == "menu" then
        if settings then player_menu() else mp.command("script-binding select/menu") end
        return
    end
    if not settings then return end
    if id == "in" then set_time("first")
    elseif id == "out" then set_time("last")
    elseif id == "range-end" then draw()
    elseif id == "range-a" or id == "range-b" then
        local time = tonumber(value)
        if not time then return end
        if id == "range-a" then first = clamp(time, 0, last - 0.001)
        else last = clamp(time, first + 0.001, mp.get_property_number("duration", 0)) end
    end
end

draw()
