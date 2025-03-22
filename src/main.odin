package main

import "core:fmt"
import rl "vendor:raylib"

Map_Camera :: struct {
    center: Mercator_Coord,
    width, height: i32,
    zoom: i32,
}

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

ZINI :: Coord{31.7544, -28.955}
STATUE :: Coord{139.7006793, 35.6590699}

main :: proc() {

    rl.SetTraceLogLevel(.WARNING)
    rl.SetConfigFlags({.WINDOW_RESIZABLE})
    rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "JPX")
    defer rl.CloseWindow()

    map_cam := Map_Camera {
        center = coord_to_mercator(STATUE, 13),
        width = WINDOW_WIDTH,
        height = WINDOW_HEIGHT,
        zoom = 13,
    }
    cache: Tile_Cache

    for !rl.WindowShouldClose() {

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

        rl.EndDrawing()
    }
    clean_cache(cache)
}
