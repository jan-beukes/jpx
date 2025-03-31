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

    // change to application directory and make cache dir on desktop
    cwd := os.get_current_directory()
    dir := filepath.dir(os.args[0])
    os.set_current_directory(dir)
    os.make_directory(jpx.CACHE_DIR)

    jpx.init_platform(cwd)
    jpx.init()

    for jpx.should_run() {
        jpx.update()
    }

    jpx.shutdown()
}
