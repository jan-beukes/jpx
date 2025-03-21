package main

import "core:fmt"
import rl "vendor:raylib"

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

ZINI :: Coord{31.7544, -28.955}
STATUE :: Coord{139.7006793, 35.6590699}

main :: proc() {

    rl.SetTraceLogLevel(.WARNING)
    rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "JPX")
    defer rl.CloseWindow()

    mercator := coord_to_mercator(STATUE, 13)
    tile := mercator_to_tile(mercator, 13)
    fmt.println(tile_to_mercator(tile))

    tile_data := fetch_tile(tile)

    for !rl.WindowShouldClose() {
        rl.BeginDrawing()
        rl.ClearBackground(rl.BLACK)

        dst := rl.Rectangle{0, 0, TILE_SIZE*2, TILE_SIZE*2}
        src := rl.Rectangle{0, 0, TILE_SIZE, TILE_SIZE}
        rl.DrawTexturePro(tile_data.texture, src, dst, {}, 0, rl.WHITE)

        rl.EndDrawing()
    }

}
