package track

// Loading and handling of a gps tracks / activities

import "base:runtime"
import "core:path/filepath"
import "core:mem"
import "core:time/datetime"
import "core:time/timezone"
import "core:time"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:fmt"

import "core:encoding/xml"

Coord :: [2]f64

SUPPORTED_FORMATS :: "gpx"

Activity_Type :: enum {
    None,
    Running,
    Cycling,
}

Track_Point :: struct {
    coord: Coord,
    elevation: i32,
    time: u64, // seconds
    hr: i32,
    distance: f32,
    speed: f32,
}

Metadata :: struct {
    text: cstring,
    date_time: datetime.DateTime,
}

Gps_Track :: struct {
    metadata: Metadata,
    points: [dynamic]Track_Point,
    name: cstring,
    type: Activity_Type,
    allocator: runtime.Allocator
}

@(rodata)
activity_types := [Activity_Type]string {
    .None = "",
    .Running = "running",
    .Cycling = "cycling",
}

load_from_file :: proc(file: string, allocator := context.allocator) -> (track: Gps_Track, ok: bool) {
    context.allocator = allocator

    ext := filepath.ext(file)
    if strings.compare(ext, ".gpx") == 0 {
        track, ok = load_from_gpx(file)
    } else {
        log.errorf("Could not load %s\nSupported formats: %s", file, SUPPORTED_FORMATS)
        track = {}
        ok = false
    }

    return
}

load_from_gpx :: proc(file: string) -> (track: Gps_Track, ok: bool) {
    ok = true
    doc, err := xml.load_from_file(file)
    if err != nil {
        return {}, false
    }
    defer xml.destroy(doc)

    // store the allocator for unload
    track.allocator = context.allocator

    root := doc.elements[0]
    for value in root.value {
        switch v in value {
        case string: {
            log.error("Invalid gpx format")
            return {}, false
        }
        case xml.Element_ID: {
            id := value.(xml.Element_ID)
            indent := doc.elements[id].ident
            if strings.compare(indent, "metadata") == 0 {
                track.metadata = get_metadata(doc.elements, id)
                log.debug("Metadata:", track.metadata.text, track.metadata.date_time.date,
                    track.metadata.date_time.time)
            } else if strings.compare(indent, "trk") == 0 {
                load_track(&track, doc.elements, id)
            } else {
                log.error("Invalid gpx format")
                return {}, false
            }
        }
        }

    }
    return
}

unload :: proc(track: ^Gps_Track) {
    if track.metadata.text != "" {
        delete(track.metadata.text, track.allocator)
    }
    if track.name != "" {
        delete(track.name, track.allocator)
    }
    if track.metadata.date_time.tz != nil{
        timezone.region_destroy(track.metadata.date_time.tz, track.allocator)
    }
    delete(track.points)
}

load_track :: proc(track: ^Gps_Track, elements: [dynamic]xml.Element, id: xml.Element_ID) {
    trk_elem := elements[id]

    for value in trk_elem.value {
        id := value.(xml.Element_ID) or_continue
        elem := elements[id]
        indent := elem.ident

        if strings.compare(indent, "name") == 0 {
            val := elem.value[0].(string) or_continue
            track.name = strings.clone_to_cstring(val)
            log.debug(value)
        } else if strings.compare(indent, "type") == 0 {
            val := elem.value[0].(string) or_continue

            found: bool
            for activity, i in activity_types {
                if strings.compare(activity, val) == 0 {
                    found = true
                    track.type = i
                    break
                }
            }
            if !found {
                track.type = .None
            }

            log.debug(track.type)
        } else if strings.compare(indent, "trkseg") == 0 {
            load_track_points(track, elements, elem.value[:])
        }
    }
}

load_track_points :: proc(track: ^Gps_Track, elements: [dynamic]xml.Element, point_ids: []xml.Value) {

    for point_id in point_ids {
        id := point_id.(xml.Element_ID) or_continue

        point := elements[id]
        log.debug(point)
    }

}

get_metadata :: proc(elements: [dynamic]xml.Element, id: xml.Element_ID) -> Metadata {

    metadata_elem := elements[id]
    metadata: Metadata
    for value in metadata_elem.value {
        id, ok := value.(xml.Element_ID)
        if !ok do continue

        element := elements[id]
        indent := element.ident

        if strings.compare(indent, "link") == 0 {
            text_id, ok := element.value[0].(xml.Element_ID)
            if !ok do continue
            text: string
            text, ok = elements[text_id].value[0].(string)
            if ok {
                metadata.text = strings.clone_to_cstring(text)
            }
        } else if strings.compare(indent, "time") == 0 {
            date_time_str, ok := element.value[0].(string)
            date_str, _, time_str := strings.partition(date_time_str, "T")
            metadata.date_time.date = parse_date(date_str) or_continue
            metadata.date_time.time = parse_time(time_str) or_continue

            tz := timezone.region_load("local") or_continue
            metadata.date_time = timezone.datetime_to_tz(metadata.date_time, tz) or_continue
        }
    }

    return metadata
}

parse_date :: proc(date_str: string) -> (date: datetime.Date, ok: bool) {
    date_str := date_str
    ok = true

    i := strings.index_rune(date_str, '-')
    date.year = auto_cast strconv.parse_int(date_str[:i]) or_return

    date_str = date_str[i+1:]
    i = strings.index_rune(date_str, '-')
    date.month = auto_cast strconv.parse_int(date_str[:i]) or_return

    date_str = date_str[i+1:]
    date.day = auto_cast strconv.parse_int(date_str) or_return

    return
}

parse_time :: proc(time_str: string) -> (time: datetime.Time, ok: bool) {
    time_str := strings.trim_right(time_str, "Z")
    ok = true

    i := strings.index_rune(time_str, ':')
    time.hour = auto_cast strconv.parse_int(time_str[:i]) or_return

    time_str = time_str[i+1:]
    i = strings.index_rune(time_str, ':')
    time.minute = auto_cast strconv.parse_int(time_str[:i]) or_return

    time_str = time_str[i+1:]
    time.second = auto_cast strconv.parse_int(time_str) or_return

    return
}

