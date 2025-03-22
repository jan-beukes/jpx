package main

import "core:math"
import "core:log"
import rl "vendor:raylib"
import "core:fmt"

// (lon, lat) in degrees
Coord :: [2]f64

// this is in pixels
Mercator_Coord :: distinct [2]f64

Tile :: struct {
    x, y: i32,
    zoom: i32,
}

MAX_ZOOM :: 19
MIN_ZOOM :: 1
ZOOM_FALLBACK_LIMIT :: 3

TILE_SIZE :: 256

// from lon/lat to a tile
coord_to_tile :: proc(coord: Coord, zoom: i32) -> Tile {
    n := 1 << u32(zoom)
    x_tile := i32(f64(n) * ((coord.x + 180.0) / 360.0))
    lat_rad := coord.y * math.RAD_PER_DEG
    y_tile := i32(f64(n) * (1.0 - (math.ln(math.tan(lat_rad) +
        (1.0 / math.cos(lat_rad))) / math.PI)) / 2.0)
    return Tile {x_tile, y_tile, zoom}
}

// from lon/lat to mercator coordinate
coord_to_mercator :: proc(coord: Coord, zoom: i32) -> Mercator_Coord {
    // project coord to web mercator
    lon := coord.x
    lat_rad := math.ln(math.tan(coord.y * math.RAD_PER_DEG) + 1.0 /
        math.cos(coord.y * math.RAD_PER_DEG))
    // transform to unit square
    x := 0.5 + lon / 360.0
    y := 0.5 - lat_rad / math.TAU

    // zoom and scale with tile size
    n := 1 << u32(zoom)
    map_size := f64(n * TILE_SIZE)
    x_pixel := x * map_size
    y_pixel := y * map_size
    return Mercator_Coord {
        x_pixel,
        y_pixel, 
    }

}

// from mercator coordinate to lon/lat
mercator_to_coord :: proc(mercator: Mercator_Coord, zoom: i32) -> Coord {
    // zoom and scale with tile size
    n := 1 << u32(zoom)
    map_size := f64(n * TILE_SIZE)

    x := mercator.x / map_size
    y := mercator.y / map_size

    // transform unit square to lon/lat
    lon := (x - 0.5) * 360.0
    lat_rad := (0.5 - y) * math.TAU
    lat := lat_rad * math.DEG_PER_RAD

    return Coord {
        lon,
        lat,
    }
}

// get which tile contains the mercator coord
mercator_to_tile :: #force_inline proc(mercator: Mercator_Coord, zoom: i32) -> Tile {
    tile_x := i32(mercator.x / TILE_SIZE)
    tile_y := i32(mercator.y / TILE_SIZE)
    return Tile{tile_x, tile_y, zoom}
}

// mercator coordinates of the given tile
tile_to_mercator :: #force_inline proc(tile: Tile) -> Mercator_Coord {
    return {
        f64(tile.x) * TILE_SIZE,
        f64(tile.y) * TILE_SIZE,
    }
}

// map mercator coord to screen pixel
map_to_screen :: #force_inline proc(map_screen: Map_Screen, coord: Mercator_Coord) -> rl.Vector2 {
    origin_x := map_screen.center.x - 0.5 * f64(map_screen.width)
    origin_y := map_screen.center.y - 0.5 * f64(map_screen.height)
    x := f32(coord.x - origin_x) * map_screen.scale
    y := f32(coord.y - origin_y) * map_screen.scale
    return {x, y}
}

// screen pixel to mercator coord
screen_to_map :: #force_inline proc(map_screen: Map_Screen, vec: rl.Vector2) -> Mercator_Coord {
    origin_x := map_screen.center.x - 0.5 * f64(map_screen.width)
    origin_y := map_screen.center.y - 0.5 * f64(map_screen.height)
    x := f64(vec.x / map_screen.scale) + origin_x
    y := f64(vec.y / map_screen.scale) + origin_y
    return {x, y}
}

// scale the mercator coord to the new zoom level
scale_mercator :: #force_inline proc(coord: Mercator_Coord, prev_z, new_z: i32) -> Mercator_Coord {
    if prev_z == new_z do return coord

    if new_z > prev_z {
        n := 1 << u32(new_z - prev_z)
        return coord * f64(n)
    } else {
        n := 1 << u32(prev_z - new_z)
        return coord / f64(n)
    }

}

// transform get tile dest rect from map screen scale and coord
get_tile_rect :: proc(map_screen: Map_Screen, tile_data: ^Tile_Data) -> rl.Rectangle {
    zoom_diff := map_screen.zoom - tile_data.zoom
    size: f32
    pos: rl.Vector2
    if zoom_diff > 0 {
        n := 1 << u32(zoom_diff)
        size = TILE_SIZE * map_screen.scale * f32(n)
        coord := scale_mercator(tile_data.coord, tile_data.zoom, map_screen.zoom)
        pos = map_to_screen(map_screen, coord)
    } else {
        size = TILE_SIZE * map_screen.scale
        pos = map_to_screen(map_screen, tile_data.coord)
    }
    return {pos.x, pos.y, size, size}
}

// get the tile from cache
// if the tile is not present request tile and look for possible fallbacks
get_tile :: proc(cache: ^Tile_Cache, tile: Tile) -> (^Tile_Data, bool) {
    n := i32(1 << u32(tile.zoom))
    if tile.x >= n || tile.x < 0 {
        return nil, false
    } else if tile.y >= n || tile.y < 0 {
        return nil, false
    }

    item, ok := cache[tile]
    if ok && item.ready {
        return item, false
    }

    // request the tile
    if !ok {
        request_tile(tile)
        // allocate so we know that this tile is busy
        tile_data := new(Tile_Data)
        cache[tile] = tile_data
    } 

    // try fallback
    fallback_limit := max(tile.zoom - ZOOM_FALLBACK_LIMIT, 0)
    for fallback_zoom := tile.zoom - 1; fallback_zoom > fallback_limit; fallback_zoom -= 1{
        coord := tile_to_mercator(tile)
        coord = scale_mercator(coord, tile.zoom, fallback_zoom)
        fallback_tile := mercator_to_tile(coord, fallback_zoom) 
        item, ok := cache[fallback_tile]
        if ok && item.ready {
            return item, true
        }
    }
    return nil, false
}

// calculate which tiles need to be rendered and add them to the list
// The tiles array will be sorted with lower zoom levels first
map_get_tiles :: proc(cache: ^Tile_Cache, map_screen: Map_Screen) -> []^Tile_Data {

    // Surely this will be fine
    @(static) tile_buf: [256]^Tile_Data
    tiles: [256]^Tile_Data
    fallbacks: [128]^Tile_Data

    origin := map_screen.center - {
        0.5 * f64(map_screen.width),
        0.5 * f64(map_screen.height),
    }

    start_pos := tile_to_mercator(mercator_to_tile(origin, map_screen.zoom))
    count, fallback_count := 0, 0
    for y := start_pos.y; y < origin.y + f64(map_screen.height); y += TILE_SIZE {
        for x := start_pos.x; x < origin.x + f64(map_screen.width); x += TILE_SIZE {
            tile := mercator_to_tile({x, y}, map_screen.zoom)
            tile_data, is_fallback := get_tile(cache, tile)
            if tile_data == nil {
                continue
            } else {
                if is_fallback {
                    fallbacks[fallback_count] = tile_data
                    fallback_count += 1
                } else {
                    tiles[count] = tile_data
                    count += 1
                }
            }
        }
    }
    // make sure fallbacks are first for rendering
    copy_slice(tile_buf[:], fallbacks[:])
    copy_slice(tile_buf[fallback_count:], tiles[:])
    total := fallback_count + count
    return tile_buf[:total]
}
