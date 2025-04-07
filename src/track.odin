package jpx

// Loading and handling of a gps tracks / activities

import "base:runtime"
import "core:math"
import "core:time/datetime"
import "core:time"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:fmt"

import "core:encoding/xml"

SUPPORTED_FORMATS :: "gpx"

DateTime :: datetime.DateTime

Activity_Type :: enum {
    None,
    Running,
    Cycling,
}

ExtData :: enum {
    Speed,
    Distance,
    Heartrate,
    Cadence,
}

Extensions :: bit_set[ExtData]

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
    max_hr: u32,

    // all in meters and seconds
    total_distance: f32,
    avg_speed: f32,
    max_speed: f32,

    // Elevation
    elevation_gain: f32,
    max_elevation: f32,
    min_elevation: f32,

    allocator: runtime.Allocator
}

@(rodata)
activity_types := [Activity_Type]string {
    .None = "",
    .Running = "running",
    .Cycling = "cycling",
}

track_load_from_file :: proc(file: string, allocator := context.allocator) -> (track: Gps_Track, ok: bool) {
    return _track_load_from_file(file, allocator)
}

/********************
* Gpx Parsing
*********************/

track_load_from_gpx :: proc(file_data: []u8) -> (track: Gps_Track, ok: bool) {
    ok = true
    doc, err := xml.parse_bytes(file_data)
    if err != nil {
        log.errorf("Could not load gpx file")
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
                track.metadata = track_get_metadata(doc.elements, id)
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
    //if track.metadata.date_time != nil{
    //    tz := track.metadata.date_time.(DateTime).tz
    //    timezone.region_destroy(tz, track.allocator)
    //}
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
            for activity, i in activity_types {
                if strings.compare(activity, val) == 0 {
                    track.type = i
                    break
                }
            }

        } else if strings.compare(ident, "trkseg") == 0 {

            //---Track Points---
            total_hr: u32
            max_ele, min_ele: f32 = min(f32), max(f32)

            point_count := len(elem.value)
            loaded_ext: Extensions
            for val in elem.value {
                id := val.(xml.Element_ID)

                // load the point
                track_point: Track_Point
                track_point, loaded_ext = track_load_next_point(elements, id)

                // set datetime in the metadata if we have times from points
                if track.metadata.date_time == nil && track_point.time != nil {
                    track.metadata.date_time = track_point.time.(DateTime)
                    date_time_to_local(&track.metadata.date_time.(DateTime))
                }

                // set max and min for ele and hr
                if track_point.elevation > max_ele do max_ele = track_point.elevation
                if track_point.elevation < min_ele do min_ele = track_point.elevation
                if track_point.hr > track.max_hr do track.max_hr = track_point.hr
                total_hr += track_point.hr

                append(&track.points, track_point)
            }
            // elevation
            if min_ele < max(f32) {
                track.min_elevation = min_ele
            }
            if max_ele > min(f32) {
                track.max_elevation = max_ele
            }
            track.avg_hr = u32(math.round(f32(total_hr) / f32(point_count)))

            track_calculate_stats(track, loaded_ext)
        }
    }
}

track_load_next_point :: proc(
    elements: [dynamic]xml.Element,
    point_id: xml.Element_ID) -> (track_point: Track_Point, loaded_ext: Extensions) {

    point_elem := elements[point_id]
    ok: bool

    // parse the lat / lon for this point
    lat_attrib := point_elem.attribs[0]
    lon_attrib := point_elem.attribs[1]
    track_point.coord.x, ok = strconv.parse_f64(lon_attrib.val)
    if !ok do return
    track_point.coord.y, ok = strconv.parse_f64(lat_attrib.val)
    if !ok do return

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
            loaded_ext = track_load_extensions(&track_point, elements, elem)
        }
    }

    return
}

// uses the track points to calculate the remaining stats for the track
track_calculate_stats :: proc(track: ^Gps_Track, loaded_ext: Extensions) {

    total_speed := track.points[0].speed
    paused_time: f64
    point_count := len(track.points)

    // smoothed elevation and speed
    for i in 1..<len(track.points) {
        point := track.points[i]
        prev := track.points[i - 1]

        // exponential moving average
        alpha: f32 = 0.1 // smoothing
        ema_elev := alpha * point.elevation + (1 - alpha) * prev.elevation

        // calculate time diff for paused time and speed
        secs: f64
        if point.time != nil  {
            start, _ := time.datetime_to_time(prev.time.(DateTime))
            end, _ := time.datetime_to_time(point.time.(DateTime))
            time_diff := time.diff(start, end)
            assert(time_diff >= 0)
            secs = time.duration_seconds(time_diff)
            // if points have a delta greater than 30s it is counted as a pause
            if secs > 30.0 {
                paused_time += secs
            }
        } 

        // NOTE: we don't always get all the data so some values need to be calculated
        // so we use haversine for distance
        if .Distance not_in loaded_ext {
            // distance using haversine
            flat_dist := coord_distance(prev.coord, point.coord)
            elev_diff := ema_elev - prev.elevation
            dist := math.sqrt(elev_diff * elev_diff + flat_dist * flat_dist) // account for elevation diff
            track.points[i].distance = prev.distance + dist

            // NOTE: I don't think there is any way to do speed/time consistentlt without time
            // I thought points had a standard 1 second delta but it doesn't seem consistent
            if secs > 0.0 {
                track.points[i].speed = dist / f32(secs)
            }
        }
        // first make sure that there is a speed value
        ema_speed := alpha * track.points[i].speed + (1 - alpha) * prev.speed

        if ema_speed > track.max_speed do track.max_speed = ema_speed

        track.points[i].elevation = ema_elev
        track.points[i].speed = ema_speed
        diff := track.points[i].elevation - prev.elevation

        if diff > 0.0 do track.elevation_gain += diff
        total_speed += track.points[i].speed
    }
    track.avg_speed = total_speed / f32(point_count)

    // get distance and duration from the last/first points
    last := track.points[len(track.points) - 1]
    first := track.points[0]
    if last.distance > 0.0 {
        track.total_distance = last.distance
    }

    if first.time != nil && last.time != nil {
        first_time, _ := time.datetime_to_time(first.time.(DateTime))
        last_time, _ := time.datetime_to_time(last.time.(DateTime))
        duration := time.diff(first_time, last_time)

        // NOTE: removes paused time
        // could add total and elapsed seperate to track
        secs := time.duration_seconds(duration)
        secs -= paused_time
        track.duration = time.Duration(secs * f64(time.Second))
    }
}

track_load_extensions :: proc(track_point: ^Track_Point, 
    elements: [dynamic]xml.Element, elem: xml.Element) -> Extensions {

    loaded_extensions: Extensions
    for val in elem.value {
        id := val.(xml.Element_ID)
        ext_elem := elements[id]
        ident := ext_elem.ident

        // sometimes instead of extensions being under gpxdata:
        // they are values of a single gpxtpx element
        if strings.compare(ident, "gpxtpx:TrackPointExtension") == 0{
            for tpx_val in ext_elem.value {
                id := tpx_val.(xml.Element_ID)
                tpx_elem := elements[id]
                ident := tpx_elem.ident
                if strings.compare(ident, "gpxtpx:hr") == 0 {
                    val := tpx_elem.value[0].(string)
                    track_point.hr = auto_cast strconv.parse_uint(val) or_continue
                    loaded_extensions += { .Heartrate }
                } else if strings.compare(ident, "gpxtpx:cad") == 0 {
                    // cadence
                }
            }
        } else if strings.compare(ident, "gpxdata:hr") == 0 {
            val := ext_elem.value[0].(string)
            track_point.hr = auto_cast strconv.parse_uint(val) or_continue
            loaded_extensions += { .Heartrate }
        } else if strings.compare(ident, "gpxdata:distance") == 0 {
            val := ext_elem.value[0].(string)
            track_point.distance = auto_cast strconv.parse_f32(val) or_continue
            loaded_extensions += { .Distance }
        } else if strings.compare(ident, "gpxdata:speed") == 0 {
            val := ext_elem.value[0].(string)
            track_point.speed = auto_cast strconv.parse_f32(val) or_continue
            loaded_extensions += { .Speed }
        }
    }

    return loaded_extensions
}

track_get_metadata :: proc(elements: [dynamic]xml.Element, id: xml.Element_ID) -> Metadata {

    metadata_elem := elements[id]
    metadata: Metadata
    for value in metadata_elem.value {
        id := value.(xml.Element_ID)

        element := elements[id]
        ident := element.ident

        if strings.compare(ident, "link") == 0 {
            text_id := element.value[0].(xml.Element_ID)
            text: string
            text = elements[text_id].value[0].(string)
            metadata.text = strings.clone_to_cstring(text)

        } else if strings.compare(ident, "time") == 0 {
            date_time_str := element.value[0].(string)
            metadata.date_time = parse_date_time(date_time_str) or_continue
            date_time_to_local(&metadata.date_time.(DateTime))
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
