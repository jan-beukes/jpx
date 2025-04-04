package jpx

import "core:math"
import "core:time"
import "core:log"
import "core:math/ease"
import "core:time/datetime"
import rl "vendor:raylib"

BORDER_THICK :: 1.2
PADDING_FACTOR :: 0.15
FADE_AMMOUNT :: 0.9

PANEL_ANIM_TIME :: 0.3
PANEL_HANDLE_SCALE :: 0.3

STATS_PANEL_MAX_SCALE :: 0.5
PLOT_PANEL_MAX_SCALE :: 0.7

DARK_BLUE :: rl.Color{0x0d, 0x2b, 0x45, 0xff}
BLUE :: rl.Color{0x20, 0x3c, 0x56, 0xff}
DARK_PURPLE :: rl.Color{0x54, 0x4e, 0x68, 0xff}
PURPLE :: rl.Color{0x8d, 0x69, 0x7a, 0xff}
WHITE :: rl.Color{0xff, 0xec, 0xd6, 0xff}
ORANGE :: rl.Color{0xff, 0xaa, 0x5e, 0xff}
BROWN :: rl.Color{0xd0, 0x81, 0x59, 0xff}
PEACH :: rl.Color{0xff, 0xd4, 0xa3, 0xff}

Gui_Colors :: struct {
    bg: rl.Color,
    bg2: rl.Color,
    fg: rl.Color,
    fg2: rl.Color,
    border: rl.Color,
    hover2: rl.Color,
    hover: rl.Color,
    select: rl.Color,
}

COLORS :: Gui_Colors {
    bg = DARK_BLUE,
    bg2 = DARK_PURPLE,
    fg = WHITE,
    fg2 = PEACH,
    hover = BLUE,
    hover2 = PURPLE,
    border = WHITE,
    select = PEACH,
}

Panel_Location :: enum {
    Left,
    Top,
    Right,
    Bottom,
}

Gui_Panel :: struct {
    rect: rl.Rectangle,
    is_open: bool,
    anim_frame: i32,
    location: Panel_Location,
}

Months :: enum {
    January,
    February,
    March,
    April,
    May,
    June,
    July,
    August,
    September,
    October,
    November,
    December,
}

@rodata
month_names := [Months]cstring {
    .January = "January",
    .February = "February",
    .March = "March",
    .April = "April",
    .May = "May",
    .June = "June",
    .July = "July",
    .August = "August",
    .September = "September",
    .October = "October",
    .November = "November",
    .December = "December",
}


g_font: rl.Font
gui_mouse_cursor: rl.MouseCursor

draw_text :: proc(text: cstring, pos: rl.Vector2, size: f32, color: rl.Color) {
    rl.DrawTextEx(g_font, text, pos, size, 0, color)
}

// this just resets gui cursor stuff
gui_begin :: proc() {
    gui_mouse_cursor = .DEFAULT
}

//---Panel stuff---

// panel with all the plots
gui_panel_plots :: proc(panel: ^Gui_Panel, track: Gps_Track, ui_focused: ^bool) {
    // this is makes the forces auto close nicer so im just gonna keep that state in the function
    @static was_force_closed: bool

    // Panel prelude
    rect, handle_rect := get_panel_rects(panel^)
    mouse_pos := rl.GetMousePosition()

    if panel.is_open && rl.CheckCollisionPointRec(mouse_pos, rect) {
        ui_focused^ = true
    }

    if rl.CheckCollisionPointRec(mouse_pos, handle_rect) {
        gui_mouse_cursor = .POINTING_HAND
        ui_focused^ = true
        if rl.IsMouseButtonPressed(.LEFT) {
            panel.is_open = !panel.is_open
            panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        }
    }
    window_height := rl.GetScreenHeight()
    // auto close the panel when it's taking up too much space
    over_max_scale := rect.height > f32(window_height) * PLOT_PANEL_MAX_SCALE 
    if panel.is_open && over_max_scale {
        panel.is_open = !panel.is_open
        panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        was_force_closed = true
    } else if was_force_closed && !over_max_scale {
        panel.is_open = !panel.is_open
        panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        was_force_closed = false
    }

    // draw the rect and handle
    rl.DrawRectangleRec(rect, rl.Fade(DARK_BLUE, FADE_AMMOUNT))
    draw_panel_handle(handle_rect, panel^)

    // exit early
    if !panel.is_open && panel.anim_frame == 0 {
        return
    } else if panel.anim_frame > 0 {
        panel.anim_frame -= 1
    }

    //---Panel Content---
}

gui_panel_stats :: proc(panel: ^Gui_Panel, track: Gps_Track, ui_focused: ^bool) {
    // this is makes the forces auto close nicer so im just gonna keep that state in the function
    @static was_force_closed: bool


    // Panel prelude
    rect, handle_rect := get_panel_rects(panel^)
    mouse_pos := rl.GetMousePosition()

    if panel.is_open && rl.CheckCollisionPointRec(mouse_pos, rect) {
        ui_focused^ = true
    }

    if rl.CheckCollisionPointRec(mouse_pos, handle_rect) {
        gui_mouse_cursor = .POINTING_HAND
        ui_focused^ = true
        if rl.IsMouseButtonPressed(.LEFT) {
            panel.is_open = !panel.is_open
            panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        }
    }
    window_width := rl.GetScreenWidth()
    // auto close the panel when it's taking up too much space
    over_max_scale := rect.width > f32(window_width) * STATS_PANEL_MAX_SCALE 
    if panel.is_open && over_max_scale {
        panel.is_open = !panel.is_open
        panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        was_force_closed = true
    } else if was_force_closed && !over_max_scale {
        panel.is_open = !panel.is_open
        panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        was_force_closed = false
    }

    // draw the rect and handle
    rl.DrawRectangleRec(rect, rl.Fade(DARK_BLUE, FADE_AMMOUNT))
    draw_panel_handle(handle_rect, panel^)

    if !panel.is_open && panel.anim_frame == 0 {
        return
    } else if panel.anim_frame > 0 {
        panel.anim_frame -= 1
    }

    //---Panel Content---

    padding: f32 = rect.width * 0.04
    font_size: f32 = PANEL_SIZE * PADDING_FACTOR * 0.5
    cursor := rl.Vector2{rect.x + padding, rect.y + padding}
    text: cstring

    // we use scissor mode to cut things draw outside the panel
    rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(rect.width), i32(rect.height))

    if track.name != "" {
        text = rl.TextFormat("%s", track.name)
        draw_text(text, cursor, font_size, WHITE)
    }


    // some files dont have any time info
    date, ok := track.metadata.date_time.(datetime.DateTime)
    if ok {
        cursor.y += font_size + padding
        text = rl.TextFormat("%d %s %d %2d:%2d:%2d", date.day, month_names[Months(date.month - 1)], date.year, date.hour,
            date.minute, date.second)
        draw_text(text, cursor, font_size, WHITE)
    }

    if track.duration != 0 {
        cursor.y += 2 * font_size + padding
        hours, mins, _ := time.clock_from_duration(track.duration)
        text = rl.TextFormat("Elapsed time: %dh %dm", hours, mins)
        draw_text(text, cursor, font_size, WHITE)
    }

    cursor.y += font_size + padding
    text = rl.TextFormat("Distance: %.2fkm", track.total_distance / 1000.0)
    draw_text(text, cursor, font_size, WHITE)

    cursor.y += font_size + padding
    text = rl.TextFormat("Elev gain: %.0fm", track.elevation_gain)
    draw_text(text, cursor, font_size, WHITE)

    cursor.y += font_size + padding
    text = rl.TextFormat("Max elev: %.0fm", track.max_elevation)
    draw_text(text, cursor, font_size, WHITE)

    if track.avg_hr > 0 {
        cursor.y += font_size + padding
        text = rl.TextFormat("Avg hr: %d", track.avg_hr)
        draw_text(text, cursor, font_size, WHITE)
    }

    if track.avg_speed > 0 {
        cursor.y += font_size + padding
        if track.type == .Running {
            mpk := (1.0 / track.avg_speed) * (1000.0 / 60.0)
            min := i32(mpk)
            sec := i32(60 * (mpk - math.trunc(mpk)))
            text = rl.TextFormat("Avg pace: %d:%2d /km", min, sec)
        } else {
            kph := (track.avg_speed * 3600) / 1000.0
            text = rl.TextFormat("Avg speed: %.1fkph", kph)
        }
        draw_text(text, cursor, font_size, WHITE)
    }

    rl.EndScissorMode()
}

draw_panel_handle :: proc(rect: rl.Rectangle, panel: Gui_Panel) {
    rl.DrawRectangleRec(rect, DARK_BLUE)
    center := rl.Vector2 {rect.x + (rect.width*0.5), rect.y + (rect.height*0.5)}
    size := min(rect.width, rect.height) * 0.3
    rotation := panel.is_open ? f32(panel.location) * -90.0 : f32(panel.location) * 90.0
    rl.DrawPoly(center, 3, size, rotation, PEACH)
}

// This function uses the panel's location and state (anim_frame and is_open) to calculate the
// transformed rect for the panel and it's handle
get_panel_rects :: proc(panel: Gui_Panel) -> (rl.Rectangle, rl.Rectangle) {
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()
    rect := panel.rect
    // offset the rect
    if panel.location == .Bottom {
        rect.y = f32(window_height) - rect.height
    } else if panel.location == .Right {
        rect.x = f32(window_width) - rect.width
    }

    frame_count := f32(rl.GetFPS()) * PANEL_ANIM_TIME
    t: f32
    if panel.is_open {
        t = ease.cubic_in(1.0 - f32(panel.anim_frame) / f32(frame_count))
    } else {
        t = ease.cubic_out(1.0 - f32(panel.anim_frame) / f32(frame_count))
    }

    // calculate rect and handle rect from animation frame based on location
    draw_rect := rect
    handle_rect: rl.Rectangle
    switch panel.location {
    case .Top:
        dest_y := panel.is_open ? rect.y : rect.y - rect.height
        start_y := panel.is_open ? rect.y - rect.height : rect.y
        draw_rect.y = math.lerp(start_y, dest_y, t)

        // handle rect
        handle_rect.width = rect.height * PANEL_HANDLE_SCALE
        handle_rect.height = handle_rect.width * 0.25
        handle_rect.x = rect.x + (rect.width - handle_rect.width) * 0.5
        // need to account for panel being offset
        handle_rect.y = draw_rect.y + rect.height
    case .Left:
        dest_x := panel.is_open ? rect.x : rect.x - rect.width
        start_x := panel.is_open ? rect.x - rect.width : rect.x
        draw_rect.x = math.lerp(start_x, dest_x, t)

        handle_rect.height = rect.width * PANEL_HANDLE_SCALE
        handle_rect.width = handle_rect.height * 0.25
        handle_rect.y = rect.y + (rect.height - handle_rect.height) * 0.5
        handle_rect.x = draw_rect.x + rect.width
    case .Right:
        dest_x := panel.is_open ? rect.x : rect.x + rect.width
        start_x := panel.is_open ? rect.x + rect.width : rect.x
        draw_rect.x = math.lerp(start_x, dest_x, t)

        handle_rect.height = rect.width * PANEL_HANDLE_SCALE
        handle_rect.width = handle_rect.height * 0.25
        handle_rect.y = rect.y + (rect.height - handle_rect.height) * 0.5
        handle_rect.x = draw_rect.x - handle_rect.width
    case .Bottom:
        dest_y := panel.is_open ? rect.y : rect.y + rect.height
        start_y := panel.is_open ? rect.y + rect.height : rect.y
        draw_rect.y = math.lerp(start_y, dest_y, t)

        handle_rect.width = rect.height * PANEL_HANDLE_SCALE
        handle_rect.height = handle_rect.width * 0.25
        handle_rect.x = rect.x + (rect.width - handle_rect.width) * 0.5
        handle_rect.y = draw_rect.y - handle_rect.height
    }
    return draw_rect, handle_rect
}

gui_button :: proc(rect: rl.Rectangle, text: cstring, ui_focused: ^bool) -> bool {
    mouse_pos := rl.GetMousePosition()

    hover: bool
    pressed: bool
    if rl.CheckCollisionPointRec(mouse_pos, rect) {
        ui_focused^ = true
        hover = true
        gui_mouse_cursor = .POINTING_HAND
        if rl.IsMouseButtonPressed(.LEFT) {
            pressed = true
        }
    }

    // Base rect
    padding := rect.height * PADDING_FACTOR
    font_size := rect.height - 2 * padding
    if hover {
        rl.DrawRectangleRec(rect, COLORS.hover)
    } else {
        rl.DrawRectangleRec(rect, COLORS.bg)
    }
    draw_text(text, {rect.x + padding, rect.y + padding}, font_size, COLORS.fg)
    rl.DrawRectangleLinesEx(rect, BORDER_THICK, COLORS.border)

    return pressed
}

// copyright info
gui_copyright :: proc(rect: rl.Rectangle, style: Layer_Style, ui_focused: ^bool) {
    @(static) expanded: bool

    icon_hover := false
    mouse_pos := rl.GetMousePosition()
    if rl.CheckCollisionPointRec(mouse_pos, rect) {
        icon_hover = true
        ui_focused^ = true
        if rl.IsMouseButtonPressed(.LEFT) {
            expanded = !expanded
        }
        gui_mouse_cursor = .POINTING_HAND
    }

    // attribution links
    if expanded {
        font_size := rect.height * 0.7
        width := style == .Osm ? rect.width * 6.5 : rect.width * 10.5 // Osm will take less

        expanded_rect := rl.Rectangle {
            x = rect.x - width + BORDER_THICK,
            y = rect.y,
            width = width,
            height = rect.height,
        }
        if rl.CheckCollisionPointRec(mouse_pos, expanded_rect) do ui_focused^ = true

        rl.DrawRectangleRec(expanded_rect, WHITE)
        rl.DrawRectangleLinesEx(expanded_rect, BORDER_THICK, DARK_BLUE)

        // OSM
        text: cstring = "(c) OpenStreetMap"
        text_width := f32(rl.MeasureText(text, i32(font_size)))
        text_rect := rl.Rectangle {
            x = expanded_rect.x + BORDER_THICK,
            y = expanded_rect.y + BORDER_THICK,
            width = text_width,
            height = rect.height,
        }
        text_hover := false
        if rl.CheckCollisionPointRec(mouse_pos, text_rect) {
            text_hover = true
            gui_mouse_cursor = .POINTING_HAND
            if rl.IsMouseButtonPressed(.LEFT) {
                rl.OpenURL("https://www.openstreetmap.org/about")
            }
        }
        color := text_hover ? rl.BLUE : rl.BLACK
        draw_text(text, {text_rect.x, text_rect.y}, font_size, color)

        // Other providers
        if style != .Osm {
            if style == .Jawg {
                text = "(c) Jawg" 
            } else {
                text = "(c) Mapbox" 
            }
            text_rect.x += text_width + 0.5*font_size
            text_rect.width = f32(rl.MeasureText(text, i32(font_size)))
            text_hover = false
            if rl.CheckCollisionPointRec(mouse_pos, text_rect) {
                text_hover = true
                gui_mouse_cursor = .POINTING_HAND
                if rl.IsMouseButtonPressed(.LEFT) {
                    if style == .Jawg {
                        rl.OpenURL("https://www.jawg.io")
                    } else {
                        rl.OpenURL("https://www.mapbox.com/about/maps")
                    }
                }
            }
            color = text_hover ? rl.BLUE : rl.BLACK
            draw_text(text, {text_rect.x, text_rect.y}, font_size, color)
        }

    }

    // draw the icon last
    font_size := rect.height
    if icon_hover || expanded {
        rl.DrawRectangleRec(rect, PEACH)
    } else {
        rl.DrawRectangleRec(rect, WHITE)
    }
    rl.DrawRectangleLinesEx(rect, BORDER_THICK, DARK_BLUE)
    draw_text("i", {rect.x + rect.width / 4.0, rect.y}, font_size, rl.DARKBLUE)
}

// Gui drop down, items will all be the same size as rect
// ui_focus gets set when the mouse is hovering over the dropdown
gui_drop_down :: proc(rect: rl.Rectangle, text: cstring, items: []cstring, expanded: ^bool, selected: ^int, ui_focus: ^bool) -> bool {

    hover_item := -1
    did_select: bool

    count := len(items)
    rect := rect
    base_rect := rect
    mouse_pos := rl.GetMousePosition()

    if rl.CheckCollisionPointRec(mouse_pos, base_rect) {
        if rl.IsMouseButtonPressed(.LEFT) {
            expanded^ = !expanded^
        }
        hover_item = 0
    }
    if expanded^ {
        for i in 0..<count {
            rect.y += rect.height
            if rl.CheckCollisionPointRec(mouse_pos, rect) {
                if rl.IsMouseButtonPressed(.LEFT) {
                    did_select = true
                    selected^ = i
                }
                hover_item = i + 1
            }
        }
    }

    padding := rect.height * PADDING_FACTOR
    font_size := rect.height - 2 * padding

    // drop down
    rect = base_rect
    if expanded^ {
        hover := hover_item == -1 ? selected^ : hover_item - 1
        for i in 0..<count {
            rect.y += rect.height
            if i == hover {
                rl.DrawRectangleRec(rect, rl.Fade(COLORS.hover, FADE_AMMOUNT))
            } else {
                rl.DrawRectangleRec(rect, rl.Fade(COLORS.bg, FADE_AMMOUNT))
            }
            draw_text(items[i], {rect.x + padding, rect.y + padding}, font_size, COLORS.fg)
        }
        rect.y = base_rect.y + rect.height
        rect.height *= f32(count)
        rl.DrawRectangleLinesEx(rect, BORDER_THICK, COLORS.border)
    }

    // Base rect
    if hover_item == 0 {
        rl.DrawRectangleRec(base_rect, COLORS.hover)
    } else {
        rl.DrawRectangleRec(base_rect, COLORS.bg)
    }
    draw_text(text, {rect.x + padding, base_rect.y + padding}, font_size, COLORS.fg)
    rl.DrawRectangleLinesEx(base_rect, BORDER_THICK, COLORS.border)


    if hover_item != -1 && !ui_focus^ {
        ui_focus^ = true
    }

    return did_select
}
