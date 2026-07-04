#+build !js
package jpx

// Desktop implementation of the platform specific code

import "base:runtime"
import "core:container/queue"
import "core:encoding/ini"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time/datetime"
import "core:time/timezone"

import "vendor:curl"
import rl "vendor:raylib/v6"
import tinyfd "tinyfiledialogs"

CACHE_DIR :: ".cache"

USAGE :: `
Usage: jpx [OPTIONS] [FILE]

file formats: gpx

OPTIONS:
    -s          map style (0 - 3)
    -k          api key for provided map style
    --help      show this help
    --offline   only use local cached tiles
`


Tile_Save :: struct {
    tile:       Tile,
    style:      Layer_Style,
    style_name: cstring,
    img:        rl.Image,
}

Tile_Read :: struct {
    tile:       Tile,
    style:      Layer_Style,
    style_name: cstring,
}

Loaded_Tile :: struct {
    tile:  Tile,
    img:   rl.Image,
    style: Layer_Style,
}

Thread_Context :: struct {
    mutex:        sync.Mutex,
    loaded_tiles: queue.Queue(Loaded_Tile),
    read_queue:   queue.Queue(Tile_Read),
    save_queue:   queue.Queue(Tile_Save),
}

// platform request state
@(private="file")
m_handle: ^curl.CURLM
@(private="file")
request_context: runtime.Context
@(private="file")
thread_ctx: Thread_Context
@(private="file")
is_offline: bool

// the desktop specific initialization
init_platform :: proc(dir: string) {

    // flags and loading of config file
    flags := parse_flags(os.args)
    state.config = load_user_config()
    state.cache_to_disk = true

    // api key config
    api_key := strings.clone_to_cstring(flags.api_key)
    layer_style := flags.layer_style
    if layer_style != .Osm {
        if api_key != "" {
            // api key was provided
            state.config.api_keys[layer_style] = api_key
        } else if state.config.api_keys[layer_style] == "" {
            // no api key provided in config or args
            layer_style = .Osm
        }
    }

    init_tile_fetching(flags.layer_style, state.config.api_keys[flags.layer_style], flags.offline)

    // load track if input file was provided
    if flags.input_file == "" {
        state.is_track_open = false
    } else {
        // if launched from another directory we need to join the path given from main 
        // since we are currently in the directory of the executable
        file_path := flags.input_file
        if !os.is_absolute_path(file_path) {
            path, err := os.join_path({dir, file_path}, context.temp_allocator)
            if err != nil {
                log.error("Could not join paths: %v + %v", dir, flags.input_file)
            } else {
                file_path = path
            }
        }
        track, ok := track_load_from_file(file_path)
        if ok {
            open_new_track(track)
        }
    }

    // platform state
    request_context = context
    is_offline = flags.offline
    m_handle = curl.multi_init()
    thread.run(io_thread_proc)
}

deinit_platform :: proc() {
    curl.multi_cleanup(m_handle)
}

// Desktop flags/config

parse_flags :: proc(argv: []string) -> Flags {
    if len(argv) < 2 do return {}

    flags: Flags
    for i := 1; i < len(argv); i += 1 {
        is_last := i == len(argv) - 1

        // flags that expect a value can't be the last arg
        if (strings.starts_with(argv[i], "-")) {

            if strings.compare(argv[i], "-s") == 0 {
                if is_last {
                    fmt.eprint(USAGE)
                    os.exit(1)
                }
                i += 1
                num, ok := strconv.parse_int(argv[i])
                if !ok || num >= len(Layer_Style) {
                    fmt.eprint(USAGE)
                    os.exit(1)
                }
                flags.layer_style = Layer_Style(num)

            } else if strings.compare(argv[i], "-k") == 0 {
                if is_last {
                    fmt.eprint(USAGE)
                    os.exit(1)
                }
                i += 1
                flags.api_key = argv[i]

            } else if strings.compare(argv[i], "--offline") == 0 {
                flags.offline = true
            } else if strings.compare(argv[i], "--help") == 0 {
                fmt.println(USAGE)
                os.exit(0)
            } else {
                fmt.eprint(USAGE)
                os.exit(1)
            }
        } else {
            flags.input_file = argv[i]
        }
    }
    return flags
}

load_user_config :: proc() -> (config: Config) {
    config_map, _, ok := ini.load_map_from_path("jpx.ini", context.allocator)
    // no config
    if !ok {
        return
    }
    // API Keys
    if ("Keys" in config_map) {
        api_keys := config_map["Keys"]
        if "Jawg" in api_keys {
            config.api_keys[.Jawg] = strings.clone_to_cstring(api_keys["Jawg"])
        }
        if "Mapbox" in api_keys {
            key := strings.clone_to_cstring(api_keys["Mapbox"])
            config.api_keys[.Mapbox_Outdoors] = key
            config.api_keys[.Mapbox_Satelite] = key
        }
    }
    return
}

// TODO: Can I make this non blocking maybe?
// or at least tell the window that there is response
open_file_dialog :: proc() -> string {
    file := tinyfd.openFileDialog("Open file", nil, 0, nil, nil, 0)
    return string(file)
}

_track_load_from_file :: proc(
    file: string,
    allocator := context.allocator,
) -> (
    track: Gps_Track,
    ok: bool,
) {
    context.allocator = allocator

    ext := filepath.ext(file)
    if strings.compare(ext, ".gpx") == 0 {
        file_data, err := os.read_entire_file(file, allocator)
        if err != nil do return

        track, ok = track_load_from_gpx(file_data)
    } else {
        log.errorf("Could not load %s\nSupported formats: %s", file, SUPPORTED_FORMATS)
    }
    return
}

// need to seperate since timezone isn't implemented on web
date_time_to_local :: proc(date_time: ^datetime.DateTime) {
    tz, _ := timezone.region_load("local")
    date_time^, _ = timezone.datetime_to_tz(date_time^, tz)
}

/**********
* REQUEST
***********/

SEP :: filepath.SEPARATOR_STRING
get_tile_file :: proc(
    tile: Tile,
    style_name: cstring,
    ext: cstring,
    allocator := context.temp_allocator,
) -> cstring {

    return fmt.ctprintf(
        "%s" + SEP + "%s" + SEP + "%d" + SEP + "%d_%d%s",
        CACHE_DIR,
        style_name,
        tile.zoom,
        tile.x,
        tile.y,
        ext,
    )
}

io_thread_proc :: proc() {
    for {
        if rl.IsWindowReady() && rl.WindowShouldClose() do break

        read_ok, save_ok: bool
        read: Tile_Read
        save: Tile_Save

        sync.mutex_lock(&thread_ctx.mutex)
        read, read_ok = queue.pop_front_safe(&thread_ctx.read_queue)
        save, save_ok = queue.pop_front_safe(&thread_ctx.save_queue)
        sync.mutex_unlock(&thread_ctx.mutex)

        // TODO: Maybe switch to odin filesystem and image functions
        if read_ok {
            ft: cstring = ".png"
            file := get_tile_file(read.tile, read.style_name, ft)
            img := rl.LoadImage(file)
            if img.data != nil {
                sync.mutex_lock(&thread_ctx.mutex)
                queue.append(
                    &thread_ctx.loaded_tiles,
                    Loaded_Tile{tile = read.tile, style = read.style, img = img},
                )
                sync.mutex_unlock(&thread_ctx.mutex)
            }
        }
        if save_ok {
            ft: cstring = ".png"
            file := get_tile_file(save.tile, save.style_name, ft)
            dirpath := rl.GetDirectoryPath(file)
            if !rl.DirectoryExists(dirpath) {
                rl.MakeDirectory(dirpath)
            }
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
    // poll tiles from disk
    if state.cache_to_disk {
        //log.debug(thread_ctx.loaded_tiles)
        sync.mutex_try_lock(&thread_ctx.mutex)
        for thread_ctx.loaded_tiles.len > 0 {
            loaded := queue.pop_front(&thread_ctx.loaded_tiles)
            item, ok := cache[loaded.tile]
            if loaded.style == req_state.tile_layer.style && ok {
                texture := rl.LoadTextureFromImage(loaded.img)
                rl.SetTextureFilter(texture, .BILINEAR)
                rl.SetTextureWrap(texture, .MIRROR_REPEAT)
                item^ = {
                    ready         = true,
                    coord         = tile_to_mercator(loaded.tile),
                    zoom          = loaded.tile.zoom,
                    texture       = texture,
                    style         = loaded.style,
                    last_accessed = rl.GetTime(),
                }
            } else {
                delete_key(cache, loaded.tile)
            }
            rl.UnloadImage(loaded.img)
        }
        sync.mutex_unlock(&thread_ctx.mutex)
    }

    // Curl
    curl.multi_perform(m_handle, &req_state.active_requests)

    msg: ^curl.Msg
    msgs_left: i32
    msg = curl.multi_info_read(m_handle, &msgs_left)
    for msg != nil {
        // this one is done
        if msg.msg == .DONE {
            handle := msg.easy_handle

            chunk: ^Tile_Chunk
            curl.easy_getinfo(handle, .PRIVATE, &chunk)

            // check for error on fetch
            result_ok: if msg.data.result == .E_OK {

                tile := chunk.tile
                item, ok := cache[tile]
                // This can happen when a tile was cleaned up after the map style changed while it's
                // request was active
                if !ok {
                    break result_ok
                }

                ft: cstring = ".png"
                if item.style == .Mapbox_Satelite || item.style == .Mapbox_Outdoors {
                    ft = ".jpg"
                }

                // This guy allocates??
                img, err := load_tile_image_from_data(chunk.data[:])

                // we also need to make sure that the tile's style is the same as what we are using
                if item.style != req_state.tile_layer.style {
                    delete_key(cache, tile)
                    rl.UnloadImage(img)
                } else if err == nil {
                    texture := rl.LoadTextureFromImage(img)
                    rl.SetTextureFilter(texture, .BILINEAR)
                    rl.SetTextureWrap(texture, .MIRROR_REPEAT) // Mirrored wrap fixes bilinear filter sampling on edges
                    item^ = Tile_Data {
                        ready         = true,
                        coord         = tile_to_mercator(chunk.tile),
                        style         = item.style,
                        zoom          = tile.zoom,
                        texture       = texture,
                        last_accessed = rl.GetTime(),
                    }

                    // save the requested tile to disk
                    if state.cache_to_disk {
                        sync.mutex_lock(&thread_ctx.mutex)
                        queue.append(
                            &thread_ctx.save_queue,
                            Tile_Save {
                                tile = tile,
                                style = item.style,
                                style_name = req_state.tile_layer.name,
                                img = img,
                            },
                        )
                        sync.mutex_unlock(&thread_ctx.mutex)
                    } else {
                        rl.UnloadImage(img)
                    }

                } else {
                    delete_key(cache, tile)
                    log.error("Could not load tile as an image:", err)
                    if ODIN_DEBUG {
                        _ = os.write_entire_file("response.dat", chunk.data[:])
                    }
                }
            } else {
                log.error("Request failed", msg.data.result)
            }

            // cleanup
            delete(chunk.data)
            free(chunk)
            curl.multi_remove_handle(m_handle, handle)
            curl.easy_cleanup(handle)
        }
        msg = curl.multi_info_read(m_handle, &msgs_left)
    }
}

request_tile :: proc(tile: Tile) -> bool {

    // since offline can only get tiles from cache cache_to_disk option is ignored
    if state.cache_to_disk || is_offline {
        tile_layer := req_state.tile_layer
        ft: cstring = ".png"
        if tile_layer.style == .Mapbox_Satelite || tile_layer.style == .Mapbox_Outdoors {
            ft = ".jpg"
        }

        file := get_tile_file(tile, tile_layer.name, ft)
        if rl.FileExists(file) {
            sync.mutex_lock(&thread_ctx.mutex)
            queue.append(
                &thread_ctx.read_queue,
                Tile_Read{style = tile_layer.style, style_name = tile_layer.name, tile = tile},
            )
            sync.mutex_unlock(&thread_ctx.mutex)
            return true
        } else if is_offline {
            // file is not cached on disk so we just don't try to load it offline
            return false
        }
    }

    // allocate a chunk for writing
    chunk := new(Tile_Chunk)
    chunk.tile = tile

    handle := curl.easy_init()
    url := get_tile_url(tile)
    curl.easy_setopt(handle, .URL, url)
    curl.easy_setopt(handle, .USERAGENT, "libcurl-agent/1.0")
    curl.easy_setopt(handle, .WRITEDATA, chunk)
    curl.easy_setopt(handle, .WRITEFUNCTION, _write_proc)
    curl.easy_setopt(handle, .PRIVATE, chunk)

    curl.multi_add_handle(m_handle, handle)
    return true
}
