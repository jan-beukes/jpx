package jpx

// Map transformations and tile handling

import "core:math"
import "core:slice"
import "core:log"
import rl "vendor:raylib"
import "core:fmt"

MIN_ZOOM :: 2
ZOOM_FALLBACK_LIMIT :: 5

// (lon, lat) in degrees
Coord :: [2]f64

// this is in pixels
Mercator_Coord :: distinct [2]f64

Tile :: struct {
    x, y: i32,
    zoom: i32,
}

R :: 6371 * 1000 // meters
// The distance between 2 lon/lat coordinates in meters
// https://en.wikipedia.org/wiki/Haversine_formula
coord_distance :: proc(c1, c2: Coord) -> f32 {

    sin1 := math.sin((c2.y - c1.y) / 2.0) * math.sin((c2.y - c1.y) / 2.0)
    sin2 := math.sin((c2.x - c1.x) / 2.0) * math.sin((c2.x - c1.x) / 2.0)
    sqrt := math.sqrt(sin1 + math.cos(c1.y) * math.cos(c2.y) * sin2)
    d := 2*R * math.asin(sqrt)
    return f32(d)
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
    tile_size := req_state.tile_layer.tile_size // depends on the tile size from req state
    map_size := f64(n * int(tile_size))
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
    tile_size := req_state.tile_layer.tile_size
    n := 1 << u32(zoom)
    map_size := f64(n * int(tile_size))

    x := mercator.x / map_size
    y := mercator.y / map_size

    // transform unit square to lon/lat
    lon := (x - 0.5) * 360.0
    lat_rad := (0.5 - y) * math.TAU
    lat := math.atan(math.sinh(lat_rad)) * math.DEG_PER_RAD
    return Coord {
        lon,
        lat,
    }
}

// get which tile contains the mercator coord
mercator_to_tile :: #force_inline proc(mercator: Mercator_Coord, zoom: i32) -> Tile {
    tile_size := req_state.tile_layer.tile_size
    tile_x := i32(mercator.x / tile_size)
    tile_y := i32(mercator.y / tile_size)
    return Tile{tile_x, tile_y, zoom}
}

// mercator coordinates of the given tile
tile_to_mercator :: #force_inline proc(tile: Tile) -> Mercator_Coord {
    tile_size := req_state.tile_layer.tile_size
    return {
        f64(tile.x * i32(tile_size)),
        f64(tile.y * i32(tile_size)),
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
    zoom_diff := abs(map_screen.zoom - tile_data.zoom)
    tile_size := req_state.tile_layer.tile_size

    size: f32
    pos: rl.Vector2
    if zoom_diff != 0 {
        n := 1 << u32(zoom_diff)
        if map_screen.zoom > tile_data.zoom {
            size = f32(tile_size) * map_screen.scale * f32(n)
        } else {
            size = f32(tile_size) * map_screen.scale / f32(n)
        }
        coord := scale_mercator(tile_data.coord, tile_data.zoom, map_screen.zoom)
        pos = map_to_screen(map_screen, coord)
    } else {
        size = f32(tile_size) * map_screen.scale
        pos = map_to_screen(map_screen, tile_data.coord)
    }
    return {pos.x, pos.y, size, size}
}

get_map_center_from_track :: proc(track_points: [dynamic]Track_Point) -> Coord {
    return {}
}

// get the tile from cache and add it to the array
// we need to do this since higher res fallback will return 4 tiles
// if the tile is not present request tile and look for possible fallbacks
add_tile :: proc(tiles: []^Tile_Data, count: ^int, tile: Tile, cache: ^Tile_Cache) {
    n := i32(1 << u32(tile.zoom))

    if tile.x >= n || tile.x < 0 {
        return
    } else if tile.y >= n || tile.y < 0 {
        return
    } else if count^ + 4 >= len(tiles) {
        return
    }

    // found it in cache
    item, ok := cache[tile]
    if ok && item.ready {
        item.last_accessed = rl.GetTime()
        tiles[count^] = item
        count^ += 1
        return
    }

    // limit requests for free osm tiles a bit more
    max_requests: i32 = req_state.tile_layer.style == .Osm ? MAX_ACTIVE_REQUESTS / 2 : MAX_ACTIVE_REQUESTS

    // request the tile
    if !ok && len(cache) < CACHE_LIMIT && req_state.active_requests < max_requests {
        new_tile(cache, tile)
    } 

    // Fallback

    // First try to use a higher zoom tile
    if tile.zoom < req_state.tile_layer.max_zoom {
        x := tile.x * 2
        y := tile.y * 2
        z := tile.zoom + 1

        // make sure we have all 4
        smaller_tiles: [4]^Tile_Data
        found := 0
        outer: for i in 0..<2 {
            for j in 0..<2 {
                t := Tile{x + i32(j), y + i32(i), z} 
                item, ok := cache[t]
                if !ok {
                    break outer
                } else {
                    smaller_tiles[found] = item
                    found += 1
                }
            }
        }
        if found == 4 {
            copy(tiles[count^:], smaller_tiles[:])
            count^ += 4
            return
        }

    }
    // Then fallback to larger tiles
    fallback_tile := tile
    fallback_limit := max(tile.zoom - ZOOM_FALLBACK_LIMIT, 0)
    for fallback_tile.zoom > fallback_limit {
        fallback_tile.x /= 2
        fallback_tile.y /= 2
        fallback_tile.zoom -= 1
        item, ok := cache[fallback_tile]
        if ok && item.ready {
            item.last_accessed = rl.GetTime()
            tiles[count^] = item
            count^ += 1
            return
        }
    }
}

// calculate which tiles need to be rendered and add them to the list
// The tiles array will be sorted with lower zoom levels first
map_get_tiles :: proc(cache: ^Tile_Cache, map_screen: Map_Screen, allocator :=
    context.temp_allocator) -> []^Tile_Data {

    @(static) tiles: [512]^Tile_Data

    origin := map_screen.center - {
        0.5 * f64(map_screen.width),
        0.5 * f64(map_screen.height),
    }

    tile_size := req_state.tile_layer.tile_size
    start_pos := tile_to_mercator(mercator_to_tile(origin, map_screen.zoom))
    count := 0
    for y := start_pos.y; y < origin.y + f64(map_screen.height); y += tile_size {
        for x := start_pos.x; x < origin.x + f64(map_screen.width); x += tile_size {
            tile := mercator_to_tile({x, y}, map_screen.zoom)

            add_tile(tiles[:], &count, tile, cache)
        }
    }

    slice.sort_by(tiles[:count], proc(l, r: ^Tile_Data) -> bool {
        return l.zoom < r.zoom
    })

    return tiles[:count]
}
