package jpx

// Loading and handling of a gps tracks / activities

import "base:runtime"
import "core:path/filepath"
import "core:mem"
import "core:math"
import "core:time/datetime"
import "core:time/timezone"
import "core:time"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:fmt"

import "core:encoding/xml"

DateTime :: datetime.DateTime

SUPPORTED_FORMATS :: "gpx"

Activity_Type :: enum {
    None,
    Running,
    Cycling,
}

// Not all the values in this struct are guaranteed
// to be loaded as track points have variable data
Track_Point :: struct {
    coord: Coord,
    time: Maybe(DateTime),
    elevation: f32,

    // Extensions
    distance: f32, // meter
    hr: u32,
    speed: f32, // m/s
}

Metadata :: struct {
    text: cstring,
    date_time: Maybe(DateTime),
}

Gps_Track :: struct {
    metadata: Metadata,
    name: cstring,
    type: Activity_Type,
    points: [dynamic]Track_Point,

    duration: time.Duration,

    avg_hr: u32,

    // all in meters and seconds
    total_distance: f32,
    avg_speed: f32,
    max_speed: f32,

    // Elevation
    elevation_gain: i32,
    max_elevation: i32,
    min_elevation: i32,

    allocator: runtime.Allocator
}

@(rodata)
activity_types := [Activity_Type]string {
    .None = "",
    .Running = "running",
    .Cycling = "cycling",
}

track_load_from_file :: proc(file: string, allocator := context.allocator) -> (track: Gps_Track, ok: bool) {
    context.allocator = allocator

    ext := filepath.ext(file)
    if strings.compare(ext, ".gpx") == 0 {
        track, ok = track_load_from_gpx(file)
    } else {
        log.errorf("Could not load %s\nSupported formats: %s", file, SUPPORTED_FORMATS)
        track = {}
        ok = false
    }

    return
}

/********************
* Gpx Parsing
*********************/

track_load_from_gpx :: proc(file: string) -> (track: Gps_Track, ok: bool) {
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
            ident := doc.elements[id].ident
            if strings.compare(ident, "metadata") == 0 {
                track.metadata = _get_metadata(doc.elements, id)
            } else if strings.compare(ident, "trk") == 0 {
                track_load_data(&track, doc.elements, id)
            } else {
                log.error("Invalid gpx format")
                return {}, false
            }
        }
        }

    }

    return
}

track_unload :: proc(track: ^Gps_Track) {
    if track.metadata.text != "" {
        delete(track.metadata.text, track.allocator)
    }
    if track.name != "" {
        delete(track.name, track.allocator)
    }
    if track.metadata.date_time != nil{
        tz := track.metadata.date_time.(DateTime).tz
        timezone.region_destroy(tz, track.allocator)
    }
    delete(track.points)
}

// TODO: could add errors and abort parsing for failed type asserts
// same thing could be done for failed number parsing, 

track_load_data :: proc(track: ^Gps_Track, elements: [dynamic]xml.Element, id: xml.Element_ID) {
    trk_elem := elements[id]

    for value in trk_elem.value {
        id := value.(xml.Element_ID)
        elem := elements[id]
        ident := elem.ident

        if strings.compare(ident, "name") == 0 {
            val := elem.value[0].(string)
            track.name = strings.clone_to_cstring(val)
        } else if strings.compare(ident, "type") == 0 {
            val := elem.value[0].(string)
            found: bool
            for activity, i in activity_types {
                if strings.compare(activity, val) == 0 {
                    track.type = i
                    break
                }
            }

        } else if strings.compare(ident, "trkseg") == 0 {
            //---Track Points---

            total_hr: u32
            total_speed: f32
            max_ele, min_ele: i32 = -100, max(i32)

            point_count := len(elem.value)
            prev_point: Track_Point
            for val in elem.value {
                id := val.(xml.Element_ID)

                // load the point
                track_point := track_load_next_point(track, elements, id, prev_point)

                // set datetime in the metadata if we have times from points
                if track.metadata.date_time == nil && track_point.time != nil {
                    track.metadata.date_time = track_point.time.(DateTime)
                    tz := timezone.region_load("local") or_continue
                    track.metadata.date_time = timezone.datetime_to_tz(track.metadata.date_time.(DateTime), tz) or_continue
                }
                // convert point timezone not sure if this will ever be needed
                if track_point.time != nil {
                    track_point.time = timezone.datetime_to_tz(track_point.time.(DateTime),
                        track.metadata.date_time.(DateTime).tz) or_continue
                }

                if i32(track_point.elevation) > max_ele do max_ele = i32(track_point.elevation)
                if i32(track_point.elevation) < min_ele do min_ele = i32(track_point.elevation)
                total_speed += track_point.speed
                total_hr += track_point.hr

                append(&track.points, track_point)
                prev_point = track_point
            }

            if min_ele < max(i32) {
                track.min_elevation = min_ele
            }
            if max_ele > -100 {
                track.max_elevation = max_ele
            }

            // averages
            track.avg_speed = total_speed / f32(point_count)
            track.avg_hr = total_hr / u32(point_count)

            // get distance and duration from the last/first points
            last := track.points[len(track.points) - 1]
            if last.distance > 0.0 {
                track.total_distance = last.distance
            }
        }
    }
}

track_load_next_point :: proc(track: ^Gps_Track, elements: [dynamic]xml.Element,
    point_id: xml.Element_ID, prev_point: Track_Point) -> (track_point: Track_Point) {

    point_elem := elements[point_id]

    // parse the lat / lon for this point
    lat_attrib := point_elem.attribs[0]
    lon_attrib := point_elem.attribs[1]

    ok: bool
    track_point.coord.x, ok = strconv.parse_f64(lon_attrib.val)
    if !ok do return
    track_point.coord.y, ok = strconv.parse_f64(lat_attrib.val)
    if !ok do return


    found_speed, found_distance: bool
    prev_point := prev_point
    // parse all the extra data from point elem
    for val in point_elem.value {

        child_id := val.(xml.Element_ID)
        elem := elements[child_id]
        ident := elem.ident

        if strings.compare(ident, "ele") == 0 {
            value := elem.value[0].(string)
            track_point.elevation = auto_cast strconv.parse_f64(value) or_continue
        } else if strings.compare(ident, "time") == 0 {
            value := elem.value[0].(string)
            track_point.time = parse_date_time(value) or_continue
        } else if strings.compare(ident, "extensions") == 0 {
            for val in elem.value {
                id := val.(xml.Element_ID)
                ext_elem := elements[id]
                ident := ext_elem.ident
                ident = strings.trim_prefix(ident, "gpxdata:")

                if strings.compare(ident, "hr") == 0 {
                    val := ext_elem.value[0].(string)
                    track_point.hr = auto_cast strconv.parse_uint(val) or_continue
                } else if strings.compare(ident, "distance") == 0 {
                    val := ext_elem.value[0].(string)
                    track_point.distance = auto_cast strconv.parse_f32(val) or_continue
                } else if strings.compare(ident, "speed") == 0 {
                    val := ext_elem.value[0].(string)
                    track_point.speed = auto_cast strconv.parse_f32(val) or_continue
                }
            }
        }
    }

    // NOTE:
    // we don't always get all the data so sometimes values need to be calculated
    // I'm not sure of all best ways to calculate these values. 
    // there are cases such as no time data where it not possible to reliably calculate speed.
    // points have a 1 second difference about 98% of the time so an estimate of speed could be done.


    if prev_point == {} do prev_point = track_point
    diff := track_point.elevation - prev_point.elevation
    // The elevation gain seems larger than
    // what other software calculates maybe some form of algorithm to minimize inacuracies?
    if diff > 0 {
        track.elevation_gain += i32(diff)
    }

    return
}

_get_metadata :: proc(elements: [dynamic]xml.Element, id: xml.Element_ID) -> Metadata {

    metadata_elem := elements[id]
    metadata: Metadata
    for value in metadata_elem.value {
        id, ok := value.(xml.Element_ID)
        if !ok do continue

        element := elements[id]
        ident := element.ident

        if strings.compare(ident, "link") == 0 {
            text_id, ok := element.value[0].(xml.Element_ID)
            if !ok do continue
            text: string
            text, ok = elements[text_id].value[0].(string)
            if ok {
                metadata.text = strings.clone_to_cstring(text)
            }
        } else if strings.compare(ident, "time") == 0 {
            date_time_str, ok := element.value[0].(string)
            metadata.date_time = parse_date_time(date_time_str) or_continue

            tz := timezone.region_load("local") or_continue
            metadata.date_time = timezone.datetime_to_tz(metadata.date_time.(DateTime), tz) or_continue
        }
    }

    return metadata
}

parse_date_time :: proc(date_time_str: string) -> (date_time: DateTime, ok: bool) {
    date_str, _, time_str := strings.partition(date_time_str, "T")
    time_str = strings.trim_right(time_str, "Z")
    ok = true

    // Date
    i := strings.index_rune(date_str, '-')
    date_time.year = auto_cast strconv.parse_int(date_str[:i]) or_return
    date_str = date_str[i+1:]
    i = strings.index_rune(date_str, '-')
    date_time.month = auto_cast strconv.parse_int(date_str[:i]) or_return
    date_str = date_str[i+1:]
    date_time.day = auto_cast strconv.parse_int(date_str) or_return

    // Time
    i = strings.index_rune(time_str, ':')
    date_time.hour = auto_cast strconv.parse_int(time_str[:i]) or_return

    time_str = time_str[i+1:]
    i = strings.index_rune(time_str, ':')
    date_time.minute = auto_cast strconv.parse_int(time_str[:i]) or_return

    time_str = time_str[i+1:]
    date_time.second = auto_cast strconv.parse_int(time_str) or_return

    return
}
