#+build js
package jpx

// web implementation of the platform specific code

import "base:runtime"
import "core:log"
import "core:time/datetime"
import "core:strings"
import rl "vendor:raylib"

@(private="file") request_context: runtime.Context
@(private="file") tile_cache: ^Tile_Cache

@(default_calling_convention="c")
foreign {
    fetchTile :: proc(urlPtr: rawptr, urlLen: i32, tile_x, tile_y, tile_z: i32) ---
}


// Init

init_platform :: proc() {
    // state across package is a little scary to manage
    tile_cache = &state.cache
    request_context = context
    flags: Flags
    init_tile_fetching(flags.layer_style, 
        state.config.api_keys[flags.layer_style])
}
deinit_platform :: proc() {
}

_track_load_from_file :: proc(file: string, allocator := context.allocator) -> (track: Gps_Track, ok: bool) {

    if strings.ends_with(file, ".gpx") {
        track, ok = track_load_from_gpx(file)
    } else {
        log.errorf("Could not load %s\nSupported formats: %s", file, SUPPORTED_FORMATS)
        track = {}
        ok = false
    }

    return
}

// need to seperate since timezone isn't implemented on web
// could implement this with js
date_time_to_local :: proc(date_time: ^datetime.DateTime) {
}

/**********
* REQUEST
***********/

// we need to pass these struct fields seperately since wasm only deals with primitives
@(export)
fetch_callback :: proc "c" (data: rawptr, len: i32, tile_x, tile_y, tile_z: i32) {
    context = request_context

    req_state.active_requests -= 1
    tile := Tile{tile_x, tile_y, tile_z}
    item, ok := tile_cache[tile]
    if !ok {
        return
    }
    if item.style != req_state.tile_layer.style {
        delete_key(tile_cache, tile)
        return
    }

    ft: cstring = ".png" 
    if item.style == .Mapbox_Satelite || item.style == .Mapbox_Outdoors {
        ft = ".jpg"
    }

    img := rl.LoadImageFromMemory(ft, data, len)
    if img.data != nil {
        texture := rl.LoadTextureFromImage(img)
        rl.SetTextureFilter(texture, .BILINEAR)
        rl.SetTextureWrap(texture, .MIRROR_REPEAT) // Mirrored wrap fixes bilinear filter sampling on edges
        item^ = Tile_Data {
            ready = true,
            coord = tile_to_mercator(tile),
            style = item.style,
            zoom = tile.zoom,
            texture = texture,
            last_accessed = rl.GetTime(),
        }
        rl.UnloadImage(img)
    }
}

request_tile :: proc(tile: Tile) {
    url := get_tile_url(tile)
    fetchTile(transmute([^]u8)url, i32(len(url)), tile.x, tile.y, tile.zoom)
}

poll_requests :: proc(cache: ^Tile_Cache) {
}
