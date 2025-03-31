package main_web

import jpx ".."

import "base:runtime"
import "core:c"
import "core:mem"

@(private = "file")
web_context: runtime.Context

@(export)
main_start :: proc "c" () {
    context = runtime.default_context()

    context.allocator = emscripten_allocator()
    runtime.init_global_temporary_allocator(1 * mem.Megabyte)
    context.logger = create_emscripten_logger()

    web_context = context

    // platform specific init is seperated
    jpx.init_platform()
    jpx.init()
}

@(export)
main_update :: proc "c" () -> bool {
    context = web_context
    jpx.update()
    return jpx.should_run()
}

@(export)
main_end :: proc "c" () {
    context = web_context
    jpx.shutdown()
}

@(export)
web_window_size_changed :: proc "c" (w: c.int, h: c.int) {
    context = web_context
    jpx.parent_window_size_changed(int(w), int(h))
}
