#+build !js

package jpx

import "base:runtime"
import "core:log"
import "core:mem"
import "curl"

import rl "vendor:raylib"

@(private="file")
request_context: runtime.Context

init_request_platform :: proc() {
    request_context = context
    req_state.m_handle = curl.multi_init()
}

deinit_request_platform :: proc() {
    curl.multi_cleanup(req_state.m_handle)
}

_write_proc :: proc "c" (content: rawptr, size, nmemb: uint, user_data: rawptr) -> uint {
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

                ft: cstring = ".png" 
                style := req_state.tile_layer.style
                if style == .Mapbox_Satelite || style == .Mapbox_Outdoors {
                    ft = ".jpg"
                }
                // This guy allocates??
                img := rl.LoadImageFromMemory(ft, raw_data(chunk.data), i32(len(chunk.data)))
                delete(chunk.data)

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
                    rl.UnloadImage(img)
                } else {
                    delete_key(cache, tile)
                    log.error("Could not load tile")
                }
            } else {
                log.error("Request failed")
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
    curl.easy_setopt(handle, curl.OPT_WRITEFUNCTION, _write_proc)
    curl.easy_setopt(handle, curl.OPT_PRIVATE, chunk)

    curl.multi_add_handle(req_state.m_handle, handle)
}
