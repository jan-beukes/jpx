package main

import "core:fmt"
import "core:log"
import "core:math"
import rl "vendor:raylib"

Map_Screen :: struct {
    center: Mercator_Coord,
    width, height: i32,
    zoom: i32,
    scale: f32,
}

WINDOW_WIDTH :: 1280
WINDOW_MIN_SIZE :: 300
WINDOW_HEIGHT :: 720

ZOOM_STEP :: 0.1

ZINI :: Coord{31.7544, -28.955}
STATUE :: Coord{139.7006793, 35.6590699}

// global state
map_screen: Map_Screen
cache: Tile_Cache

FADED_BLACK :: rl.Color{0, 0, 0, 100}
draw_ui :: proc() {
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()

    when ODIN_DEBUG {
        overlay := rl.Vector2 {
            f32(WINDOW_HEIGHT) * 0.4,
            f32(WINDOW_HEIGHT) * 0.2,
        }
        rl.DrawRectangleV({0, 0}, overlay, FADED_BLACK)

        padding := i32(overlay.y * 0.05)
        font_size := i32(overlay.y / 8.0)
        cursor := [2]i32 {0, 0}
        rl.DrawText(rl.TextFormat("Cache: %d tiles", len(cache)), cursor.x, cursor.y,
            font_size, rl.GREEN)
        cursor.y += font_size + padding
        rl.DrawText(rl.TextFormat("center: [%.0f, %.0f]", map_screen.center.x, map_screen.center.y),
            cursor.x, cursor.y, font_size, rl.GREEN)
        cursor.y += font_size + padding
        rl.DrawText(rl.TextFormat("Screen size: %dx%d", map_screen.width, map_screen.height),
            cursor.x, cursor.y, font_size, rl.GREEN)
        cursor.y += font_size + padding
        rl.DrawText(rl.TextFormat("Zoom: %d", map_screen.zoom),
            cursor.x, cursor.y, font_size, rl.GREEN)

        mouse_coord := mercator_to_coord(screen_to_map(map_screen, rl.GetMousePosition()),
            map_screen.zoom)
        cursor.y += font_size + padding
        rl.DrawText(rl.TextFormat("Mouse: [%.2f, %.2f]", mouse_coord.x, mouse_coord.y),
            cursor.x, cursor.y, font_size, rl.GREEN)
    }

}

zoom_map :: proc(dir: f32, window_width, window_height: i32) {
    if map_screen.zoom == MAX_ZOOM && dir > 0 do return
    if map_screen.zoom == MIN_ZOOM && dir < 0 do return

    map_screen.scale += dir*ZOOM_STEP

    if map_screen.scale < 1.0 {
        map_screen.zoom = max(map_screen.zoom - 1, MIN_ZOOM)
        map_screen.scale = 2.0
        map_screen.center *= 0.5
    } else if map_screen.scale > 2.0 {
        map_screen.zoom = min(map_screen.zoom + 1, MAX_ZOOM)
        map_screen.scale = 1.0
        map_screen.center *= 2
    }

    map_screen.width = i32(f32(window_width) / map_screen.scale)
    map_screen.height = i32(f32(window_height) / map_screen.scale)
}

handle_input :: proc() {
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()
    if rl.IsWindowResized() {
        map_screen.width = i32(f32(window_width) / map_screen.scale)
        map_screen.height = i32(f32(window_height) / map_screen.scale)
    }

    mouse_pos := rl.GetMousePosition()
    scroll := rl.GetMouseWheelMove()

    // TODO: with UI only handle map input when mouse is in map region

    if scroll != 0.0 {
        prev_zoom := map_screen.zoom
        prev_mouse_map_pos := screen_to_map(map_screen, mouse_pos)

        if scroll > 0.0 && map_screen.zoom < MAX_ZOOM {
            zoom_map(1, window_width, window_height)
            if map_screen.zoom > prev_zoom {
                prev_mouse_map_pos *= 2.0
            }
        } else if scroll < 0.0 && map_screen.zoom > 0 {
            zoom_map(-1, window_width, window_height)
            if map_screen.zoom < prev_zoom {
                prev_mouse_map_pos *= 0.5
            }
        }

        mouse_map_pos := screen_to_map(map_screen, mouse_pos)
        map_screen.center += (prev_mouse_map_pos - mouse_map_pos)
    }

    if rl.IsMouseButtonDown(.LEFT) {
        rl.SetMouseCursor(.RESIZE_ALL)
        delta := rl.GetMouseDelta() / map_screen.scale
        map_screen.center -= {f64(delta.x), f64(delta.y)}
    } else if rl.IsMouseButtonReleased(.LEFT) {
        rl.SetMouseCursor(.DEFAULT)
    }

    // clamp map screen position
    n := 1 << u32(map_screen.zoom)
    border_left := 0.0
    border_right := TILE_SIZE * f64(n)
    map_screen.center.x = clamp(map_screen.center.x, border_left, border_right)
    border_top := 0.0
    border_bottom := TILE_SIZE * f64(n)
    map_screen.center.y = clamp(map_screen.center.y, border_top, border_bottom)
}

update :: proc() {

    handle_input()

    // get tiles
    poll_requests(&cache)
    tiles := map_get_tiles(&cache, map_screen)

    //---Render---
    rl.BeginDrawing()
    rl.ClearBackground(rl.RAYWHITE)

    src := rl.Rectangle{0, 0, TILE_SIZE, TILE_SIZE}
    for item in tiles {
        pos := item.coord
        tile_rect := get_tile_rect(map_screen, item)
        rl.DrawTexturePro(item.texture, src, tile_rect, {}, 0, rl.WHITE)
        rl.DrawRectangleLinesEx(tile_rect, 1, rl.ORANGE)
    }

    draw_ui()

    rl.EndDrawing()
}

main :: proc() {
    context.logger = log.create_console_logger(opt = log.Options{.Level, .Terminal_Color})

    // Init
    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_RESIZABLE})
    rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "jpx")
    rl.SetWindowMinSize(WINDOW_MIN_SIZE, WINDOW_MIN_SIZE)
    defer rl.CloseWindow()

    map_screen = Map_Screen {
        center = coord_to_mercator(ZINI, 13),
        width = WINDOW_WIDTH,
        height = WINDOW_HEIGHT,
        zoom = 13,
        scale = 1.0,
    }

    init_tile_fetching()

    for !rl.WindowShouldClose() {
        update()
    }
    clear_cache(&cache)
}
