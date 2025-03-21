package main

import "core:math"
import "core:fmt"

// (lon, lat) in degrees
Coord :: [2]f64

// this is in pixels
Mercator_Coord :: [2]int

Tile :: struct {
    x, y: i32,
    zoom: i32,
}

MAX_LAT :: 85.051129
TILE_SIZE :: 256

coord_to_tile :: proc(coord: Coord, zoom: i32) -> Tile {
    n := 1 << u32(zoom)
    x_tile := i32(f64(n) * ((coord.x + 180.0) / 360.0))
    lat_rad := coord.y * math.RAD_PER_DEG
    y_tile := i32(f64(n) * (1.0 - (math.ln(math.tan(lat_rad) + (1.0 / math.cos(lat_rad))) / math.PI)) / 2.0)
    return Tile {x_tile, y_tile, zoom}
}

coord_to_mercator :: proc(coord: Coord, zoom: i32) -> Mercator_Coord {
    // project coord to web mercator
    lon := coord.x
    lat_rad := math.ln(math.tan(coord.y * math.RAD_PER_DEG) + 1.0 / math.cos(coord.y * math.RAD_PER_DEG))
    // transform to unit square
    x := 0.5 + lon / 360.0
    y := 0.5 - lat_rad / math.TAU
    fmt.println(y)

    // zoom and scale with tile size
    n := 1 << u32(zoom)
    map_size := f64(n * TILE_SIZE)
    x_pixel := x * map_size
    y_pixel := y * map_size
    return Mercator_Coord {
        int(x_pixel),
        int(y_pixel), 
    }

}

mercator_to_tile :: #force_inline proc(mercator: Mercator_Coord, zoom: i32) -> Tile {
    tile_x := i32(mercator.x / TILE_SIZE)
    tile_y := i32(mercator.y / TILE_SIZE)
    return Tile{tile_x, tile_y, zoom}
}

tile_to_mercator :: #force_inline proc(tile: Tile) -> Mercator_Coord {
    return {
        int(tile.x * TILE_SIZE),
        int(tile.y * TILE_SIZE),
    }
}

mercator_to_coord :: proc(mercator: Mercator_Coord, zoom: i32) -> Coord {
    x := f64(mercator.x) / TILE_SIZE
    y := f64(mercator.y) / TILE_SIZE

    // transform unit square to lon/lat
    lon := (x - 0.5) * 360.0
    lat_rad := (0.5 - y) * math.TAU
    lat := lat_rad * math.DEG_PER_RAD

    return Coord {
        lon,
        lat,
    }
}
