package jpx

import rl "vendor:raylib"
import "core:math"
import "core:time"
import "core:time/datetime"

BORDER_THICK :: 1.2
PADDING_FACTOR :: 0.2
FADE_AMMOUNT :: 0.9

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

g_font: rl.Font

draw_text :: proc(text: cstring, pos: rl.Vector2, size: f32, color: rl.Color) {
    rl.DrawTextEx(g_font, text, pos, size, 0, color)
}

debug_ui :: proc(x, y: f32) {
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()

    height: f32 = state.is_track_open ? 0.5 : 0.15
    overlay := rl.Vector2 {
        f32(WINDOW_HEIGHT) * 0.35,
        f32(WINDOW_HEIGHT) * height,
    }
    rl.DrawRectangleV({x, y}, overlay, rl.Fade(DARK_BLUE, FADE_AMMOUNT))

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
