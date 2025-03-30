#+build js
package jpx

// web implementation of the platform specific code
// currently requests and file dialog

init_platform_requests :: proc() {
    request_context = context
    is_offline = offline
    req_state.m_handle = curl.multi_init()
    thread.run(io_thread_proc)
}

deinit_platform_requests :: proc() {
    curl.multi_cleanup(req_state.m_handle)
}
