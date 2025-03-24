package jpx

import "core:fmt"
import "core:mem"
import "core:strconv"
import "core:os"
import "core:strings"
import "core:flags"
import "core:time"
import "core:log"
import "core:math"
import "core:math/linalg"
import rl "vendor:raylib"

Map_Screen :: struct {
    center: Mercator_Coord,
    width, height: i32,
    zoom: i32,
    scale: f32,
}

Flags :: struct {
    input_file: string,
    api_key: string,
    layer_style: Layer_Style,
}

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
WINDOW_MIN_SIZE :: 300
FPS :: 60

MAX_SCALE :: 1.0
MIN_SCALE :: MAX_SCALE / 2.0

ZOOM_STEP :: 0.2
ZOOM_FRAMES :: 5
MOVE_FRICTION :: 2400
MAX_SPEED :: 1800

DARKGRAY :: rl.Color{100, 100, 100, 255}
FADED_BLACK :: rl.Color{0, 0, 0, 100}

TEST_LOC :: Coord{18.8843, -33.9467}

USAGE :: 
`
Usage: jpx [file] [OPTIONS]

file formats: gpx

OPTIONS:
    -s         map style (0 - 3)
    -k         map api key
`

// global state
map_screen: Map_Screen
cache: Tile_Cache
last_eviction: f64
is_track_open: bool
g_font: rl.Font

draw_text :: proc(text: cstring, pos: rl.Vector2, size: f32, color: rl.Color) {
    rl.DrawTextEx(g_font, text, pos, size, 0, color)
}

draw_ui :: proc() {
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()

    // Debug UI
    when ODIN_DEBUG {
        overlay := rl.Vector2 {
            f32(WINDOW_HEIGHT) * 0.35,
            f32(WINDOW_HEIGHT) * 0.15,
        }
        rl.DrawRectangleV({0, 0}, overlay, FADED_BLACK)

        rl.DrawFPS(10, window_height - 20)

        padding := overlay.y * 0.05
        font_size: f32 = WINDOW_HEIGHT / 40.0

        cursor: rl.Vector2
        draw_text(rl.TextFormat("Cache: %d tiles", len(cache)), cursor, font_size, rl.ORANGE)

        cursor.y += font_size + padding
        draw_text(rl.TextFormat("Zoom: %d", map_screen.zoom), cursor, font_size, rl.ORANGE)
        mouse_coord := mercator_to_coord(screen_to_map(map_screen, rl.GetMousePosition()),
            map_screen.zoom)

        cursor.y += font_size + padding
        draw_text(rl.TextFormat("Mouse: [%.3f, %.3f]", mouse_coord.x, mouse_coord.y),
            cursor, font_size, rl.ORANGE)

        cursor.y += font_size + padding
        text := fmt.ctprint("Map Style:", req_state.tile_layer.style)
        draw_text(text, cursor, font_size, rl.ORANGE)
    }

}

handle_input :: proc() {

    zoom_map :: proc(step: f32, window_width, window_height: i32) {
        // This depends on tile layer
        max_zoom := req_state.tile_layer.max_zoom
        if step > 0 && map_screen.zoom == max_zoom do return
        if step < 0 && map_screen.zoom == MIN_ZOOM do return

        map_screen.scale += step

        if map_screen.scale < MIN_SCALE {
            diff := MIN_SCALE - map_screen.scale
            map_screen.zoom = max(map_screen.zoom - 1, MIN_ZOOM)
            map_screen.scale = MAX_SCALE - diff
            map_screen.center *= 0.5
        } else if map_screen.scale > MAX_SCALE {
            diff := map_screen.scale - MAX_SCALE
            map_screen.zoom = min(map_screen.zoom + 1, max_zoom)
            map_screen.scale = MIN_SCALE + diff
            map_screen.center *= 2
        }
        map_screen.width = i32(f32(window_width) / map_screen.scale)
        map_screen.height = i32(f32(window_height) / map_screen.scale)
    }

    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()
    if rl.IsWindowResized() {
        map_screen.width = i32(f32(window_width) / map_screen.scale)
        map_screen.height = i32(f32(window_height) / map_screen.scale)
    }

    mouse_pos := rl.GetMousePosition()
    scroll := rl.GetMouseWheelMove()

    // TODO: with UI only handle map input when mouse is in map region

    //---Map Movement---

    // movement state
    @(static) move_state: struct {
        zoom_frame: i32,
        zoom_step: f32,
        mouse_zoom: bool,

        mouse_held: bool,
        velocity: rl.Vector2,
    }

    // Zooming
    if scroll != 0.0 {
        move_state.mouse_zoom = true
        move_state.zoom_frame = ZOOM_FRAMES
        move_state.zoom_step = scroll > 0.0 ? ZOOM_STEP : -ZOOM_STEP
    } else if rl.IsKeyPressed(.EQUAL) {
        move_state.mouse_zoom = false
        move_state.zoom_frame = 2 * ZOOM_FRAMES
        move_state.zoom_step = 2 * ZOOM_STEP
    } else if rl.IsKeyPressed(.MINUS) {
        move_state.mouse_zoom = false
        move_state.zoom_frame = 2 * ZOOM_FRAMES
        move_state.zoom_step = -2 * ZOOM_STEP
    }

    if move_state.zoom_frame > 0 {
        prev_zoom := map_screen.zoom
        prev_mouse_map_pos := screen_to_map(map_screen, mouse_pos)

        zoom_map(move_state.zoom_step / ZOOM_FRAMES, window_width, window_height)
        move_state.zoom_frame -= 1

        if move_state.mouse_zoom {
            if map_screen.zoom > prev_zoom {
                prev_mouse_map_pos *= 2.0
            }
            if map_screen.zoom < prev_zoom {
                prev_mouse_map_pos *= 0.5
            }
            mouse_map_pos := screen_to_map(map_screen, mouse_pos)
            map_screen.center += (prev_mouse_map_pos - mouse_map_pos)
        }
    }

    // Panning
    dt: f32 = (1.0 / FPS)
    if rl.IsMouseButtonDown(.LEFT) {
        rl.SetMouseCursor(.RESIZE_ALL)
        move_state.mouse_held = true

        move_state.velocity = {0.0, 0.0}
        delta := rl.GetMouseDelta() / map_screen.scale
        map_screen.center -= {f64(delta.x), f64(delta.y)}
    } else if rl.IsMouseButtonReleased(.LEFT) {
        rl.SetMouseCursor(.DEFAULT)
        if move_state.mouse_held {
            move_state.mouse_held = false
            delta := rl.GetMouseDelta() / map_screen.scale
            move_state.velocity = - (delta / dt)
            if linalg.length(move_state.velocity) > MAX_SPEED {
                move_state.velocity = MAX_SPEED * linalg.normalize(move_state.velocity)
            }
        }
    }
    // update from panning velocity
    speed := linalg.length(move_state.velocity)
    if speed > 0 {
        dr := move_state.velocity * dt
        map_screen.center += {f64(dr.x), f64(dr.y)}
        speed -= MOVE_FRICTION * dt

        if speed <= 0 {
            move_state.velocity = {0, 0}
        } else {
            move_state.velocity = speed * linalg.normalize(move_state.velocity)
        }
    }


    // clamp map screen position
    tile_size := req_state.tile_layer.tile_size
    n := 1 << u32(map_screen.zoom)
    border_left := 0.0
    border_right := tile_size * f64(n)
    map_screen.center.x = clamp(map_screen.center.x, border_left, border_right)
    border_top := 0.0
    border_bottom := tile_size * f64(n)
    map_screen.center.y = clamp(map_screen.center.y, border_top, border_bottom)


    if rl.IsKeyPressed(.F) {
        if rl.IsWindowMaximized() {
            rl.RestoreWindow()
        } else {
            rl.MaximizeWindow()
        }
    }
}

update :: proc() {

    if rl.GetTime() - last_eviction > CACHE_TIMEOUT {
        evict_cache(&cache, map_screen)
        last_eviction = rl.GetTime()
    }

    handle_input()

    // get tiles
    poll_requests(&cache)
    tiles := map_get_tiles(&cache, map_screen)

    //---Render---
    rl.BeginDrawing()
    rl.ClearBackground(req_state.tile_layer.clear_color)

    tile_size := req_state.tile_layer.tile_size
    src := rl.Rectangle{0, 0, f32(tile_size), f32(tile_size)}
    for item in tiles {
        pos := item.coord
        tile_rect := get_tile_rect(map_screen, item)
        rl.DrawTexturePro(item.texture, src, tile_rect, {}, 0, rl.WHITE)
        //rl.DrawRectangleLinesEx(tile_rect, 1, rl.PURPLE)
    }

    draw_ui()
    rl.EndDrawing()

    free_all(context.temp_allocator)
}

parse_flags :: proc() -> Flags {
    argv := os.args
    if len(argv) < 2 do return {}

    flags: Flags
    for i := 1; i < len(argv); i += 1 {
        is_last := i == len(argv) - 1
        if strings.compare(argv[i], "-s") == 0 {
            if is_last {
                fmt.eprint(USAGE); os.exit(1)
            }
            i += 1
            num, ok := strconv.parse_int(argv[i])
            if !ok || num >= len(Layer_Style) {
                fmt.eprint(USAGE)
                os.exit(1)
            }
            flags.layer_style = Layer_Style(num)
        } else if strings.compare(argv[i], "-k") == 0 {
            if is_last {
                fmt.eprint(USAGE); os.exit(1)
            }
            i += 1
            flags.api_key = argv[i]
        // file must always be first if it is provided
        } else if i == 1 {
            flags.input_file = argv[i]
        } else {
            fmt.eprint(USAGE)
            os.exit(1)
        }
    }
    return flags
}

main :: proc() {
    context.logger = log.create_console_logger(
        .Debug when ODIN_DEBUG else .Info,
        log.Options{.Level, .Terminal_Color},
    )

    flags := parse_flags()
    if flags.input_file == "" {
        is_track_open = false
    }
    // TODO: read keys from a jpx.key file
    api_key := strings.clone_to_cstring(flags.api_key)
    init_tile_fetching(flags.layer_style, api_key)
    log.debug(flags)

    // Init
    rl.SetTraceLogLevel(.ERROR)
    rl.SetConfigFlags({.WINDOW_RESIZABLE})
    rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "jpx")
    rl.SetTargetFPS(FPS) // idk
    rl.SetWindowMinSize(WINDOW_MIN_SIZE, WINDOW_MIN_SIZE)
    defer rl.CloseWindow()

    // resource
    g_font = rl.LoadFontEx("res/font.ttf", 96, nil, 0)
    rl.SetTextureFilter(g_font.texture, .BILINEAR)

    map_screen = Map_Screen {
        center = coord_to_mercator(TEST_LOC, 13),
        width = WINDOW_WIDTH,
        height = WINDOW_HEIGHT,
        zoom = 13,
        scale = 1.0,
    }

    // cache a few large tiles
    tile := mercator_to_tile(map_screen.center, map_screen.zoom)
    for _ in 0..<ZOOM_FALLBACK_LIMIT {
        tile.x /= 2
        tile.y /= 2
        tile.zoom -= 1
        request_tile(tile)
        tile_data := new(Tile_Data)
        cache[tile] = tile_data
    }

    for !rl.WindowShouldClose() {
        update()
    }
}
