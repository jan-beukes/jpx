package jpx

import "core:math"
import "core:time"
import "core:math/ease"
import "core:time/datetime"
import sa "core:container/small_array"
import rl "vendor:raylib"

BORDER_THICK :: 1.2
PADDING_FACTOR :: 0.2
FADE_AMMOUNT :: 0.9

PANEL_ANIM_TIME :: 0.2
PANEL_OFFSET :: 20
PANEL_HANDLE_SCALE :: 0.1

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
    Top,
    Bottom,
    Left,
    Right,
}

Gui_Panel :: struct {
    rect: rl.Rectangle,
    is_open: bool,
    anim_frame: i32,
    location: Panel_Location,
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

gui_debug :: proc(x, y: f32) {
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()

    height: f32 = state.is_track_open ? 0.5 : 0.15
    overlay := rl.Vector2 {
        f32(WINDOW_HEIGHT) * 0.35,
        f32(WINDOW_HEIGHT) * 0.9,
    }
    rl.DrawRectangleRounded({-PANEL_OFFSET, y, overlay.x, overlay.y}, 0.2, 20, rl.Fade(DARK_BLUE, FADE_AMMOUNT))

    padding := overlay.y * 0.02
    font_size: f32 = WINDOW_HEIGHT / 40.0

    cursor := rl.Vector2{x, y}
    cursor.y += padding
    draw_text(rl.TextFormat("Cache: %d tiles", len(state.cache)), cursor, font_size, PEACH)

    cursor.y += font_size + padding
    draw_text(rl.TextFormat("Zoom: %d | %.1fx", state.map_screen.zoom, state.map_screen.scale), cursor, font_size, PEACH)

    mouse_coord := mercator_to_coord(screen_to_map(state.map_screen, rl.GetMousePosition()),
        state.map_screen.zoom)
    cursor.y += font_size + padding
    draw_text(rl.TextFormat("Mouse: [%.3f, %.3f]", mouse_coord.x, mouse_coord.y),
        cursor, font_size, PEACH)

    // Track
    if state.is_track_open {
        cursor.y += 2 * font_size + padding
        text := rl.TextFormat("TRACK:")
        draw_text(text, cursor, font_size, WHITE)

        cursor.y += font_size + padding
        text = rl.TextFormat("%s", state.track.name)
        draw_text(text, cursor, font_size, WHITE)

        // some files dont have any time info
        date, ok := state.track.metadata.date_time.(datetime.DateTime)
        if ok {
            cursor.y += font_size + padding
            text = rl.TextFormat("%d-%d-%d %d:%d:%d", date.day, date.month, date.year, date.hour,
                date.minute, date.second)
            draw_text(text, cursor, font_size, WHITE)
        }

        cursor.y += 2 * font_size + padding
        hours, mins, _ := time.clock_from_duration(state.track.duration)
        text = rl.TextFormat("Total time: %dh %dm", hours, mins)
        draw_text(text, cursor, font_size, WHITE)

        cursor.y += font_size + padding
        text = rl.TextFormat("Distance: %.2fkm", state.track.total_distance / 1000.0)
        draw_text(text, cursor, font_size, WHITE)

        cursor.y += font_size + padding
        text = rl.TextFormat("Elev gain: %.0fm", state.track.elevation_gain)
        draw_text(text, cursor, font_size, WHITE)

        cursor.y += font_size + padding
        text = rl.TextFormat("Max elev: %.0fm", state.track.max_elevation)
        draw_text(text, cursor, font_size, WHITE)

        if state.track.avg_hr > 0 {
            cursor.y += font_size + padding
            text = rl.TextFormat("Avg hr: %d", state.track.avg_hr)
            draw_text(text, cursor, font_size, WHITE)
        }

        cursor.y += font_size + padding
        if state.track.type == .Running {
            mpk := (1.0 / state.track.avg_speed) * (1000.0 / 60.0)
            min := i32(mpk)
            sec := i32(60 * (mpk - math.trunc(mpk)))
            text = rl.TextFormat("Avg pace: %d:%2d /km", min, sec)
        } else {
            kph := (state.track.avg_speed * 3600) / 1000.0
            text = rl.TextFormat("Avg speed: %.1fkph", kph)
        }
        draw_text(text, cursor, font_size, WHITE)
    }

}

// panel with all the plots
gui_panel_plots :: proc(panel: ^Gui_Panel, track: Gps_Track, ui_focused: ^bool) {
    rect := panel.rect
    mouse_pos := rl.GetMousePosition()

    if panel.is_open && rl.CheckCollisionPointRec(mouse_pos, rect) {
        ui_focused^ = true
    }

    // TODO: check for click on the panel handle and change panel state

    // only draw the handle and then return
    if !panel.is_open && panel.anim_frame == 0 {
    }

    // draw the panel
    frame_count := f32(rl.GetFPS()) * PANEL_ANIM_TIME
    ease_func := panel.is_open ? ease.elastic_in : ease.elastic_out
    t: f32 = ease_func(f32(panel.anim_frame) / f32(frame_count))

    // add offset and calculate rect from animation frame
    draw_rect := rect
    switch panel.location {
    case .Top: {
        dest_y := panel.is_open ? rect.y - PANEL_OFFSET : rect.y - rect.height
        start_y := panel.is_open ? rect.y - rect.height : rect.y - PANEL_OFFSET
        draw_rect.y = math.lerp(start_y, dest_y, t)
    }
    case .Left: {
        dest_x := panel.is_open ? rect.x - PANEL_OFFSET : rect.x - rect.width
        start_x := panel.is_open ? rect.x - rect.width : rect.x - PANEL_OFFSET
        draw_rect.x = math.lerp(start_x, dest_x, t)
    }
    case .Right: {
        dest_x := panel.is_open ? rect.x + PANEL_OFFSET : rect.x + rect.width
        start_x := panel.is_open ? rect.x + rect.width : rect.x + PANEL_OFFSET
        draw_rect.x = math.lerp(start_x, dest_x, t)
    }
    case .Bottom: {
        dest_y := panel.is_open ? rect.y + PANEL_OFFSET : rect.y + rect.height
        start_y := panel.is_open ? rect.y + rect.height : rect.y + PANEL_OFFSET
        draw_rect.y = math.lerp(start_y, dest_y, t)
    }
    }
    rl.DrawRectangleRounded(draw_rect, 0.2, 20, rl.Fade(DARK_BLUE, FADE_AMMOUNT))

}

gui_panel_stats :: proc(panel: Gui_Panel, track: Gps_Track, ui_focused: ^bool) {

}

_gui_panel :: proc(panel: Gui_Panel) {

}

_gui_panel_handle :: proc(panel: Gui_Panel) {
    rect := panel.rect
    handle_rect: rl.Rectangle
    switch panel.location {
    case .Top: {
        handle_rect.width = rect.width * PANEL_HANDLE_SCALE
        handle_rect.height = handle_rect.width * 0.5
        handle_rect.x = rect.x + (rect.width - handle_rect.width) * 0.5
        // need to account for panel being offset
        handle_rect.y = rect.y - PANEL_OFFSET
    }
    case .Bottom: {
        handle_rect.width = rect.width * PANEL_HANDLE_SCALE
        handle_rect.height = handle_rect.width * 0.5
        handle_rect.x = rect.x + (rect.width - handle_rect.width) * 0.5
        // need to account for panel being offset
        handle_rect.y = rect.y + PANEL_OFFSET
    }
    case .Right: {
        handle_rect.height = rect.height * PANEL_HANDLE_SCALE
        handle_rect.width = handle_rect.height * 0.5
        handle_rect.y = rect.y + (rect.height - handle_rect.height) * 0.5
        // need to account for panel being offset
        handle_rect.x = rect.x + PANEL_OFFSET
    }
    case .Left: {
        handle_rect.height = rect.height * PANEL_HANDLE_SCALE
        handle_rect.width = handle_rect.height * 0.5
        handle_rect.y = rect.y + (rect.height - handle_rect.height) * 0.5
        // need to account for panel being offset
        handle_rect.x = rect.x + PANEL_OFFSET
    }
    }

    rl.DrawRectangleRec(handle_rect, ORANGE)
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
gui_drop_down :: proc(rect: rl.Rectangle, text: cstring, items: []cstring, selected: ^int, ui_focus: ^bool) -> bool {
    @(static) expanded: bool

    hover_item := -1
    did_select: bool

    count := len(items)
    rect := rect
    base_rect := rect
    mouse_pos := rl.GetMousePosition()

    if rl.CheckCollisionPointRec(mouse_pos, base_rect) {
        if rl.IsMouseButtonPressed(.LEFT) {
            expanded = !expanded
        }
        hover_item = 0
    }
    if expanded {
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
    if expanded {
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
