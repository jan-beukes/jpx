package jpx

import rl "vendor:raylib"
import "core:math"
import "core:time/datetime"

BORDER_THICK :: 1.2
PADDING_FACTOR :: 0.2

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

DEFAULT_PALLETE :: Gui_Colors {
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

debug_ui :: proc() {
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()

    overlay := rl.Vector2 {
        f32(WINDOW_HEIGHT) * 0.35,
        f32(WINDOW_HEIGHT) * 0.5,
    }
    rl.DrawRectangleV({0, 0}, overlay, rl.Fade(DARK_BLUE, 0.9))

    padding := overlay.y * 0.02
    font_size: f32 = WINDOW_HEIGHT / 40.0

    cursor: rl.Vector2
    draw_text(rl.TextFormat("Cache: %d tiles", len(state.cache)), cursor, font_size, PEACH)

    cursor.y += font_size + padding
    draw_text(rl.TextFormat("Requests: %d", req_state.active_requests), cursor, font_size, PEACH)

    cursor.y += font_size + padding
    draw_text(rl.TextFormat("Zoom: %d | %.1fx", state.map_screen.zoom, state.map_screen.scale), cursor, font_size, PEACH)

    mouse_coord := mercator_to_coord(screen_to_map(state.map_screen, rl.GetMousePosition()),
        state.map_screen.zoom)
    cursor.y += font_size + padding
    draw_text(rl.TextFormat("Mouse: [%.3f, %.3f]", mouse_coord.x, mouse_coord.y),
        cursor, font_size, PEACH)

    cursor.y += font_size + padding
    text := rl.TextFormat("Map Style: %s", req_state.tile_layer.name)
    draw_text(text, cursor, font_size, PEACH)

    // Track
    if state.is_track_open {
        cursor.y += font_size + 2 * padding
        text := rl.TextFormat("TRACK:")
        draw_text(text, cursor, font_size, WHITE)

        cursor.y += font_size + padding
        text = rl.TextFormat("%s | %s", state.track.name, state.track.metadata.text)
        draw_text(text, cursor, font_size, WHITE)

        // some files dont have any time info
        date, ok := state.track.metadata.date_time.(datetime.DateTime)
        if ok {
            cursor.y += font_size + padding
            text = rl.TextFormat("%d-%d-%d %d:%d:%d", date.day, date.month, date.year, date.hour,
                date.minute, date.second)
            draw_text(text, cursor, font_size, WHITE)
        }

        cursor.y += font_size + padding
        text = rl.TextFormat("Distance: %.2fkm", state.track.total_distance / 1000.0)
        draw_text(text, cursor, font_size, WHITE)

        cursor.y += font_size + padding
        text = rl.TextFormat("ele gain: %.0fm", state.track.elevation_gain)
        draw_text(text, cursor, font_size, WHITE)

        cursor.y += font_size + padding
        text = rl.TextFormat("max ele: %.0fm", state.track.max_elevation)
        draw_text(text, cursor, font_size, WHITE)

        if state.track.avg_hr > 0 {
            cursor.y += font_size + padding
            text = rl.TextFormat("avg hr: %d", state.track.avg_hr)
            draw_text(text, cursor, font_size, WHITE)
        }

        cursor.y += font_size + padding
        if state.track.type == .Running {
            mpk := (1.0 / state.track.avg_speed) * (1000.0 / 60.0)
            min := i32(mpk)
            sec := i32(60 * (mpk - math.trunc(mpk)))
            text = rl.TextFormat("avg pace: %d:%d /km", min, sec)
        } else {
            kph := (state.track.avg_speed * 3600) / 1000.0
            text = rl.TextFormat("avg speed: %.1fkph", kph)
        }
        draw_text(text, cursor, font_size, WHITE)
    }

}


gui_drop_down :: proc(rect: rl.Rectangle, text: cstring, items: []cstring, colors: Gui_Colors, ui_focus: ^bool) -> (int, bool) {
    @(static) expanded: bool
    @(static) selected_item: int
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
                    selected_item = i
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
        for i in 0..<count {
            rect.y += rect.height
            if i + 1 == hover_item {
                rl.DrawRectangleRec(rect, colors.hover2)
            } else {
                rl.DrawRectangleRec(rect, colors.bg2)
            }
            draw_text(items[i], {rect.x + padding, rect.y + padding}, font_size, colors.fg)
        }
        rect.y = base_rect.y + rect.height
        rect.height *= f32(count)
        rl.DrawRectangleLinesEx(rect, BORDER_THICK, colors.border)
    }

    // Base rect
    if hover_item == 0 {
        rl.DrawRectangleRec(base_rect, colors.hover)
    } else {
        rl.DrawRectangleRec(base_rect, colors.bg)
    }
    draw_text(text, {rect.x + padding, base_rect.y + padding}, font_size, colors.fg)
    rl.DrawRectangleLinesEx(base_rect, BORDER_THICK, colors.border)


    if hover_item != -1 && !ui_focus^ {
        ui_focus^ = true
    }

    return selected_item, did_select
}
