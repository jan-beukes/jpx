package jpx

import "core:math"
import "core:time"
import "core:log"
import "core:math/ease"
import "core:time/datetime"
import "vendor:raylib/rlgl"
import rl "vendor:raylib"

BORDER_THICK :: 1.2
PANEL_BORDER_THICK :: 3.0
PADDING_FACTOR :: 0.15
FADE_AMMOUNT :: 0.9

PANEL_ANIM_TIME :: 0.3
PANEL_HANDLE_SCALE :: 0.3

TOGGLE_INNER_SCALE :: 0.8

STATS_PANEL_MAX_SCALE :: 0.5
PLOT_PANEL_MAX_SCALE :: 0.7

DARK_BLUE :: rl.Color{0x0d, 0x2b, 0x45, 0xff}
BLUE :: rl.Color{0x20, 0x3c, 0x56, 0xff}
DARK_PURPLE :: rl.Color{0x54, 0x4e, 0x68, 0xff}
PURPLE :: rl.Color{0x8d, 0x69, 0x7a, 0xff}
WHITE :: rl.Color{0xff, 0xec, 0xd6, 0xff}
ORANGE :: rl.Color{0xff, 0xaa, 0x5e, 0xff}
BROWN :: rl.Color{0xd0, 0x81, 0x59, 0xff}
PEACH :: rl.Color{0xff, 0xd4, 0xa3, 0xff}

Gui_Colors :: struct {
    bg: rl.Color,
    bg2: rl.Color,
    fg: rl.Color,
    fg2: rl.Color,
    border: rl.Color,
    hover2: rl.Color,
    hover: rl.Color,
    select: rl.Color,
}

Panel_Location :: enum {
    Left,
    Top,
    Right,
    Bottom,
}

Gui_Panel :: struct {
    rect: rl.Rectangle,
    is_open: bool,
    anim_frame: i32,
    location: Panel_Location,
}

Months :: enum {
    January,
    February,
    March,
    April,
    May,
    June,
    July,
    August,
    September,
    October,
    November,
    December,
}

@rodata
month_names := [Months]cstring {
    .January = "January",
    .February = "February",
    .March = "March",
    .April = "April",
    .May = "May",
    .June = "June",
    .July = "July",
    .August = "August",
    .September = "September",
    .October = "October",
    .November = "November",
    .December = "December",
}


g_font: rl.Font
gui_mouse_cursor: rl.MouseCursor

draw_text :: proc(text: cstring, pos: rl.Vector2, size: f32, color: rl.Color) {
    rl.DrawTextEx(g_font, text, pos, size, 0, color)
}

measure_text :: proc(text: cstring, font_size: f32) -> f32 {
    return rl.MeasureTextEx(g_font, text, font_size, 0).x
}

// this just resets gui cursor stuff
gui_begin :: proc() {
    gui_mouse_cursor = .DEFAULT
}

//---Panel stuff---

// Handles the plot panel
gui_panel_plots :: proc(panel: ^Gui_Panel, track: Gps_Track, ui_focused: ^bool) {
    // this makes the forced auto close nicer so im just gonna keep that state in the function
    @static was_force_closed: bool

    // Panel prelude
    rect, handle_rect := get_panel_rects(panel^)
    mouse_pos := rl.GetMousePosition()

    if panel.is_open && rl.CheckCollisionPointRec(mouse_pos, rect) {
        ui_focused^ = true
    }

    if rl.CheckCollisionPointRec(mouse_pos, handle_rect) {
        gui_mouse_cursor = .POINTING_HAND
        ui_focused^ = true
        if rl.IsMouseButtonPressed(.LEFT) {
            panel.is_open = !panel.is_open
            panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        }
    }
    window_height := rl.GetScreenHeight()
    // auto close the panel when it's taking up too much space
    over_max_scale := rect.height > f32(window_height) * PLOT_PANEL_MAX_SCALE 
    if panel.is_open && over_max_scale {
        panel.is_open = !panel.is_open
        panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        was_force_closed = true
    } else if was_force_closed && !over_max_scale {
        panel.is_open = !panel.is_open
        panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        was_force_closed = false
    }

    // draw the rect and handle
    rl.DrawRectangleRec(rect, rl.Fade(DARK_BLUE, FADE_AMMOUNT))
    rl.DrawRectangleLinesEx(rect, PANEL_BORDER_THICK, BLUE)
    draw_panel_handle(handle_rect, panel^)

    // exit early
    if !panel.is_open && panel.anim_frame == 0 {
        return
    } else if panel.anim_frame > 0 {
        panel.anim_frame -= 1
    }

    /*********
    * PLOTS
    **********/

    // the plot toggle state
    @static hr_plot_active: bool
    @static speed_plot_active: bool

    padding := rect.height * 0.03
    font_size := rect.height * 0.06

    // leaves space for values and toggles
    axis_rect_y := rect.y + 2 * font_size + 3 * padding

    // Draw the axes
    axis_rect := rl.Rectangle {
        x = rect.x + padding,
        y = axis_rect_y,
        width = rect.width - 2 * padding,
        height = rect.height - (axis_rect_y - rect.y) - padding
    }

    AXIS_STEPS :: 6.0
    axis_font_size := font_size * 0.9

    font_spacing := 2.5 * axis_font_size
    inner_rect := rl.Rectangle {
        x = axis_rect.x + font_spacing,
        y = axis_rect.y,
        width = axis_rect.width - font_spacing,
        height = axis_rect.height - 0.5*font_spacing,
    }

    // draw the axis track_load_extensions
    // elevation on the y axis and distance on the x axis
    axis_delta_y := axis_rect.height / AXIS_STEPS
    axis_delta_x := axis_rect.width / AXIS_STEPS
    axis_elev_delta := (track.max_elevation - track.min_elevation) / AXIS_STEPS
    axis_dist_delta := track.total_distance / AXIS_STEPS
    for i in 0..<AXIS_STEPS {
        // elev markers are centered on the y value
        ele_y := axis_rect.y + f32(i) * axis_delta_y - axis_font_size * 0.5
        elev := track.max_elevation - f32(i) * axis_elev_delta
        dist_x := inner_rect.x + f32(i) * axis_delta_x
        dist := f32(i) * axis_dist_delta

        draw_text(rl.TextFormat("%.0fm", elev), {axis_rect.x, ele_y}, axis_font_size, WHITE)
        draw_text(rl.TextFormat("%.1fkm", dist * 0.001), {dist_x, axis_rect.y + inner_rect.height},
            axis_font_size, WHITE)
    }

    //---Drawing Plots---
    PLOT_LINE_THICK :: 2.5
    MAX_PLOT_POINTS :: 4096
    rlgl.SetLineWidth(PLOT_LINE_THICK)

    has_time := track.duration != 0
    has_hr := track.avg_hr != 0
    has_speed := track.avg_speed != 0

    points_buf: [MAX_PLOT_POINTS]rl.Vector2

    draw_plot :: proc(rect: rl.Rectangle, points_buf: []rl.Vector2, track: Gps_Track, plot_data: ExtData) {
        points := track.points[:]
        point_count: int = min(len(points), min(int(rect.width), MAX_PLOT_POINTS))
        point_step := f32(len(points)) / f32(point_count)
        dx := rect.width / f32(point_count)

        count: int
        point_idx: f32 = 0.0
        for i in 0..<point_count {
            assert(int(point_idx) < len(points))
            point := points[int(point_idx)]

            x := rect.x + f32(i) * dx
            scale: f32
            switch plot_data {
            case .Heartrate:
                scale = f32(point.hr) / f32(track.max_hr)
            case .Speed:
                scale = point.speed / track.max_speed
            case .Cadence: unimplemented("Cadence plot")
            case .Distance: unreachable()
            }
            y := rect.y + rect.height - scale * rect.height

            points_buf[count] = {x, y}
            count += 1
            point_idx += point_step
        }
        color: rl.Color
        switch plot_data {
        case .Heartrate: color = rl.RED
        case .Speed: color = rl.BLUE
        case .Cadence: unimplemented("Cadence plot")
        case .Distance: unimplemented()
        }
        rl.DrawLineStrip(raw_data(points_buf[:count]), auto_cast count, color)
    }

    //---Elevation---
    {
        point_count: int = min(len(track.points), min(int(inner_rect.width), 4096))
        point_step := f32(len(track.points)) / f32(point_count)
        dx := inner_rect.width / f32(point_count)

        y0 := inner_rect.y + inner_rect.height
        prev_point := track.points[0]
        // we need this to be a float since a non integer point step needs to be accumulated
        point_idx: f32 = 0.0
        for i in 1..<point_count {
            point_idx += point_step
            assert(int(point_idx) < len(track.points))
            point := track.points[int(point_idx)]

            px := inner_rect.x + f32(i - 1) * dx
            x := inner_rect.x + f32(i) * dx
            elev_scale := (point.elevation - track.min_elevation) /
                (track.max_elevation - track.min_elevation)
            prev_elev_scale := (prev_point.elevation - track.min_elevation) / 
                (track.max_elevation - track.min_elevation)
            py := inner_rect.y + inner_rect.height - prev_elev_scale * inner_rect.height
            y := inner_rect.y + inner_rect.height - elev_scale * inner_rect.height

            // unlike other plots we render triangles to fill out a polygon
            rl.DrawTriangle({px, y0}, {x, y}, {px, py}, rl.GRAY)
            rl.DrawTriangle({px, y0}, {x, y0}, {x, y}, rl.GRAY)

            prev_point = point
        }
    }

    // next plots are not guaranteed
    plot_count := 0

    //---Heart Rate---
    if has_hr {
        plot_count += 1
        if hr_plot_active {
            draw_plot(inner_rect, points_buf[:], track, .Heartrate)
        }
    }

    //---Speed---
    if has_speed {
        plot_count += 1
        if speed_plot_active {
            draw_plot(inner_rect, points_buf[:], track, .Speed)
        }
    }

    rlgl.DrawRenderBatchActive()
    rlgl.SetLineWidth(1.0)

    //---Values and toggles---
    // values are rendered depending on the selected point in the track, if nothing is selected
    // default values are shown in the value text

    distance_text: cstring = "Distance"
    gain_text: cstring = "Gain"
    time_text: cstring = "Time"

    // For centering these values I think just using the known top text is good enough?
    value_count := 2
    top_total_text_width := measure_text(distance_text, font_size) + measure_text(gain_text, font_size)
    if has_time {
        value_count += 1
        top_total_text_width += measure_text(time_text, font_size)
    }

    toggle_radius := font_size * 0.7
    value_padding := padding * 2.0
    toggle_padding := 4  * toggle_radius

    total_values_width := top_total_text_width + f32(plot_count) * (toggle_radius) + f32(plot_count - 1) *
        toggle_padding + f32(value_count + plot_count - 1) * value_padding

    cursor := rl.Vector2{axis_rect.x + (axis_rect.width - total_values_width) * 0.5,
        axis_rect.y - font_size - padding}

    text: cstring
    text_width: f32
    pos: rl.Vector2
    mid_x: f32

    // Distance
    text = rl.TextFormat("%.1fkm", track.total_distance * 0.001)
    text_width = measure_text(text, font_size)
    draw_text(text, cursor, font_size, WHITE)

    mid_x = cursor.x + text_width * 0.5
    text_width = measure_text(distance_text, font_size)
    pos = rl.Vector2{mid_x - text_width * 0.5, cursor.y - 1.5*font_size}
    draw_text(distance_text, pos, font_size, PEACH)

    // Elevation
    cursor.x += text_width + value_padding
    text = rl.TextFormat("%.0fm", track.elevation_gain)
    text_width = measure_text(text, font_size)
    draw_text(text, cursor, font_size, WHITE)

    mid_x = cursor.x + text_width * 0.5
    text_width = measure_text(gain_text, font_size)
    pos = rl.Vector2{mid_x - text_width * 0.5, cursor.y - 1.5*font_size}
    draw_text(gain_text, pos, font_size, PEACH)

    // Time
    if has_time {
        cursor.x += text_width + value_padding
        hours, mins, _ := time.clock_from_duration(track.duration)
        text = rl.TextFormat("%dh %dm", hours, mins)
        text_width = measure_text(text, font_size)
        draw_text(text, cursor, font_size, WHITE)

        mid_x = cursor.x + text_width * 0.5
        text_width = measure_text(time_text, font_size)
        pos = rl.Vector2{mid_x - text_width * 0.5, cursor.y - 1.5*font_size}
        draw_text(time_text, pos, font_size, PEACH)
    }
    cursor.x += text_width + toggle_radius + value_padding

    // Heartrate
    if has_hr {
        text = rl.TextFormat("%dbpm", track.avg_hr)
        text_width = measure_text(text, font_size)
        draw_text(text, cursor, font_size, WHITE)

        mid_x = cursor.x + text_width * 0.5
        pos = rl.Vector2{mid_x, cursor.y - font_size}

        if gui_toggle(pos, toggle_radius, rl.RED, &hr_plot_active) {
            gui_mouse_cursor = .POINTING_HAND
        }
    }

    // Speed
    if has_speed {
        width := has_hr ? toggle_padding : text_width
        cursor.x += width + value_padding

        // calc units based on type
        if track.type == .Running {
            mpk := (1.0 / track.avg_speed) * (1000.0 / 60.0)
            min := i32(mpk)
            sec := i32(60 * (mpk - math.trunc(mpk)))
            text = rl.TextFormat("%d'%2d\"", min, sec)
        } else {
            kph := (track.avg_speed * 3600) / 1000.0
            text = rl.TextFormat("%.1fkph", kph)
        }
        text_width = measure_text(text, font_size)
        draw_text(text, cursor, font_size, WHITE)

        // toggle
        mid_x = cursor.x + text_width * 0.5
        pos = rl.Vector2{mid_x, cursor.y - font_size}
        if gui_toggle(pos, toggle_radius, rl.BLUE, &speed_plot_active) {
            gui_mouse_cursor = .POINTING_HAND
        }
    }



    // Axis lines drawn after the plot lines
    rl.DrawLineEx({inner_rect.x, inner_rect.y}, {inner_rect.x, inner_rect.y +
        inner_rect.height}, 2.0, BLUE)
    rl.DrawLineEx({inner_rect.x, inner_rect.y + inner_rect.height}, 
        {inner_rect.x + inner_rect.width, inner_rect.y + inner_rect.height}, 2.0, BLUE)

}

// Handles the stats panel
gui_panel_stats :: proc(panel: ^Gui_Panel, track: Gps_Track, ui_focused: ^bool) {
    // this is makes the forces auto close nicer so im just gonna keep that state in the function
    @static was_force_closed: bool

    // Panel prelude
    rect, handle_rect := get_panel_rects(panel^)
    mouse_pos := rl.GetMousePosition()

    if panel.is_open && rl.CheckCollisionPointRec(mouse_pos, rect) {
        ui_focused^ = true
    }

    if rl.CheckCollisionPointRec(mouse_pos, handle_rect) {
        gui_mouse_cursor = .POINTING_HAND
        ui_focused^ = true
        if rl.IsMouseButtonPressed(.LEFT) {
            panel.is_open = !panel.is_open
            panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        }
    }
    window_width := rl.GetScreenWidth()
    // auto close the panel when it's taking up too much space
    over_max_scale := rect.width > f32(window_width) * STATS_PANEL_MAX_SCALE 
    if panel.is_open && over_max_scale {
        panel.is_open = !panel.is_open
        panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        was_force_closed = true
    } else if was_force_closed && !over_max_scale {
        panel.is_open = !panel.is_open
        panel.anim_frame = i32(PANEL_ANIM_TIME * f32(rl.GetFPS()))
        was_force_closed = false
    }

    // draw the rect and handle
    rl.DrawRectangleRec(rect, rl.Fade(DARK_BLUE, FADE_AMMOUNT))
    border_rect := rect
    border_rect.height += PANEL_BORDER_THICK
    rl.DrawRectangleLinesEx(border_rect, PANEL_BORDER_THICK, BLUE)
    draw_panel_handle(handle_rect, panel^)

    if !panel.is_open && panel.anim_frame == 0 {
        return
    } else if panel.anim_frame > 0 {
        panel.anim_frame -= 1
    }

    /********
    * STATS
    *********/
    padding: f32 = rect.width * 0.04
    font_size: f32 = PANEL_SIZE * PADDING_FACTOR * 0.5
    cursor := rl.Vector2{rect.x + padding, rect.y + padding}
    text: cstring

    // we use scissor mode to cut things draw outside the panel
    rl.BeginScissorMode(i32(rect.x), i32(rect.y), i32(rect.width - PANEL_BORDER_THICK),
        i32(rect.height - PANEL_BORDER_THICK))

    // Track name
    if track.name != "" {
        text = rl.TextFormat("%s", track.name)
        draw_text(text, cursor, font_size, WHITE)
    }

    // start time
    date, ok := track.metadata.date_time.(datetime.DateTime)
    if ok {
        cursor.y += font_size + padding
        text = rl.TextFormat("%d %s %d %2d:%2d:%2d", date.day, month_names[Months(date.month - 1)], date.year, date.hour,
            date.minute, date.second)
        draw_text(text, cursor, font_size, WHITE)
    }

    // duration
    if track.duration != 0 {
        cursor.y += 2 * font_size + padding
        hours, mins, _ := time.clock_from_duration(track.duration)
        text = rl.TextFormat("Elapsed time: %dh %2dm", hours, mins)
        draw_text(text, cursor, font_size, WHITE)
    }

    // distance (should always be available)
    cursor.y += font_size + padding
    text = rl.TextFormat("Distance: %.2fkm", track.total_distance / 1000.0)
    draw_text(text, cursor, font_size, WHITE)

    // Elevation
    cursor.y += font_size + padding
    text = rl.TextFormat("Elev gain: %.0fm", track.elevation_gain)
    draw_text(text, cursor, font_size, WHITE)

    cursor.y += font_size + padding
    text = rl.TextFormat("Max elev: %.0fm", track.max_elevation)
    draw_text(text, cursor, font_size, WHITE)

    if track.avg_hr > 0 {
        cursor.y += font_size + padding
        text = rl.TextFormat("Avg hr: %d", track.avg_hr)
        draw_text(text, cursor, font_size, WHITE)

        cursor.y += font_size + padding
        text = rl.TextFormat("Max hr: %d", track.max_hr)
        draw_text(text, cursor, font_size, WHITE)
    }

    if track.avg_speed > 0 {
        cursor.y += font_size + padding
        if track.type == .Running {
            mpk := (1.0 / track.avg_speed) * (1000.0 / 60.0)
            min := i32(mpk)
            sec := i32(60 * (mpk - math.trunc(mpk)))
            text = rl.TextFormat("Avg pace: %d:%2d /km", min, sec)
        } else {
            kph := (track.avg_speed * 3600) / 1000.0
            text = rl.TextFormat("Avg speed: %.1fkph", kph)
        }
        draw_text(text, cursor, font_size, WHITE)
    }

    rl.EndScissorMode()
}

draw_panel_handle :: proc(handle_rect: rl.Rectangle, panel: Gui_Panel) {
    border_rect := handle_rect
    rl.DrawRectangleRec(handle_rect, DARK_BLUE)
    center := rl.Vector2 {handle_rect.x + (handle_rect.width*0.5), handle_rect.y + (handle_rect.height*0.5)}
    size := min(handle_rect.width, handle_rect.height) * 0.3
    switch panel.location {
    case .Left:
        rotation: f32 = panel.is_open ? 180.0 : 0.0
        rl.DrawPoly(center, 3, size, rotation, PEACH)
        // adjust for nicer fitting borders
        border_rect.x -= PANEL_BORDER_THICK
        border_rect.width += PANEL_BORDER_THICK
    case .Top:
        rotation: f32 = panel.is_open ? -90.0 : 90.0
        rl.DrawPoly(center, 3, size, rotation, PEACH)
        border_rect.y -= PANEL_BORDER_THICK
        border_rect.height += PANEL_BORDER_THICK
    case .Right:
        rotation: f32 = panel.is_open ? 0.0 : 180.0
        rl.DrawPoly(center, 3, size, rotation, PEACH)
        border_rect.width += PANEL_BORDER_THICK
    case .Bottom:
        rotation: f32 = panel.is_open ? 90.0 : -90.0
        rl.DrawPoly(center, 3, size, rotation, PEACH)
        border_rect.height += PANEL_BORDER_THICK
    }
    rl.DrawRectangleLinesEx(border_rect, PANEL_BORDER_THICK, BLUE)
}

// This function uses the panel's state to calculate the
// transformed rect for the panel and it's handle
// returns panel_rect, handle_rect
get_panel_rects :: proc(panel: Gui_Panel) -> (rl.Rectangle, rl.Rectangle) {
    window_width, window_height := rl.GetScreenWidth(), rl.GetScreenHeight()

    rect := panel.rect
    // offset the rect
    if panel.location == .Bottom {
        rect.y = f32(window_height) - rect.height
    } else if panel.location == .Right {
        rect.x = f32(window_width) - rect.width
    }


    // get current t for interpolation between open and close
    frame_count := f32(rl.GetFPS()) * PANEL_ANIM_TIME
    t: f32
    if panel.is_open {
        t = ease.cubic_in(1.0 - f32(panel.anim_frame) / f32(frame_count))
    } else {
        t = ease.cubic_out(1.0 - f32(panel.anim_frame) / f32(frame_count))
    }

    // calculate rect and handle rect from animation frame based on location
    draw_rect := rect
    handle_rect: rl.Rectangle
    switch panel.location {
    case .Top:
        // interpolate between open and closed
        dest_y := panel.is_open ? rect.y : rect.y - rect.height
        start_y := panel.is_open ? rect.y - rect.height : rect.y
        draw_rect.y = math.lerp(start_y, dest_y, t)

        // calculate handle rect
        handle_rect.width = rect.height * PANEL_HANDLE_SCALE
        handle_rect.height = handle_rect.width * 0.25
        handle_rect.x = rect.x + (rect.width - handle_rect.width) * 0.5
        handle_rect.y = draw_rect.y + rect.height
    case .Left:
        dest_x := panel.is_open ? rect.x : rect.x - rect.width
        start_x := panel.is_open ? rect.x - rect.width : rect.x
        draw_rect.x = math.lerp(start_x, dest_x, t)

        handle_rect.height = rect.width * PANEL_HANDLE_SCALE
        handle_rect.width = handle_rect.height * 0.25
        handle_rect.y = rect.y + (rect.height - handle_rect.height) * 0.5
        handle_rect.x = draw_rect.x + rect.width
    case .Right:
        dest_x := panel.is_open ? rect.x : rect.x + rect.width
        start_x := panel.is_open ? rect.x + rect.width : rect.x
        draw_rect.x = math.lerp(start_x, dest_x, t)

        handle_rect.height = rect.width * PANEL_HANDLE_SCALE
        handle_rect.width = handle_rect.height * 0.25
        handle_rect.y = rect.y + (rect.height - handle_rect.height) * 0.5
        handle_rect.x = draw_rect.x - handle_rect.width
    case .Bottom:
        dest_y := panel.is_open ? rect.y : rect.y + rect.height
        start_y := panel.is_open ? rect.y + rect.height : rect.y
        draw_rect.y = math.lerp(start_y, dest_y, t)

        handle_rect.width = rect.height * PANEL_HANDLE_SCALE
        handle_rect.height = handle_rect.width * 0.25
        handle_rect.x = rect.x + (rect.width - handle_rect.width) * 0.5
        handle_rect.y = draw_rect.y - handle_rect.height
    }

    return draw_rect, handle_rect
}

// toggle button return true on hover
gui_toggle :: proc(pos: rl.Vector2, radius: f32, color: rl.Color, toggled: ^bool) -> bool {
    mouse_pos := rl.GetMousePosition()
    hover := false
    if rl.CheckCollisionPointCircle(mouse_pos, pos, radius) {
        hover = true
        if rl.IsMouseButtonPressed(.LEFT) {
            if toggled != nil do toggled^ = !toggled^
        }
    }

    rl.DrawRing(pos, radius * TOGGLE_INNER_SCALE, radius, 0, 360, 1, color)
    if toggled^ {
        rl.DrawCircleV(pos, radius, color)
    }

    return hover
}

gui_button :: proc(rect: rl.Rectangle, text: cstring, ui_focused: ^bool) -> bool {
    mouse_pos := rl.GetMousePosition()

    hover: bool
    pressed: bool
    if rl.CheckCollisionPointRec(mouse_pos, rect) {
        ui_focused^ = true
        hover = true
        gui_mouse_cursor = .POINTING_HAND
        if rl.IsMouseButtonPressed(.LEFT) {
            pressed = true
        }
    }

    // Base rect
    padding := rect.height * PADDING_FACTOR
    font_size := rect.height - 2 * padding
    if hover {
        rl.DrawRectangleRec(rect, BLUE)
    } else {
        rl.DrawRectangleRec(rect, DARK_BLUE)
    }
    draw_text(text, {rect.x + padding, rect.y + padding}, font_size, WHITE)
    rl.DrawRectangleLinesEx(rect, BORDER_THICK, WHITE)

    return pressed
}

// copyright info
gui_copyright :: proc(rect: rl.Rectangle, style: Layer_Style, ui_focused: ^bool) {
    @(static) expanded: bool

    icon_hover := false
    mouse_pos := rl.GetMousePosition()
    if rl.CheckCollisionPointRec(mouse_pos, rect) {
        icon_hover = true
        ui_focused^ = true
        if rl.IsMouseButtonPressed(.LEFT) {
            expanded = !expanded
        }
        gui_mouse_cursor = .POINTING_HAND
    }

    // attribution links
    if expanded {
        font_size := rect.height * 0.8
        width := style == .Osm ? rect.width * 6.5 : rect.width * 10.5 // Osm will take less

        expanded_rect := rl.Rectangle {
            x = rect.x - width + BORDER_THICK,
            y = rect.y,
            width = width,
            height = rect.height,
        }
        if rl.CheckCollisionPointRec(mouse_pos, expanded_rect) do ui_focused^ = true

        rl.DrawRectangleRec(expanded_rect, WHITE)
        rl.DrawRectangleLinesEx(expanded_rect, BORDER_THICK, DARK_BLUE)

        // OSM
        text: cstring = "(c) OpenStreetMap"
        text_width := f32(rl.MeasureText(text, i32(font_size)))
        text_rect := rl.Rectangle {
            x = expanded_rect.x + BORDER_THICK,
            y = expanded_rect.y + BORDER_THICK,
            width = text_width * 0.8,
            height = rect.height,
        }
        text_hover := false
        if rl.CheckCollisionPointRec(mouse_pos, text_rect) {
            text_hover = true
            gui_mouse_cursor = .POINTING_HAND
            if rl.IsMouseButtonPressed(.LEFT) {
                rl.OpenURL("https://www.openstreetmap.org/about")
            }
        }
        color := text_hover ? rl.BLUE : rl.BLACK
        draw_text(text, {text_rect.x, text_rect.y}, font_size, color)

        // Other providers
        if style != .Osm {
            if style == .Jawg {
                text = "(c) Jawg" 
            } else {
                text = "(c) Mapbox" 
            }
            text_rect.x += text_width * 0.9
            text_rect.width = f32(rl.MeasureText(text, i32(font_size)))
            text_hover = false
            if rl.CheckCollisionPointRec(mouse_pos, text_rect) {
                text_hover = true
                gui_mouse_cursor = .POINTING_HAND
                if rl.IsMouseButtonPressed(.LEFT) {
                    if style == .Jawg {
                        rl.OpenURL("https://www.jawg.io")
                    } else {
                        rl.OpenURL("https://www.mapbox.com/about/maps")
                    }
                }
            }
            color = text_hover ? rl.BLUE : rl.BLACK
            draw_text(text, {text_rect.x, text_rect.y}, font_size, color)
        }

    }

    // draw the icon last
    font_size := rect.height
    if icon_hover || expanded {
        rl.DrawRectangleRec(rect, PEACH)
    } else {
        rl.DrawRectangleRec(rect, WHITE)
    }
    rl.DrawRectangleLinesEx(rect, BORDER_THICK, DARK_BLUE)
    draw_text("i", {rect.x + rect.width / 4.0, rect.y}, font_size, rl.DARKBLUE)
}

// Gui drop down, items will all be the same size as rect
// ui_focus gets set when the mouse is hovering over the dropdown
gui_drop_down :: proc(rect: rl.Rectangle, text: cstring, items: []cstring, expanded: ^bool, selected: ^int, ui_focus: ^bool) -> bool {

    hover_item := -1
    did_select: bool

    count := len(items)
    rect := rect
    base_rect := rect
    mouse_pos := rl.GetMousePosition()

    if rl.CheckCollisionPointRec(mouse_pos, base_rect) {
        if rl.IsMouseButtonPressed(.LEFT) {
            expanded^ = !expanded^
        }
        hover_item = 0
    }
    if expanded^ {
        for i in 0..<count {
            rect.y += rect.height
            if rl.CheckCollisionPointRec(mouse_pos, rect) {
                if rl.IsMouseButtonPressed(.LEFT) {
                    did_select = true
                    selected^ = i
                }
                hover_item = i + 1
            }
        }
    }

    padding := rect.height * PADDING_FACTOR
    font_size := rect.height - 2 * padding

    // drop down
    rect = base_rect
    if expanded^ {
        hover := hover_item == -1 ? selected^ : hover_item - 1
        for i in 0..<count {
            rect.y += rect.height
            if i == hover {
                rl.DrawRectangleRec(rect, rl.Fade(BLUE, FADE_AMMOUNT))
            } else {
                rl.DrawRectangleRec(rect, rl.Fade(DARK_BLUE, FADE_AMMOUNT))
            }
            draw_text(items[i], {rect.x + padding, rect.y + padding}, font_size, WHITE)
        }
        rect.y = base_rect.y + rect.height
        rect.height *= f32(count)
        rl.DrawRectangleLinesEx(rect, BORDER_THICK, WHITE)
    }

    // Base rect
    if hover_item == 0 {
        rl.DrawRectangleRec(base_rect, BLUE)
    } else {
        rl.DrawRectangleRec(base_rect, DARK_BLUE)
    }
    draw_text(text, {rect.x + padding, base_rect.y + padding}, font_size, WHITE)
    rl.DrawRectangleLinesEx(base_rect, BORDER_THICK, WHITE)


    if hover_item != -1 && !ui_focus^ {
        ui_focus^ = true
    }

    return did_select
}
