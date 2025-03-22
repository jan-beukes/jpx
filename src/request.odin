package main

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

CACHE_LIMIT :: 128
CACHE_TIMEOUT :: 5.0
Tile_Cache :: map[Tile]^Tile_Data

TILE_DOMAIN: cstring : "https://tile.openstreetmap.org/%d/%d/%d.png"

@(private="file")
request_context: runtime.Context

multi_handle: rawptr
active_requests: i32

init_tile_fetching :: proc() {
    request_context = context
    multi_handle = curl.multi_init()
    active_requests = 0
}

deinit_tile_fetching :: proc() {
    curl.multi_cleanup(multi_handle)
    active_requests = 0
}

get_tile_url :: proc(tile: Tile) -> cstring {
    return rl.TextFormat(TILE_DOMAIN, tile.zoom, tile.x, tile.y)
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

    curl.multi_perform(multi_handle, &active_requests)

    msg: ^curl.CURLMsg
    msgs_left: i32
    msg = curl.multi_info_read(multi_handle, &msgs_left)
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
                texture := rl.LoadTextureFromImage(img)
                rl.SetTextureFilter(texture, .BILINEAR)

                item := cache[tile]
                item^ = Tile_Data {
                    ready = true,
                    coord = tile_to_mercator(chunk.tile),
                    zoom = tile.zoom,
                    texture = texture,
                    last_accessed = rl.GetTime(),
                }

                delete(chunk.data)
            } else {
                // free memory on fail
                delete(chunk.data)
                log.error("Tile download failed")
            }

            // cleanup
            free(chunk)
            curl.multi_remove_handle(multi_handle, handle)
            curl.easy_cleanup(handle)
        }
        msg = curl.multi_info_read(multi_handle, &msgs_left)
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

    curl.multi_add_handle(multi_handle, handle)
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
