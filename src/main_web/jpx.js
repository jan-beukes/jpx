
var odinInterface = new odin.WasmMemoryInterface();
odinInterface.setIntSize(4);
var odinImports = odin.setupDefaultImports(odinInterface);

function fetchTile(urlPtr, urlLen, tileX, tileY, tileZ) {
    const url = odinInterface.loadString(urlPtr, urlLen);
    const exports = odinInterface.exports;
    fetch(url).then(response => response.arrayBuffer()).then(buffer => {
        const byteArray = new Uint8Array(buffer);
        // need to move the data to wasm mem
        const ptr = exports.malloc(byteArray.length);
        const dst = new Uint8Array(odinInterface.memory.buffer, ptr, byteArray.length);
        dst.set(byteArray);

        exports.fetch_callback(ptr, byteArray.length, tileX, tileY, tileZ);

        exports.free(ptr);
    })
        .catch(error => console.error("Fetch failed:", error));
}

// The Module is used as configuration for emscripten.
var Module = {
    // This is called by emscripten when it starts up.
    instantiateWasm: (imports, successCallback) => {
        imports.env.fetchTile = fetchTile;
        const newImports = {
            ...odinImports,
            ...imports
        };

        return WebAssembly.instantiateStreaming(fetch("index.wasm"), newImports).then(function(output) {
            var e = output.instance.exports;
            odinInterface.setExports(e);
            odinInterface.setMemory(e.memory);
            return successCallback(output.instance);
        });
    },

    // This happens a bit after `instantiateWasm`, when everything is
    // done setting up. At that point we can run code.
    onRuntimeInitialized: () => {
        var e = wasmExports;

        // Calls any procedure marked with @init
        e._start();

        // See source/main_web/main_web.odin for main_start,
        // main_update and main_end.
        e.main_start();

        function send_resize() {
            var canvas = document.getElementById('canvas');
            e.web_window_size_changed(canvas.width, canvas.height);
        }

        window.addEventListener('resize', function(event) {
            send_resize();
        }, true);

        // This can probably be done better: Ideally we'd feed the
        // initial size to `main_start`. But there seems to be a
        // race condition. `canvas` doesn't have it's correct size yet.
        send_resize();

        // Runs the "main loop".
        function do_main_update() {
            if (!e.main_update()) {
                e.main_end();

                // Calls procedures marked with @fini
                e._end();
                return;
            }
            window.requestAnimationFrame(do_main_update);
        }

        window.requestAnimationFrame(do_main_update);
    },
    print: (function() {
        var element = document.getElementById("output");
        if (element) element.value = ''; // clear browser cache
        return function(text) {
            if (arguments.length > 1) text = Array.prototype.slice.call(arguments).join(' ');
            console.log(text);
            if (element) {
                element.value += text + "\n";
                element.scrollTop = element.scrollHeight; // focus on bottom
            }
        };
    })(),
    canvas: (function() {
        return document.getElementById("canvas");
    })()
};
