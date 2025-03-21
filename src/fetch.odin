package main

import "core:mem"
import "core:fmt"
import "base:runtime"
import rl "vendor:raylib"
import stbp "vendor:stb/sprintf"
import "curl"

Cache_Entry :: struct {
    tile: Tile,
    texture: rl.Texture,
}

Tile_Chunk :: struct {
    tile: Tile,
    data: [dynamic]u8,
}

TILE_DOMAIN: cstring : "https://tile.openstreetmap.org/%d/%d/%d.png"
fetch_context: runtime.Context

tile_url :: proc(tile: Tile) -> cstring {
    @(static) url_buf: [1024]u8
    buf_ptr := raw_data(url_buf[:])
    stbp.sprintf(buf_ptr, TILE_DOMAIN, tile.zoom, tile.x, tile.y)
    fmt.println(cstring(buf_ptr))
    return cstring(buf_ptr)
}

write_proc :: proc "c" (content: rawptr, size, nmemb: uint, user_data: rawptr) -> uint {
    context = fetch_context
    num_bytes := size * nmemb
    chunk := cast(^Tile_Chunk)user_data
    data_slice := mem.slice_ptr(cast(^u8)(content), int(num_bytes))
    append(&chunk.data, ..data_slice)

    return num_bytes
}

fetch_tile :: proc(tile: Tile) -> Cache_Entry {
    handle := curl.easy_init()
    defer curl.easy_cleanup(handle)

    // blocking so on stack
    chunk := Tile_Chunk {
        tile = tile,
    }
    fetch_context = context

    url := tile_url(tile)
    curl.easy_setopt(handle, curl.OPT_URL, url)
    curl.easy_setopt(handle, curl.OPT_USERAGENT, "libcurl-agent/1.0")
    curl.easy_setopt(handle, curl.OPT_WRITEDATA, &chunk)
    curl.easy_setopt(handle, curl.OPT_WRITEFUNCTION, write_proc)
    curl.easy_setopt(handle, curl.OPT_PRIVATE, &chunk)

    curl.easy_perform(handle)
    fmt.println("Got Tile", chunk.tile, len(chunk.data))

    // upload texture
    img := rl.LoadImageFromMemory(".png", raw_data(chunk.data), i32(len(chunk.data)))
    texture := rl.LoadTextureFromImage(img)
    delete(chunk.data)
    return Cache_Entry {
        tile = chunk.tile,
        texture = texture,
    }
}
