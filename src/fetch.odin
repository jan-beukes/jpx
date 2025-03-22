package main

import "core:mem"
import "core:fmt"
import "base:runtime"
import rl "vendor:raylib"
import stbp "vendor:stb/sprintf"
import "curl"

Tile_Item :: struct {
    coord: Mercator_Coord,
    texture: rl.Texture,
    access_timer: f32,
}

Tile_Chunk :: struct {
    tile: Tile,
    data: [dynamic]u8,
}

CACHE_LIMIT :: 128
Tile_Cache :: map[Tile]^Tile_Item

TILE_DOMAIN: cstring : "https://tile.openstreetmap.org/%d/%d/%d.png"
fetch_context: runtime.Context

tile_url :: proc(tile: Tile) -> cstring {
    @(static) url_buf: [1024]u8
    buf_ptr := raw_data(url_buf[:])
    stbp.sprintf(buf_ptr, TILE_DOMAIN, tile.zoom, tile.x, tile.y)
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

fetch_tile :: proc(cache: ^Tile_Cache, tile: Tile) {
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

    // upload texture
    img := rl.LoadImageFromMemory(".png", raw_data(chunk.data), i32(len(chunk.data)))
    texture := rl.LoadTextureFromImage(img)
    rl.SetTextureFilter(texture, .BILINEAR)
    delete(chunk.data)
    item := new(Tile_Item)
    item^ = Tile_Item {
        coord = tile_to_mercator(chunk.tile),
        texture = texture,
    }
    cache[chunk.tile] = item
}

clean_cache :: proc(cache: Tile_Cache) {
    for _, item in cache {
        free(item)
    }

}
