package jpx

import "core:fmt"
import "core:strings"
import "core:math/linalg"
import "core:math"
import "core:log"

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720
WINDOW_MIN_SIZE :: 300

MAX_SCALE :: 1.2
MIN_SCALE :: MAX_SCALE / 2.0

// Movement
ZOOM_STEP :: 0.4
ZOOM_TIME :: 0.1
MOVE_FRICTION :: 3200
MAX_SPEED :: 1600

// Track
TRACK_LINE_THICK :: 4
END_POINT_RADIUS :: 6.0

FONT_DATA :: #load("../res/font.ttf")
ICON_DATA :: #load("../res/icon.png")

USAGE :: 
`
Usage: jpx [file] [OPTIONS]

file formats: gpx

OPTIONS:
    -s          map style (0 - 3)
    -k          api key for provided map style
    --offline   only use local cached tiles
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
    offline: bool
}

// used to store the user config from the jpx.ini file
Config :: struct {
    api_keys: [Layer_Style]cstring,
}

State :: struct {
    map_screen: Map_Screen,
    cache: Tile_Cache,
    last_eviction: f64,

    cache_to_disk: bool,
    config: Config,

    // Track
    is_track_open: bool,
    track: Gps_Track,
    draw_track: Draw_Track,

    ui_is_focused: bool,
}

// The draw state of the track
// coords and points are allocated on track loading
Draw_Track :: struct {
    coords: []Mercator_Coord, // the coordinates are computed from track points
                              // and must be scaled when zoom changes 

    points: []rl.Vector2, // the points that get passed to DrawLineStrip
    zoom: i32,
    color: rl.Color,
}
// global state
state: State

draw_track :: proc() {

    // if zoom change mercator coords need to be scaled
    if state.draw_track.zoom != state.map_screen.zoom {
        for &coord in state.draw_track.coords {
            coord = scale_mercator(coord, state.draw_track.zoom, state.map_screen.zoom)
        }
        state.draw_track.zoom = state.map_screen.zoom
    }

    length := len(state.draw_track.points)
    // set points on screen
    for i := 0; i < len(state.draw_track.points); i += 1 {
        state.draw_track.points[i] = map_to_screen(state.map_screen, state.draw_track.coords[i])
    }

    // set the line thickness for the track and draw the render batch
    // we don't want this thickness for the endpoints or UI
    rlgl.SetLineWidth(TRACK_LINE_THICK)
    rl.DrawLineStrip(raw_data(state.draw_track.points), i32(len(state.draw_track.points)),
        state.draw_track.color)
    rlgl.DrawRenderBatchActive()
    rlgl.SetLineWidth(1)

    // Draw the start and end points
    rl.DrawCircleV(state.draw_track.points[0], END_POINT_RADIUS, rl.DARKGREEN)
    rl.DrawCircleLinesV(state.draw_track.points[0], END_POINT_RADIUS, WHITE)
    rl.DrawCircleV(state.draw_track.points[length - 1], END_POINT_RADIUS, rl.MAROON)
    rl.DrawCircleLinesV(state.draw_track.points[length - 1], END_POINT_RADIUS, WHITE)
}

// since we are using a type of imgui the drawing and logic of the gui are in the same place
handle_ui :: proc() {
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()

    state.ui_is_focused = false
    @(static) mouse_cursor: rl.MouseCursor

    gui_begin()

    //---Tile Layers dropdown---
    width: f32 = WINDOW_HEIGHT * 0.18
    height := width * 0.2
    rect := rl.Rectangle{f32(window_width) - width, 0, width, height}
    items := []cstring {
        "Osm",
        "Jawg Outdoors",
        "Mapbox Outdoors",
        "Satelite",
    }
    selected := int(req_state.tile_layer.style)
    if gui_drop_down(rect, "Map Style", items, &selected, &state.ui_is_focused) {
        switch_tile_layer(Layer_Style(selected))
    }

    size: f32 = WINDOW_HEIGHT * 0.03
    rect = rl.Rectangle{f32(window_width) - 1.1*size, f32(window_height) - 1.1*size, size, size}
    gui_copyright(rect, req_state.tile_layer.style, &state.ui_is_focused)

    width = WINDOW_HEIGHT * 0.18
    height = width * 0.2
    rect = rl.Rectangle{0, 0, width, height}
    if gui_button(rect, "Open file", &state.ui_is_focused) {
        file := open_file_dialog()
        if file != "" {
            track, ok := track_load_from_file(file)
            if ok {
                open_new_track(track)
            }
        }
    }

    when ODIN_DEBUG do gui_debug(0, height + height*0.5)

    // change cursor
    if mouse_cursor != gui_mouse_cursor {
        rl.SetMouseCursor(gui_mouse_cursor)
        mouse_cursor = gui_mouse_cursor
    }
}

// switch the active tile layer
// since the tile size changes for mapbox we need to recalculate center, scale and all the track points
switch_tile_layer :: proc(style: Layer_Style) {

    // TODO: Some sort of message for no api key
    if style != .Osm && state.config.api_keys[style] == "" {
        return
    }

    clear_cache(&state.cache)

    prev_tile_size := req_state.tile_layer.tile_size
    req_state.tile_layer = get_tile_layer(style, state.config.api_keys[style])
    tile_size := req_state.tile_layer.tile_size

    // This is pretty sketchy but we need to keep the relative scale the same when switching 
    // tile layers
    if prev_tile_size != tile_size {
        state.map_screen.center /= prev_tile_size
        state.map_screen.center *= tile_size
        scale_factor := prev_tile_size / tile_size

        step: f32 = (MAX_SCALE - MIN_SCALE)
        if scale_factor < 1.0 {
            step = -step
        }
        zoom_map(step, rl.GetScreenWidth(), rl.GetScreenHeight())
    }

    // recalc track
    if state.is_track_open {
        for point, i in state.track.points {
            state.draw_track.zoom = state.map_screen.zoom
            state.draw_track.coords[i] = coord_to_mercator(point.coord, state.map_screen.zoom)
        }
    }
}

// set the map screen to the center of the loaded track
center_map_to_track :: proc() {
    assert(state.is_track_open)

    // this just makes sure it works during initialization
    window_width, window_height: i32 = WINDOW_WIDTH, WINDOW_HEIGHT
    if rl.IsWindowReady() {
        window_width, window_height = rl.GetScreenWidth(), rl.GetScreenHeight()
    }

    coord, zoom := get_map_pos_from_track(state.track.points)
    state.map_screen.center = coord_to_mercator(coord, zoom)
    state.map_screen.zoom = zoom
    state.map_screen.scale = 1.0
    state.map_screen.width = window_width
    state.map_screen.height = window_height
}

open_new_track :: proc(track: Gps_Track) {
    // free all the previous track data
    if state.is_track_open {
        track_unload(&state.track)
        delete(state.draw_track.points)
        delete(state.draw_track.coords)
    }

    state.track = track

    // allocate for the draw track
    // the setup needs to come after we setup the map screen
    state.is_track_open = true
    state.draw_track.coords = make([]Mercator_Coord, len(state.track.points))
    state.draw_track.points = make([]rl.Vector2, len(state.track.points))
    state.draw_track.color = ORANGE

    center_map_to_track()
    state.draw_track.zoom = state.map_screen.zoom
    for i := 0; i < len(state.track.points); i += 1 {
        state.draw_track.coords[i] = coord_to_mercator(state.track.points[i].coord,
            state.draw_track.zoom)
    }
}

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
    // rescale after zoom
    state.map_screen.width = i32(f32(window_width) / state.map_screen.scale)
    state.map_screen.height = i32(f32(window_height) / state.map_screen.scale)
}

handle_input :: proc() {

    dt := rl.GetFrameTime()
    fps := rl.GetFPS()
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()
    if rl.IsWindowResized() {
        state.map_screen.width = i32(f32(window_width) / state.map_screen.scale)
        state.map_screen.height = i32(f32(window_height) / state.map_screen.scale)
    }

    mouse_pos := rl.GetMousePosition()
    scroll := rl.GetMouseWheelMove()

    //---Map Movement---

    // movement state
    @(static) move_state: struct {
        zoom_frame: i32,
        zoom_step: f32,
        mouse_zoom: bool,

        mouse_held: bool,
        velocity: rl.Vector2,
    }

    // don't allow panning and zooming when ui is focused
    if !state.ui_is_focused {

        // Zooming
        zoom_frames := i32(f32(fps) * ZOOM_TIME)
        if scroll != 0.0 {
            move_state.mouse_zoom = true
            move_state.zoom_frame = zoom_frames
            move_state.zoom_step = scroll > 0.0 ? ZOOM_STEP : -ZOOM_STEP
        } else if rl.IsKeyPressed(.EQUAL) {
            move_state.mouse_zoom = false
            move_state.zoom_frame = 2 * zoom_frames
            move_state.zoom_step = 2 * ZOOM_STEP
        } else if rl.IsKeyPressed(.MINUS) {
            move_state.mouse_zoom = false
            move_state.zoom_frame = 2 * zoom_frames
            move_state.zoom_step = -2 * ZOOM_STEP
        }

        // zoom animation takes zoom_frames to complete
        if move_state.zoom_frame > 0 {
            prev_zoom := state.map_screen.zoom
            prev_mouse_map_pos := screen_to_map(state.map_screen, mouse_pos)

            zoom_map(move_state.zoom_step / f32(zoom_frames), window_width, window_height)
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
    } else if move_state.mouse_held {
        move_state.mouse_held = false
        rl.SetMouseCursor(.DEFAULT)
    }
    // update from panning velocity
    // this is not supposed to do this while im writting comments
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

    // Keybinds
    if rl.IsKeyPressed(.F) {
        if rl.IsWindowMaximized() {
            rl.RestoreWindow()
        } else {
            rl.MaximizeWindow()
        }
    }
    if rl.IsKeyPressed(.R) {
        if state.is_track_open {
            center_map_to_track()
        }
    }
    if rl.IsKeyPressed(.O) {
        file := open_file_dialog()
        if file != "" {
            track, ok := track_load_from_file(file)
            if ok {
                open_new_track(track)
            }
        }
    }

    // since js file reading is async we handle it seperately
    when ODIN_OS != .JS {
        if rl.IsFileDropped() {
            dropped_files := rl.LoadDroppedFiles()
            files := dropped_files.paths[:dropped_files.count]
            file := files[0] // only load one file
            track, ok := track_load_from_file(string(file))
            if ok {
                open_new_track(track)
            }
            rl.UnloadDroppedFiles(dropped_files)
        }
    }
}

update :: proc() {
    // only evict when we are near the limit
    if rl.GetTime() - state.last_eviction > CACHE_TIMEOUT {
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

    // Tiles
    for item in tiles {
        src := rl.Rectangle{0, 0, f32(item.texture.width), f32(item.texture.height)}
        tile_rect := get_tile_rect(state.map_screen, item)
        rl.DrawTexturePro(item.texture, src, tile_rect, {}, 0, rl.WHITE)
        //rl.DrawRectangleLinesEx(tile_rect, 1, rl.PURPLE)
    }
    // Track
    if state.is_track_open {
        draw_track()
    }

    handle_ui()

    rl.EndDrawing()

    free_all(context.temp_allocator)
}


// Extra platform stuff for web
parent_window_size_changed :: proc(w, h: int) {
    rl.SetWindowSize(i32(w), i32(h))
}

should_run :: proc() -> bool {
    when ODIN_OS != .JS {
        return !rl.WindowShouldClose()
    } else {
        return true
    }
}

shutdown :: proc() {
    rl.CloseWindow()
    deinit_platform()
}

init :: proc() {

    // Raylib setup
    rl.SetTraceLogLevel(.ERROR)
    rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
    rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "jpx")
    rl.SetWindowMinSize(WINDOW_MIN_SIZE, WINDOW_MIN_SIZE)
    rl.SetWindowIcon(rl.LoadImageFromMemory(".png", raw_data(ICON_DATA), i32(len(ICON_DATA))))
    when !ODIN_DEBUG do rl.SetExitKey(.KEY_NULL)
    rl.SetTargetFPS(rl.GetMonitorRefreshRate(rl.GetCurrentMonitor()))
    rlgl.EnableSmoothLines()

    g_font = rl.LoadFontFromMemory(".ttf", raw_data(FONT_DATA), i32(len(FONT_DATA)), 96, nil, 0)
    rl.SetTextureFilter(g_font.texture, .BILINEAR)

    // initialize map screen if we didn't already from platform
    if !state.is_track_open {
        state.map_screen = Map_Screen {
            center = coord_to_mercator({23.5, 0}, 3),
            width = rl.GetScreenWidth(),
            height = rl.GetScreenHeight(),
            zoom = 3,
            scale = 1.0,
        }
    }

    // cache a few large tiles
    tile := mercator_to_tile(state.map_screen.center, state.map_screen.zoom)
    fallback := max(0, tile.zoom - ZOOM_FALLBACK_LIMIT)
    for _ in 0..<fallback {
        tile.x /= 2
        tile.y /= 2
        tile.zoom -= 1
        new_tile(&state.cache, tile)
    }
}
