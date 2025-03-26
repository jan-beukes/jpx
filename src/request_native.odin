#+build !js

package jpx

import "base:runtime"
import "core:path/filepath"
import "core:fmt"
import "core:os"
import "core:thread"
import "core:sync"
import "core:container/queue"
import "core:log"
import "core:mem"

import "curl"
import rl "vendor:raylib"

CACHE_DIR :: ".cache"

Tile_Save :: struct {
    tile: Tile,
    style: Layer_Style,
    style_name: cstring,
    img: rl.Image,
}

Tile_Read :: struct {
    tile: Tile,
    style: Layer_Style,
    style_name: cstring,
}

Loaded_Tile :: struct {
    tile: Tile,
    img: rl.Image,
    style: Layer_Style,
}

Thread_Context :: struct {
    mutex: sync.Mutex,

    loaded_tiles: queue.Queue(Loaded_Tile),

    read_queue: queue.Queue(Tile_Read),
    save_queue: queue.Queue(Tile_Save),
}

@(private="file")
request_context: runtime.Context
@(private="file")
thread_ctx: Thread_Context

init_request_platform :: proc() {
    request_context = context
    req_state.m_handle = curl.multi_init()
    thread.run(io_thread_proc)
}

deinit_request_platform :: proc() {
    curl.multi_cleanup(req_state.m_handle)
}

SEP :: filepath.SEPARATOR_STRING
get_tile_file :: proc(tile: Tile, style_name: cstring, ext: cstring,
    allocator := context.temp_allocator) -> cstring {

    return fmt.ctprintf("%s" + SEP + "%s" + SEP + "%d" + SEP + "%d_%d%s", 
        CACHE_DIR, style_name, tile.zoom, tile.x, tile.y, ext)
}

io_thread_proc :: proc () {
    for {
        if rl.IsWindowReady() && rl.WindowShouldClose() do break

        read_ok, save_ok: bool
        read: Tile_Read
        save: Tile_Save

        sync.mutex_lock(&thread_ctx.mutex)
        read, read_ok = queue.pop_front_safe(&thread_ctx.read_queue)
        save, save_ok = queue.pop_front_safe(&thread_ctx.save_queue)
        sync.mutex_unlock(&thread_ctx.mutex)

        if read_ok {
            ft: cstring = read.style == .Mapbox_Outdoors || read.style == .Mapbox_Satelite ? ".jpg" : ".png"
            file := get_tile_file(read.tile, read.style_name, ft)
            img := rl.LoadImage(file)
            if img.data != nil {
                sync.mutex_lock(&thread_ctx.mutex)
                queue.append(&thread_ctx.loaded_tiles, Loaded_Tile {
                    tile = read.tile,
                    style = read.style,
                    img = img,
                })
                sync.mutex_unlock(&thread_ctx.mutex)
            }
        }
        if save_ok {
            ft: cstring = save.style == .Mapbox_Outdoors || save.style == .Mapbox_Satelite ? ".jpg" : ".png"
            file := get_tile_file(save.tile, save.style_name, ft)
            rl.MakeDirectory(rl.GetDirectoryPath(file))
            if !rl.ExportImage(save.img, file) {
                fmt.eprintln("Could not cache tile", file)
            }
            rl.UnloadImage(save.img)
        }

        if save_ok || read_ok {
            free_all(context.temp_allocator)
        }
    }
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

    if state.cache_to_disk {
        sync.mutex_try_lock(&thread_ctx.mutex)
        //log.debug(thread_ctx.loaded_tiles)
        for thread_ctx.loaded_tiles.len > 0 {
            loaded := queue.pop_front(&thread_ctx.loaded_tiles)
            item, ok := cache[loaded.tile]
            if loaded.style == req_state.tile_layer.style {
                if ok {
                    texture := rl.LoadTextureFromImage(loaded.img)
                    rl.SetTextureFilter(texture, .BILINEAR)
                    rl.SetTextureWrap(texture, .MIRROR_REPEAT)
                    item^ = {
                        ready = true,
                        coord = tile_to_mercator(loaded.tile),
                        zoom = loaded.tile.zoom,
                        texture = texture,
                        style = loaded.style,
                        last_accessed = rl.GetTime(),
                    }
                } else {
                    delete_key(cache, loaded.tile)
                }
            }
            rl.UnloadImage(loaded.img)
        }
        sync.mutex_unlock(&thread_ctx.mutex)
    }

    // Curl
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
            result_ok: if msg.data.result == curl.E_OK {

                tile := chunk.tile
                item := cache[tile]
                
                style := req_state.tile_layer.style
                if item.style != req_state.tile_layer.style {
                    break result_ok
                }

                ft: cstring = ".png" 
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
                    item^ = Tile_Data {
                        ready = true,
                        coord = tile_to_mercator(chunk.tile),
                        zoom = tile.zoom,
                        texture = texture,
                        style = req_state.tile_layer.style,
                        last_accessed = rl.GetTime(),
                    }

                    if state.cache_to_disk {
                        sync.mutex_lock(&thread_ctx.mutex)
                        queue.append(&thread_ctx.save_queue, Tile_Save {
                            tile = tile,
                            style = style,
                            style_name = req_state.tile_layer.name,
                            img = img,
                        })
                        sync.mutex_unlock(&thread_ctx.mutex)
                    } else {
                        rl.UnloadImage(img)
                    }
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

    if state.cache_to_disk {
        tile_layer := req_state.tile_layer
        ft: cstring = ".png" 
        if tile_layer.style == .Mapbox_Satelite || tile_layer.style == .Mapbox_Outdoors {
            ft = ".jpg"
        }

        file := get_tile_file(tile, tile_layer.name, ft)
        if rl.FileExists(file) {
            sync.mutex_lock(&thread_ctx.mutex)
            queue.append(&thread_ctx.read_queue, Tile_Read {
                style = tile_layer.style,
                style_name = tile_layer.name,
                tile = tile,
            })
            sync.mutex_unlock(&thread_ctx.mutex)
            return
        }
    }

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
