package jpx

import "core:fmt"
import os "core:os/os2"
import "core:path/filepath"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:flags"
import "core:time"
import "core:time/datetime"
import "core:log"
import "core:math"
import "core:math/linalg"

import rl "vendor:raylib"
import trk "gps_track"

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
WINDOW_MIN_SIZE :: 300
FPS :: 60

MAX_SCALE :: 1.2
MIN_SCALE :: MAX_SCALE / 2.0

ZOOM_STEP :: 0.3
ZOOM_FRAMES :: 5
MOVE_FRICTION :: 2400
MAX_SPEED :: 1800

DARKGRAY :: rl.Color{100, 100, 100, 255}
FADED_BLACK :: rl.Color{0, 0, 0, 200}

TEST_LOC :: Coord{18.8843, -33.9467}

USAGE :: 
`
Usage: jpx [file] [OPTIONS]

file formats: gpx

OPTIONS:
    -s         map style (0 - 3)
    -k         map api key
`

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

State :: struct {
    map_screen: Map_Screen,
    cache: Tile_Cache,
    last_eviction: f64,
    cache_to_disk: bool,

    track: trk.Gps_Track,
    is_track_open: bool,
}

// global state
state: State
g_font: rl.Font


draw_text :: proc(text: cstring, pos: rl.Vector2, size: f32, color: rl.Color) {
    rl.DrawTextEx(g_font, text, pos, size, 0, color)
}

debug_ui :: proc() {
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()

    overlay := rl.Vector2 {
        f32(WINDOW_HEIGHT) * 0.40,
        f32(WINDOW_HEIGHT),
    }
    rl.DrawRectangleV({0, 0}, overlay, FADED_BLACK)

    padding := overlay.y * 0.02
    font_size: f32 = WINDOW_HEIGHT / 40.0

    cursor: rl.Vector2
    draw_text(rl.TextFormat("Cache: %d tiles", len(state.cache)), cursor, font_size, rl.ORANGE)

    cursor.y += font_size + padding
    draw_text(rl.TextFormat("Requests: %d", req_state.active_requests), cursor, font_size, rl.ORANGE)

    cursor.y += font_size + padding
    draw_text(rl.TextFormat("Zoom: %d | %.1fx", state.map_screen.zoom, state.map_screen.scale), cursor, font_size, rl.ORANGE)

    mouse_coord := mercator_to_coord(screen_to_map(state.map_screen, rl.GetMousePosition()),
        state.map_screen.zoom)
    cursor.y += font_size + padding
    draw_text(rl.TextFormat("Mouse: [%.3f, %.3f]", mouse_coord.x, mouse_coord.y),
        cursor, font_size, rl.ORANGE)

    cursor.y += font_size + padding
    text := rl.TextFormat("Map Style: %s", req_state.tile_layer.name)
    draw_text(text, cursor, font_size, rl.ORANGE)

    if state.is_track_open {
        cursor.y += font_size + 2 * padding
        text := rl.TextFormat("TRACK:")
        draw_text(text, cursor, font_size, rl.PURPLE)

        cursor.y += font_size + padding
        text = rl.TextFormat("%s | %s", state.track.name, state.track.metadata.text)
        draw_text(text, cursor, font_size, rl.PURPLE)

        date, ok := state.track.metadata.date_time.(datetime.DateTime)
        if ok {
            cursor.y += font_size + padding
            text = rl.TextFormat("%d-%d-%d %d:%d:%d", date.day, date.month, date.year, date.hour,
                date.minute, date.second)
            draw_text(text, cursor, font_size, rl.PURPLE)
        }

        cursor.y += font_size + padding
        text = rl.TextFormat("Distance: %.1fkm", state.track.total_distance / 1000.0)
        draw_text(text, cursor, font_size, rl.PURPLE)

        cursor.y += font_size + padding
        text = rl.TextFormat("ele gain: %d", state.track.elevation_gain)
        draw_text(text, cursor, font_size, rl.PURPLE)

        cursor.y += font_size + padding
        text = rl.TextFormat("max ele: %d", state.track.max_elevation)
        draw_text(text, cursor, font_size, rl.PURPLE)

        if state.track.avg_hr > 0 {
            cursor.y += font_size + padding
            text = rl.TextFormat("avg hr: %d", state.track.avg_hr)
            draw_text(text, cursor, font_size, rl.PURPLE)
        }

        cursor.y += font_size + padding
        if state.track.type == .Running {
            text = rl.TextFormat("avg speed: %d", state.track.avg_speed)
        } else {
            kph := (state.track.avg_speed * 3600) / 1000.0
            text = rl.TextFormat("avg speed: %.1fkph", kph)
        }
        draw_text(text, cursor, font_size, rl.PURPLE)
    }

    //// Draw elevation
    //MAX :: 400
    //max_height := window_height / 2
    //count := 500
    //length := len(state.track.points)
    //w := f32(window_width) / f32(count)
    //step := length / count
    //for i in 0..<count {
    //    point := state.track.points[i * step]
    //    x := f32(i) * w
    //    height := f32(max_height) * f32(point.elevation) / 400.0
    //    rl.DrawRectangleRec({x, f32(window_height) - height, w, height}, rl.GREEN)
    //}

}

handle_input :: proc() {

    zoom_map :: proc(step: f32, window_width, window_height: i32) {
        // This depends on tile layer
        max_zoom := req_state.tile_layer.max_zoom
        if step > 0 && state.map_screen.zoom == max_zoom {
            if state.map_screen.scale + step > MAX_SCALE do return
        }
        if step < 0 && state.map_screen.zoom == MIN_ZOOM do return

        state.map_screen.scale += step

        if state.map_screen.scale < MIN_SCALE {
            diff := MIN_SCALE - state.map_screen.scale
            state.map_screen.zoom = max(state.map_screen.zoom - 1, MIN_ZOOM)
            state.map_screen.scale = MAX_SCALE - diff
            state.map_screen.center *= 0.5
        } else if state.map_screen.scale > MAX_SCALE {
            diff := state.map_screen.scale - MAX_SCALE
            state.map_screen.zoom = min(state.map_screen.zoom + 1, max_zoom)
            state.map_screen.scale = MIN_SCALE + diff
            state.map_screen.center *= 2
        }
        state.map_screen.width = i32(f32(window_width) / state.map_screen.scale)
        state.map_screen.height = i32(f32(window_height) / state.map_screen.scale)
    }

    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()
    if rl.IsWindowResized() {
        state.map_screen.width = i32(f32(window_width) / state.map_screen.scale)
        state.map_screen.height = i32(f32(window_height) / state.map_screen.scale)
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
        prev_zoom := state.map_screen.zoom
        prev_mouse_map_pos := screen_to_map(state.map_screen, mouse_pos)

        zoom_map(move_state.zoom_step / ZOOM_FRAMES, window_width, window_height)
        move_state.zoom_frame -= 1

        if move_state.mouse_zoom {
            if state.map_screen.zoom > prev_zoom {
                prev_mouse_map_pos *= 2.0
            }
            if state.map_screen.zoom < prev_zoom {
                prev_mouse_map_pos *= 0.5
            }
            mouse_map_pos := screen_to_map(state.map_screen, mouse_pos)
            state.map_screen.center += (prev_mouse_map_pos - mouse_map_pos)
        }
    }

    // Panning
    dt: f32 = (1.0 / FPS)
    if rl.IsMouseButtonDown(.LEFT) {
        if !move_state.mouse_held {
            rl.SetMouseCursor(.RESIZE_ALL)
            move_state.mouse_held = true
        }

        move_state.velocity = {0.0, 0.0}
        delta := rl.GetMouseDelta() / state.map_screen.scale
        state.map_screen.center -= {f64(delta.x), f64(delta.y)}
    } else if rl.IsMouseButtonReleased(.LEFT) {
        if move_state.mouse_held {
            rl.SetMouseCursor(.DEFAULT)
            move_state.mouse_held = false
            delta := rl.GetMouseDelta() / state.map_screen.scale
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
        state.map_screen.center += {f64(dr.x), f64(dr.y)}
        speed -= MOVE_FRICTION * dt

        if speed <= 0 {
            move_state.velocity = {0, 0}
        } else {
            move_state.velocity = speed * linalg.normalize(move_state.velocity)
        }
    }


    // clamp map screen position
    tile_size := req_state.tile_layer.tile_size
    n := 1 << u32(state.map_screen.zoom)
    border_left := 0.0
    border_right := tile_size * f64(n)
    state.map_screen.center.x = clamp(state.map_screen.center.x, border_left, border_right)
    border_top := 0.0
    border_bottom := tile_size * f64(n)
    state.map_screen.center.y = clamp(state.map_screen.center.y, border_top, border_bottom)


    if rl.IsKeyPressed(.F) {
        if rl.IsWindowMaximized() {
            rl.RestoreWindow()
        } else {
            rl.MaximizeWindow()
        }
    }
}

update :: proc() {

    // only evict when we are near the limit
    if rl.GetTime() - state.last_eviction > CACHE_TIMEOUT && len(state.cache) >= EVICTION_SIZE {
        evict_cache(&state.cache, state.map_screen)
        state.last_eviction = rl.GetTime()
    }

    handle_input()

    // get tiles
    poll_requests(&state.cache)
    tiles := map_get_tiles(&state.cache, state.map_screen)

    //---Render---
    rl.BeginDrawing()
    rl.ClearBackground(req_state.tile_layer.clear_color)

    tile_size := req_state.tile_layer.tile_size
    for item in tiles {
        pos := item.coord
        src := rl.Rectangle{0, 0, f32(item.texture.width), f32(item.texture.height)}
        tile_rect := get_tile_rect(state.map_screen, item)
        rl.DrawTexturePro(item.texture, src, tile_rect, {}, 0, rl.WHITE)
        //rl.DrawRectangleLinesEx(tile_rect, 1, rl.PURPLE)
    }

    when ODIN_DEBUG do debug_ui()
    rl.EndDrawing()

    free_all(context.temp_allocator)
}

parse_flags :: proc(argv: []string) -> Flags {
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

    argv := os.args
    flags := parse_flags(argv)
    log.debug(flags)

    // load track if input file was provided
    if flags.input_file == "" {
        state.is_track_open = false
    } else {
        ok: bool
        state.track, ok = trk.load_from_file(flags.input_file)
        if ok {
            state.is_track_open = true
        } else {
            state.is_track_open = false
        }
    }

    // cache dir on desktop
    when ODIN_OS != .JS {
        dir := filepath.dir(argv[0])
        os.change_directory(dir)
        os.make_directory(CACHE_DIR)
        state.cache_to_disk = true
    } else {
        state.cache_to_disk = false
    }

    api_key := strings.clone_to_cstring(flags.api_key)
    init_tile_fetching(flags.layer_style, api_key)

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

    state.map_screen = Map_Screen {
        center = coord_to_mercator(TEST_LOC, 13),
        width = WINDOW_WIDTH,
        height = WINDOW_HEIGHT,
        zoom = 13,
        scale = 1.0,
    }

    // cache a few large tiles
    tile := mercator_to_tile(state.map_screen.center, state.map_screen.zoom)
    for _ in 0..<ZOOM_FALLBACK_LIMIT {
        tile.x /= 2
        tile.y /= 2
        tile.zoom -= 1

        new_tile(&state.cache, tile)
    }

    for !rl.WindowShouldClose() {
        update()
    }
}
