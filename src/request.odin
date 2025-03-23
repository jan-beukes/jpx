package jpx

import "core:mem"
import "core:fmt"
import "core:log"
import "base:runtime"

import rl "vendor:raylib"
import "curl"

Tile_Data :: struct {
    ready: bool,
    coord: Mercator_Coord,
    zoom: i32,
    texture: rl.Texture,
    last_accessed: f64,
}

Tile_Chunk :: struct {
    tile: Tile,
    data: [dynamic]u8,
}

Tile_Cache :: map[Tile]^Tile_Data

Layer_Style :: enum i32 {
    Osm,
    Thunderforest,
    Mapbox_Satelite,
    Mapbox_Outdoors,
}

Tile_Layer :: struct {
    type: Layer_Style,
    url: cstring,
    api_key: cstring,
}

CACHE_LIMIT :: 128
CACHE_TIMEOUT :: 5.0

OSM_URL: cstring : "https://tile.openstreetmap.org/%d/%d/%d.png"
THUNDERFOREST_URL: cstring : "https://tile.thunderforest.com/outdoors/%d/%d/%d.png?apikey=%s"
MAPBOX_SATELITE_URL: cstring : ""
MAPBOX_OUTDOORS_URL: cstring : ""

@(private="file")
request_context: runtime.Context

req_state: struct {
    m_handle: rawptr, // the global multi handle for libcurl
    active_requests: i32,
    tile_layer: Tile_Layer,
}

init_tile_fetching :: proc(layer_style: Layer_Style, api_key: cstring) {
    request_context = context
    req_state.m_handle = curl.multi_init()
    req_state.active_requests = 0
    switch_tile_layer(layer_style, api_key)
}

switch_tile_layer :: proc(type: Layer_Style, api_key := cstring("")) {
    url: cstring
    switch type {
    case .Osm: url = OSM_URL
    case .Thunderforest: url = THUNDERFOREST_URL
    case .Mapbox_Satelite: url = MAPBOX_SATELITE_URL
    case .Mapbox_Outdoors: url = MAPBOX_OUTDOORS_URL
    }
    req_state.tile_layer = Tile_Layer {
        type = type,
        url = url,
        api_key = api_key,
    }
}

deinit_tile_fetching :: proc() {
    curl.multi_cleanup(req_state.m_handle)
    req_state.active_requests = 0
}

get_tile_url :: proc(tile: Tile) -> cstring {
    if req_state.tile_layer.type == .Osm {
        return rl.TextFormat(req_state.tile_layer.url, tile.zoom, tile.x, tile.y)
    } else {
        return rl.TextFormat(req_state.tile_layer.url, tile.zoom, tile.x, tile.y,
            req_state.tile_layer.api_key)
    }
}

write_proc :: proc "c" (content: rawptr, size, nmemb: uint, user_data: rawptr) -> uint {
    context = request_context
    num_bytes := size * nmemb
    chunk := cast(^Tile_Chunk)user_data
    data_slice := mem.slice_ptr(cast([^]u8)(content), int(num_bytes))
    append(&chunk.data, ..data_slice)

    return num_bytes
}

poll_requests :: proc(cache: ^Tile_Cache) {

    curl.multi_perform(req_state.m_handle, &req_state.active_requests)

    msg: ^curl.CURLMsg
    msgs_left: i32
    msg = curl.multi_info_read(req_state.m_handle, &msgs_left)
    for msg != nil {
        // this one is done
        if msg.msg == curl.MSG_DONE {
            handle := msg.easy_handle

            chunk: ^Tile_Chunk
            curl.easy_getinfo(handle, curl.INFO_PRIVATE, &chunk)

            // check for error on fetch
            if msg.data.result == curl.E_OK {

                tile := chunk.tile

                // upload texture
                img := rl.LoadImageFromMemory(".png", raw_data(chunk.data), i32(len(chunk.data)))
                if img.data != nil {
                    texture := rl.LoadTextureFromImage(img)
                    rl.SetTextureFilter(texture, .BILINEAR)
                    // Mirrored wrap fixes bilinear filter sampling on edges
                    rl.SetTextureWrap(texture, .MIRROR_REPEAT) 
                    item := cache[tile]
                    item^ = Tile_Data {
                        ready = true,
                        coord = tile_to_mercator(chunk.tile),
                        zoom = tile.zoom,
                        texture = texture,
                        last_accessed = rl.GetTime(),
                    }
                } else {
                    delete_key(cache, tile)
                    log.error("Could not get tile, maybe bad api key?")
                }

                delete(chunk.data)
            } else {
                // free memory on fail
                delete(chunk.data)
                log.error("Could not get tile, maybe bad api key?")
            }

            // cleanup
            free(chunk)
            curl.multi_remove_handle(req_state.m_handle, handle)
            curl.easy_cleanup(handle)
        }
        msg = curl.multi_info_read(req_state.m_handle, &msgs_left)
    }
}

request_tile :: proc(tile: Tile) {
    // allocate a chunk
    chunk := new(Tile_Chunk)
    chunk.tile = tile

    handle := curl.easy_init()
    url := get_tile_url(tile)
    curl.easy_setopt(handle, curl.OPT_URL, url)
    curl.easy_setopt(handle, curl.OPT_USERAGENT, "libcurl-agent/1.0")
    curl.easy_setopt(handle, curl.OPT_WRITEDATA, chunk)
    curl.easy_setopt(handle, curl.OPT_WRITEFUNCTION, write_proc)
    curl.easy_setopt(handle, curl.OPT_PRIVATE, chunk)

    curl.multi_add_handle(req_state.m_handle, handle)
}

// tiles that have a last use longer than timeout are evicted
// don't evict tiles that contain the camera
evict_cache :: proc(cache: ^Tile_Cache) {
    // TODO: Implement
    for _, item in cache {
        rl.UnloadTexture(item.texture)
        free(item)
    }
}

clear_cache :: proc(cache: ^Tile_Cache) {
    for _, item in cache {
        rl.UnloadTexture(item.texture)
        free(item)
    }
}
