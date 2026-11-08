-- Splice UI, derived from ModernZ (https://github.com/Samillion/ModernZ),
-- mpv-osc-modern by maoiscat and the ModernX forks by cyl0 and dexeonify.
-- The speed ruler is adapted from tomasklaen/uosc's Speed.lua.
-- Licensed under LGPL-2.1. See LICENSE.LGPL-2.1.

local assdraw = require "mp.assdraw"
local ui = {}
local edits = {controls = {}}
local overlay = mp.create_osd_overlay("ass-events")
overlay.z = 1000
local W, H, duration, position, speed = 1280, 720, 0, 0, 1
local chapters, chapter, title = {}, -1, ""
local visibility, shown, console, inside = "auto", false, false, false
local opacity, ruler, last_frame = 0, 0, mp.get_time()
local drag, pending_seek, preview_seek, hover, click_enabled
local regions, speed_box = {}, nil
local remaining, milliseconds = false, false
local thumbnail, thumb_request = {}, nil
local request, render
local interval, font, published_margin = 1 / 60, "sans-serif", nil
local white, accent, handle = "FFFFFF", "3282FF", "0865C9"
local paths = {
    trim = "m 2 5 b 2 1 8 1 8 5 b 8 9 2 9 2 5 m 4 5 b 4 6.5 6 6.5 6 5 b 6 3.5 4 3.5 4 5 m 2 19 b 2 15 8 15 8 19 b 8 23 2 23 2 19 m 4 19 b 4 20.5 6 20.5 6 19 b 6 17.5 4 17.5 4 19 m 6 7 l 8 6 22 21 19 21 m 6 17 l 8 18 22 3 19 3",
    crop = "m 5 1 l 7 1 7 17 23 17 23 19 5 19 m 1 5 l 19 5 19 23 17 23 17 7 1 7",
    download = "m 11 2 l 13 2 13 14 18 9 20 11 12 19 4 11 6 9 11 14 m 2 21 l 22 21 22 23 2 23",
    downloading = "m 4 3 l 12 11 20 3 22 5 14 13 22 21 20 23 12 15 4 23 2 21 10 13 2 5",
}

local function send(command) mp.command_native_async(command, function() end) end
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end
local pointer = {x = 0, y = 0}
local function mouse() return pointer.x, pointer.y end
local function hit(box, x, y)
    return box and x >= box.x and x <= box.x + box.w and y >= box.y and y <= box.y + box.h
end
local function clock(value, precise)
    value = math.max(0, value)
    local hours, minutes = math.floor(value / 3600), math.floor(value / 60) % 60
    local seconds = precise and string.format("%06.3f", value % 60) or string.format("%02d", math.floor(value % 60))
    return (hours > 0 and string.format("%d:%02d:", hours, minutes) or string.format("%d:", minutes)) .. seconds
end
local function control_text(control)
    return (control.text or "") .. clock(edits.range and edits.range[control.range] or 0, true)
end
local function action(id, value)
    if ui.action and edits.enabled ~= false then ui.action(id, value) end
end
local function clear_thumbnail()
    if thumb_request then send({"script-message-to", "thumbfast", "clear"}) end
    thumb_request = nil
end
local bar_height = 86
local function over_controls(x, y)
    return y >= H - bar_height or x >= 25 and x <= W - 25 and y >= 20 and y <= (chapter >= 0 and 74 or 50)
end
local function enabled() return not console and not (edits.enabled == false and #edits.controls > 0) end
local function visible() return enabled() and duration > 0 and visibility ~= "never" and (visibility == "always" or shown or drag ~= nil) end
local function input(enabled_now)
    if enabled_now == click_enabled then return end
    click_enabled = enabled_now
    for _, section in ipairs({"splice-input", "splice-heading"}) do
        if enabled_now then mp.enable_key_bindings(section) else mp.disable_key_bindings(section) end
    end
end
local hide_timer = mp.add_timeout(1.5, function()
    if not inside or not over_controls(mouse()) then shown = false end
    request()
end)
hide_timer:kill()
local function show()
    shown = true
    hide_timer:kill()
    hide_timer:resume()
    request()
end
local function set_visibility(mode)
    if mode ~= "auto" and mode ~= "always" and mode ~= "never" then return end
    visibility = mode
    mp.set_property_native("user-data/osc/visibility", mode)
    if mode == "auto" then show() else request() end
end
local function add_region(id, x, y, w, h, control)
    local box = {id = id, x = x, y = y, w = w, h = h, control = control}
    regions[#regions + 1] = box
    return box
end
local function layout()
    local width, height = mp.get_osd_size()
    if width > 0 and height > 0 then W, H = width, height end
    regions = {}
    add_region("seek", 15, H - 23, W - 30, 18)
    local x, row = W - 37, H - 44
    if W >= 600 then add_region("menu", x - 12, row - 12, 24, 24) x = x - 45 end
    for i = #edits.controls, 1, -1 do
        local control = edits.controls[i]
        if not control.range then
            add_region(control.id, x - 12, row - 12, 24, 24, control)
            x = x - 45
        end
    end
    local left = 25
    local reserve = math.max(292, #(clock(duration, true) .. clock(duration, true)) * 9 + 40)
    local fields = false
    for _, control in ipairs(edits.controls) do
        if control.range then
            fields = true
            local width = math.max(140, #control_text(control) * 8 + 8)
            add_region(control.id, left, row - 12, width, 24, control)
            left = left + width + 12
        end
    end
    if not fields then add_region("time", 25, row - 12, #(clock(duration, true) .. clock(duration, true)) * 9 + 24, 24) end
    local speed_left, speed_right = 25 + reserve + 20, x + 12
    local height = 32 * 1.3
    local width = math.min(height * 3.5, speed_right - speed_left)
    speed_box = width >= height * 2 and {x = clamp(W / 2 - width / 2, speed_left, speed_right - width), y = row - height / 2 - 14, w = width, h = height} or nil
    if speed_box then add_region("speed", speed_box.x, speed_box.y, width, height + 14) end
    add_region("title", 25, 20, math.max(0, W - 50), 30)
    if chapter >= 0 then add_region("chapter", 25, 52, math.max(0, W - 50), 22) end
    mp.set_mouse_area(0, H - bar_height, W, H, "splice-input")
    mp.set_mouse_area(25, 20, W - 25, chapter >= 0 and 74 or 50, "splice-heading")
end
local function target_at(x, y)
    for i = #regions, 1, -1 do if hit(regions[i], x, y) then return regions[i] end end
end
local function time_at(x)
    return clamp((x - 22) / math.max(1, W - 44), 0, 1) * duration
end
local function x_at(value) return 22 + clamp(value / math.max(duration, 0.001), 0, 1) * (W - 44) end
local function seek(value, exact)
    send({"seek", value, exact and "absolute+exact" or "absolute+keyframes"})
end
local function update_drag(x)
    if not drag then return end
    x = x or mouse()
    if drag.kind == "speed" then
        drag.value = clamp(drag.speed - (x - drag.x) / drag.spacing * 0.1, 0.01, 100)
        local value = math.max(0.01, math.floor(drag.value * 10 + 0.5) / 10)
        if value ~= speed then mp.set_property_number("speed", value) end
        return
    end
    if drag.kind == "button" then return end
    local value = time_at(x)
    if drag.kind ~= "seek" then
        if not edits.range then return end
        value = drag.kind == "a" and clamp(value, 0, edits.range.b - 0.001)
            or clamp(value, edits.range.a + 0.001, duration)
        edits.range[drag.kind] = value
        action("range-" .. drag.kind, value)
    end
    if value ~= drag.value then drag.value, preview_seek = value, value end
end
local function stop_drag(finalize)
    local held = drag
    drag, preview_seek = nil, nil
    if held and (held.kind == "seek" or held.kind == "a" or held.kind == "b") then
        if finalize then
            pending_seek = {value = held.value, time = mp.get_time()}
            seek(held.value, true)
        end
        if held.was_paused == false then mp.set_property_bool("pause", false) end
    end
    return held
end
local function release()
    if not drag then return end
    pointer.x, pointer.y = mp.get_mouse_pos()
    update_drag()
    local held = stop_drag(true)
    if held.kind == "a" or held.kind == "b" then action("range-end")
    elseif held.kind == "button" then
        local x, y = mouse()
        if hit(held.box, x, y) then
            local id = held.box.id
            if held.box.control then action(id)
            elseif id == "menu" then mp.command("script-binding select/menu")
            elseif id == "time" then remaining = not remaining
            elseif id == "title" then mp.command("script-binding stats/display-page-5")
            elseif id == "chapter" then mp.command("script-binding select/select-chapter") end
        end
    end
    request()
end
local function press()
    pointer.x, pointer.y = mp.get_mouse_pos()
    local x, y = mouse()
    local box = target_at(x, y)
    if not box then return end
    show()
    if box.id == "speed" then
        drag = {kind = "speed", x = x, speed = speed, value = speed, spacing = speed_box.w / 11}
    elseif box.id == "seek" then
        local kind = "seek"
        if edits.range and edits.range.handles then
            if math.abs(x - x_at(edits.range.a)) <= 10 then kind = "a"
            elseif math.abs(x - x_at(edits.range.b)) <= 10 then kind = "b" end
        end
        drag = {kind = kind, was_paused = mp.get_property_bool("pause")}
        if not drag.was_paused then mp.set_property_bool("pause", true) end
        update_drag()
    else drag = {kind = "button", box = box} end
    request()
end
local function secondary()
    local x, y = mouse()
    local box = target_at(x, y)
    if not box then return end
    if box.id == "speed" then mp.set_property_number("speed", 1)
    elseif box.id == "time" then milliseconds = not milliseconds
    elseif box.id == "seek" then
        local nearest, distance
        for _, entry in ipairs(chapters) do
            local d = math.abs(x_at(entry.time) - x)
            if not distance or d < distance then nearest, distance = entry.time, d end
        end
        if nearest then seek(nearest, true) end
    elseif box.id == "title" then mp.command("script-binding select/select-watch-history")
    elseif box.id == "chapter" then mp.commandv("show-text", "${chapter-list}", 3000)
    elseif box.id == "menu" then mp.command("script-binding select/menu") end
    request()
end
local function wheel(direction)
    local x, y = mouse()
    local box = target_at(x, y)
    if not box then return end
    if box.id == "speed" then mp.set_property_number("speed", math.max(0.01, math.floor(speed * 10 + direction + 0.5) / 10))
    elseif box.id == "seek" then mp.commandv("seek", direction * 10, "relative") end
    show()
end

local tick = mp.add_timeout(0, function() render() end)
tick:kill()
request = function()
    if tick:is_enabled() then return end
    tick.timeout = math.max(0, interval - (mp.get_time() - last_frame))
    tick:resume()
end
render = function()
    local now = mp.get_time()
    local dt = math.max(0, now - last_frame)
    last_frame = now
    local target = visible() and 1 or 0
    opacity = target > opacity and math.min(target, opacity + dt / 0.16) or math.max(target, opacity - dt / 0.16)
    if opacity ~= target then request() end
    input(target > 0)
    local margin = target > 0 and bar_height / math.max(H, 1) or 0
    if published_margin ~= margin then
        published_margin = margin
        mp.set_property_native("user-data/osc/margins", {l = 0, r = 0, t = 0, b = margin})
    end
    if opacity <= 0 then overlay.data = "" overlay:remove() clear_thumbnail() return end
    local mx, my = mouse()
    update_drag(mx)
    hover = inside and target_at(mx, my) or nil
    local over_speed = hover and hover.id == "speed" or drag and drag.kind == "speed"
    local ruler_target = over_speed and 1 or 0
    ruler = ruler_target > ruler and math.min(ruler_target, ruler + math.min(dt, 1 / 30) / 0.14)
        or math.max(ruler_target, ruler - math.min(dt, 1 / 30) / 0.14)
    if ruler ~= ruler_target or drag then request() end
    local ass = assdraw.ass_new()
    local function event(color, alpha, x, y, align)
        ass:new_event()
        ass:pos(x or 0, y or 0)
        ass:an(align or 7)
        ass:append(string.format("{\\rDefault\\bord0\\shad0\\blur0\\1c&H%s&\\1a&H%02X&}", color or white,
            math.floor(255 * (1 - opacity * (alpha or 1)))))
    end
    local function box(x, y, w, h, color, alpha, radius)
        if w <= 0 or h <= 0 then return end
        event(color, alpha)
        ass:draw_start()
        ass:round_rect_cw(x, y, x + w, y + h, radius or 0)
        ass:draw_stop()
    end
    local function text(value, x, y, size, color, align, alpha, clip)
        event(color, alpha, x, y, align or 4)
        ass:append(string.format("{\\fn%s\\fs%.2f\\bord1\\3c&H000000&}", font, size))
        if clip then ass:append(string.format("{\\clip(25,0,%d,%d)}", W - 25, H)) end
        ass:append((tostring(value):gsub("\\", "\\\226\129\160"):gsub("{", "\\{"):gsub("\n", "\\N"):gsub("^ ", "\\h"):gsub("\\N ", "\\N\\h")))
    end
    local function icon(name, x, y, color)
        if name == "menu" then
            for offset = -6, 6, 6 do box(x - 1.5, y + offset - 1.5, 3, 3, color, 1, 1.5) end
        elseif paths[name] then
            event(color, 1, x - 12, y - 12)
            ass:append("{\\p1}" .. paths[name] .. "{\\p0}")
        end
    end
    -- A short gradient avoids the large blurred shapes inherited from ModernZ.
    for i = 0, 31 do
        local top = H - bar_height + math.floor(i * bar_height / 32)
        local bottom = H - bar_height + math.floor((i + 1) * bar_height / 32)
        box(0, top, W, bottom - top, "000000", i / 31 * 0.7)
    end
    local function bar(left, right, color, alpha)
        local start = left
        for _, entry in ipairs(chapters) do
            local x = x_at(entry.time)
            if x > left and x < right and entry.time > 0 then
                box(start, H - 16, math.max(0, x - 1.5 - start), 4, color, alpha)
                start = math.max(start, x + 1.5)
            end
        end
        box(start, H - 16, math.max(0, right - start), 4, color, alpha)
    end
    bar(15, W - 15, "999999", 0.6)
    local shown_position = position
    if drag and drag.kind == "seek" then shown_position = time_at(mx)
    elseif pending_seek then
        if math.abs(position - pending_seek.value) < 0.05 or now - pending_seek.time > 1 then pending_seek = nil
        else shown_position = pending_seek.value end
    end
    local knob = x_at(shown_position)
    bar(15, knob, accent)
    local range = edits.range
    if range then
        bar(x_at(range.a), x_at(range.b), "BE9625")
        if range.handles then
            box(x_at(range.a) - 3, H - 23, 6, 18, handle, 1, 2)
            box(x_at(range.b) - 3, H - 23, 6, 18, handle, 1, 2)
        end
    end
    box(knob - 7, H - 21, 14, 14, accent, 1, 7)
    box(knob - 4, H - 18, 8, 8, handle, 1, 4)
    local chapter_entry = chapters[chapter + 1]
    text(title, 25, 35, 24, white, 4, 1, true)
    if chapter_entry then text(chapter_entry.title or "", 25, 63, 16, white, 4, 1, true) end
    for _, region in ipairs(regions) do
        local color = region.control and region.control.active and accent or white
        local hovered = hover == region
        if region.control and not region.control.range or region.id == "menu" then
            if hovered then box(region.x - 6, region.y - 6, region.w + 12, region.h + 12, accent, 0.1, 4) end
            icon(region.control and region.control.icon or "menu", region.x + region.w / 2, H - 44, hovered and accent or color)
        elseif region.control and region.control.range then
            text(control_text(region.control), region.x, H - 44, 16, hovered and accent or white)
        elseif region.id == "time" then
            text((remaining and "−" or "") .. clock(remaining and duration - position or position, milliseconds) .. " / " .. clock(duration, milliseconds), 25, H - 44, 16)
        end
    end
    if speed_box then
        local b, amount = speed_box, ruler * ruler * (3 - 2 * ruler)
        local cx = b.x + b.w / 2
        local spacing = b.w / 11
        local size = math.floor(b.h * 0.48 + 0.5)
        local label_height = math.floor(size * 1.1 + 0.5)
        local emphasis = 0.45 + 0.55 * amount
        box(b.x, b.y, b.w, b.h, "000000", 0.6 * amount, 4)
        local current = drag and drag.kind == "speed" and drag.value or speed
        local nearest = math.floor(current * 10 + 0.5)
        local guide = math.floor(b.h / 7.5)
        local bottom = b.y + b.h - guide
        local top = b.y + label_height
        for i = -5, 5 do
            local notch = nearest + i
            local x = cx + (notch - current * 10) * spacing
            if notch >= 0 and notch <= 1000 then
                local y = top + (bottom - top) * (notch % 10 == 0 and 0 or notch % 5 == 0 and 0.2 or 0.4)
                local width = notch % 10 == 0 and 3 or 2
                event(white, math.min(1, 1.2 - math.abs(x - cx) / (b.w / 2)) * emphasis)
                ass:append("{\\bord1\\3c&H000000&}")
                ass:draw_start()
                ass:rect_cw(x - width / 2, y, x + width / 2, bottom)
                ass:draw_stop()
            end
        end
        event(white, emphasis)
        ass:append("{\\bord1\\3c&H000000&}")
        ass:draw_start()
        ass:move_to(cx, b.y + b.h - 2 - guide)
        ass:line_to(cx + guide, b.y + b.h - 2)
        ass:line_to(cx - guide, b.y + b.h - 2)
        ass:draw_stop()
        event(white, amount, cx, b.y + label_height / 2, 5)
        ass:append(string.format("{\\fn%s\\fs%.2f\\bord1.2\\3c&H000000&}%gx", font, size, math.floor(speed * 100 + 0.5) / 100))
    end
    if hover and hover.id == "seek" then
        local value = time_at(mx)
        local width, height = thumbnail.width or 0, thumbnail.height or 0
        local has_thumb = thumbnail.available and not thumbnail.disabled and width > 0 and height > 0
        local tx = clamp(mx, math.max(70, width / 2 + 18), math.min(W - 70, W - width / 2 - 18))
        local baseline = H - 66
        text(clock(value), tx, baseline, 14, white, 2)
        local top = baseline - 22
        if has_thumb then
            local x, y = math.floor(tx - width / 2), math.floor(top - height)
            box(x - 5, y - 5, width + 10, height + 10, "111111", 1, 4)
            if not thumb_request or math.abs(thumb_request.time - value) > 0.02 or thumb_request.x ~= x or thumb_request.y ~= y then
                send({"script-message-to", "thumbfast", "thumb", tostring(value), tostring(x), tostring(y)})
                thumb_request = {time = value, x = x, y = y}
            end
            top = y - 10
        else clear_thumbnail() end
        local hovered_chapter
        for _, entry in ipairs(chapters) do if entry.time <= value then hovered_chapter = entry end end
        if hovered_chapter and hovered_chapter.title then
            local label = hovered_chapter.title
            local label_width = #label * 8 + 16
            box(tx - label_width / 2, top - 23, label_width, 23, "111111", 0.95, 5)
            text(label, tx, top - 12, 14, white, 5)
        end
    else
        clear_thumbnail()
        if hover and hover.control and hover.control.tooltip then
            local label = hover.control.tooltip
            local width = #label * 7 + 18
            local x = clamp(hover.x + hover.w / 2, width / 2 + 10, W - width / 2 - 10)
            box(x - width / 2, H - 92, width, 24, "111111", 0.95, 5)
            text(label, x, H - 80, 14, white, 5)
        end
    end
    overlay.res_x, overlay.res_y = W, H
    if overlay.data ~= ass.text then overlay.data = ass.text
        send({name = "osd-overlay", id = overlay.id, format = overlay.format, data = ass.text, res_x = W, res_y = H, z = overlay.z}) end
    -- Publish the current pointer position before a preview seek can present a video frame.
    if preview_seek then local value = preview_seek preview_seek = nil seek(value, false) end
end

ui.update = function(value)
    if drag and (value.enabled == false or (drag.kind == "a" or drag.kind == "b") and not (value.range and value.range.handles)) then stop_drag(true) end
    edits = value
    layout()
    request()
end
local click_bindings = {
    {"MBTN_LEFT", release, press},
    {"Shift+MBTN_LEFT", release, press},
    {"MBTN_RIGHT", secondary},
    {"MBTN_LEFT_DBL", function() end},
    {"WHEEL_UP", function() wheel(1) end},
    {"WHEEL_DOWN", function() wheel(-1) end},
}
for _, section in ipairs({"splice-input", "splice-heading"}) do
    mp.set_key_bindings(click_bindings, section, "force")
    mp.disable_key_bindings(section)
end
mp.observe_property("mouse-pos", "native", function(_, value)
    if not value then return end
    pointer = value
    inside = value.hover
    if inside then
        if over_controls(value.x, value.y) then show() elseif visibility == "auto" and not drag then shown = false end
    else release() shown = false end
    request()
end)
mp.register_script_message("osc-visibility", set_visibility)
mp.register_script_message("osc-show", show)
mp.register_script_message("osc-hide", function() shown = false request() end)
mp.register_script_message("thumbfast-info", function(value)
    thumbnail = require("mp.utils").parse_json(value) or {}
    request()
end)
local function observe(name, accept)
    mp.observe_property(name, "native", function(_, value) accept(value) request() end)
end
observe("duration", function(value) duration = value or 0 layout() end)
observe("time-pos", function(value) position = value or 0 end)
observe("speed", function(value) speed = value or 1 end)
observe("media-title", function(value) title = value or "" end)
observe("chapter", function(value) chapter = value or -1 layout() end)
observe("chapter-list", function(value)
    chapters = value or {}
    table.sort(chapters, function(a, b) return a.time < b.time end)
    layout()
end)
observe("osd-dimensions", function() layout() end)
observe("display-fps", function(value) interval = 1 / (value and value > 0 and clamp(value, 30, 240) or 60) end)
observe("osd-font", function(value) font = value or "sans-serif" end)
observe("seeking", function(value) if value == false then pending_seek = nil end end)
observe("user-data/mpv/console/open", function(value) console = value == true end)
mp.observe_property("pause", "bool", function(_, paused) if paused then show() end end)
mp.register_event("seek", show)
mp.register_event("file-loaded", show)
mp.register_event("start-file", function() stop_drag(false) pending_seek = nil clear_thumbnail() end)
mp.register_event("shutdown", function() clear_thumbnail() mp.del_property("user-data/osc") end)
mp.set_property("osc", "no")
set_visibility("auto")
layout()
return ui
