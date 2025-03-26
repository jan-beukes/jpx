package jpx

import "core:mem"
import "core:fmt"
import "core:log"
import "base:runtime"

import rl "vendor:raylib"

MAX_ACTIVE_REQUESTS :: 32
CACHE_LIMIT :: 1024
EVICTION_SIZE :: 256
CACHE_TIMEOUT :: 2.0

Tile_Data :: struct {
    ready: bool,
    coord: Mercator_Coord,
    zoom: i32,
    texture: rl.Texture,
    style: Layer_Style,
    last_accessed: f64,
}

Tile_Chunk :: struct {
    tile: Tile,
    data: [dynamic]u8,
}

Tile_Cache :: map[Tile]^Tile_Data

Layer_Style :: enum i32 {
    Osm,
    Jawg,
    Mapbox_Outdoors,
    Mapbox_Satelite,
}

// Prover URLS
OSM_URL: cstring : "https://tile.openstreetmap.org/%d/%d/%d.png"
JAWG_URL: cstring :
"https://tile.jawg.io/jawg-terrain/%d/%d/%d.png?access-token=%s&lang=en"
MAPBOX_OUTDOORS_URL: cstring :
"https://api.mapbox.com/styles/v1/mapbox/outdoors-v12/tiles/%d/%d/%d?access_token=%s"
MAPBOX_SATELITE_URL: cstring :
"https://api.mapbox.com/styles/v1/mapbox/satellite-streets-v12/tiles/%d/%d/%d?access_token=%s"

Tile_Layer :: struct {
    style: Layer_Style,
    url: cstring,
    name: cstring,
    api_key: cstring,
    max_zoom: i32,
    tile_size: f64,
    clear_color: rl.Color,
}

// global
req_state: struct {
    m_handle: rawptr, // the global multi handle for libcurl
    active_requests: i32,
    tile_layer: Tile_Layer,
}

init_tile_fetching :: proc(style: Layer_Style, api_key: cstring) {
    init_request_platform()
    req_state.active_requests = 0
    req_state.tile_layer = get_tile_layer(style, api_key)
}

// switch the active layer to style
get_tile_layer :: proc(style: Layer_Style, api_key := cstring("")) -> Tile_Layer {
    url: cstring
    name: cstring
    max_zoom: i32
    tile_size: f64
    clear_color: rl.Color

    switch style {
    case .Osm: {
        url = OSM_URL
        name = "Osm"
        max_zoom = 19
        tile_size = 256
        clear_color = rl.GetColor(0xF2EFE9FF)
    }
    case .Jawg: {
        url = JAWG_URL
        name = "Jawg"
        max_zoom = 22
        tile_size = 256
        clear_color = rl.GetColor(0xFEF6EEFF)
    }
    case .Mapbox_Satelite: {
        url = MAPBOX_SATELITE_URL
        name = "Mapbox_Satelite"
        max_zoom = 22
        tile_size = 512
        clear_color = rl.GetColor(0x040810FF)
    }
    case .Mapbox_Outdoors: {
        url = MAPBOX_OUTDOORS_URL
        name = "Mapbox_Outdoors"
        max_zoom = 22
        tile_size = 512
        clear_color = rl.GetColor(0xE1E1D2FF)
    }
    }
    return Tile_Layer {
        style = style,
        url = url,
        name = name,
        api_key = api_key,
        max_zoom = max_zoom,
        tile_size = tile_size,
        clear_color = clear_color,
    }
}

deinit_tile_fetching :: proc() {
    deinit_request_platform()
    req_state.active_requests = 0
}

get_tile_url :: proc(tile: Tile) -> cstring {
    if req_state.tile_layer.style == .Osm {
        return rl.TextFormat(req_state.tile_layer.url, tile.zoom, tile.x, tile.y)
    } else {
        return rl.TextFormat(req_state.tile_layer.url, tile.zoom, tile.x, tile.y,
            req_state.tile_layer.api_key)
    }
}

new_tile :: proc(cache: ^Tile_Cache, tile: Tile) {
    // allocate so we know that this tile is busy
    tile_data := new(Tile_Data)
    tile_data.style = req_state.tile_layer.style
    cache[tile] = tile_data

    request_tile(tile)
    req_state.active_requests += 1
}

// tiles that have a last use longer than timeout are evicted
// don't evict fallback tiles that contain the camera
evict_cache :: proc(cache: ^Tile_Cache, map_screen: Map_Screen) {
    for key, item in cache {
        if !item.ready do continue

        time := rl.GetTime()
        if time - item.last_accessed < CACHE_TIMEOUT {
            continue
        }
        // check if this is a fallback tile
        coord := scale_mercator(map_screen.center, map_screen.zoom, key.zoom)
        screen_tile := mercator_to_tile(coord, key.zoom)
        if key == screen_tile {
            continue
        }

        rl.UnloadTexture(item.texture)
        free(item)
        delete_key(cache, key)
    }
}

clear_cache :: proc(cache: ^Tile_Cache) {
    for key, item in cache {
        rl.UnloadTexture(item.texture)
        free(item)
        delete_key(cache, key)
    }
}
