package main_desktop

import jpx ".."
import "core:os"
import "core:log"
import "core:path/filepath"

main :: proc () {
    context.logger = log.create_console_logger(
        .Debug when ODIN_DEBUG else .Info,
        log.Options{.Level, .Terminal_Color},
    )

    // XXX: Maybe rework this to use a user cache directory or to not cd and just store cache_dir as
    // relative in a global variable.

    // change to executable directory and make cache dir on desktop
    executable_dir, err := os.get_executable_directory(context.temp_allocator)
    if err != nil {
        log.error("Could not find executable directory")
        os.exit(1)
    }

    cwd: string
    cwd, err = os.get_working_directory(context.temp_allocator)
    if err != nil {
        log.error("Could get working directory")
        os.exit(1)
    }
    os.set_working_directory(executable_dir)
    os.make_directory(jpx.CACHE_DIR)

    jpx.init_platform(cwd)
    jpx.init()

    free_all(context.temp_allocator)
    for jpx.should_run() {
        jpx.update()
    }

    jpx.shutdown()
}
