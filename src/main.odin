package main

import "core:fmt"
import "core:log"
import rl "vendor:raylib"

Map_Camera :: struct {
    center: Mercator_Coord,
    width, height: i32,
    zoom: i32,
}

WINDOW_WIDTH :: 1280
WINDOW_MIN_SIZE :: 300
WINDOW_HEIGHT :: 720

ZINI :: Coord{31.7544, -28.955}
STATUE :: Coord{139.7006793, 35.6590699}

// global state
map_cam: Map_Camera
cache: Tile_Cache

FADED_BLACK :: rl.Color{0, 0, 0, 100}
draw_ui :: proc() {
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()

    when ODIN_DEBUG {
        overlay := rl.Vector2 {
            f32(WINDOW_HEIGHT) * 0.2,
            f32(WINDOW_HEIGHT) * 0.1,
        }
        rl.DrawRectangleV({0, 0}, overlay, FADED_BLACK)

        padding := overlay.y * 0.05
        font_size := i32(overlay.x / 8.0)
        log.info(font_size)
        cursor := [2]i32 {0, 0}
        rl.DrawText(rl.TextFormat("requests: %d", active_requests), cursor.x, cursor.y,
            font_size, rl.GREEN)
    }

}

update :: proc() {
    poll_requests(&cache)
    tiles := map_get_tiles(&cache, map_cam)

    rl.BeginDrawing()
    rl.ClearBackground(rl.RAYWHITE)

    // keep center in the middle on resize makes resizing much nicer
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()
    map_cam.width, map_cam.height = window_width, window_height
    origin := map_cam.center - Mercator_Coord{int(window_width) / 2, int(window_height) / 2}

    src := rl.Rectangle{0, 0, TILE_SIZE, TILE_SIZE}
    for item in tiles {
        pos := item.coord
        dst := rl.Rectangle{f32(pos.x - origin.x), f32(pos.y - origin.y), TILE_SIZE, TILE_SIZE}
        rl.DrawTexturePro(item.texture, src, dst, {}, 0, rl.WHITE)
    }

    draw_ui()

    rl.EndDrawing()
}

main :: proc() {
    context.logger = log.create_console_logger(opt = log.Options{.Level, .Terminal_Color})

    // Init
    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_RESIZABLE})
    rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "JPX")
    rl.SetWindowMinSize(WINDOW_MIN_SIZE, WINDOW_MIN_SIZE)
    defer rl.CloseWindow()

    map_cam = Map_Camera {
        center = coord_to_mercator(STATUE, 13),
        width = WINDOW_WIDTH,
        height = WINDOW_HEIGHT,
        zoom = 13,
    }
    init_tile_fetching()

    for !rl.WindowShouldClose() {
        update()
    }
    evict_cache(&cache)
}
