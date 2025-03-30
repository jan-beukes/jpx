var odinMemoryInterface = new odin.WasmMemoryInterface();
odinMemoryInterface.setIntSize(4);
var odinImports = odin.setupDefaultImports(odinMemoryInterface);

// The Module is used as configuration for emscripten.
var Module = {
    // This is called by emscripten when it starts up.
    instantiateWasm: (imports, successCallback) => {
        const newImports = {
            ...odinImports,
            ...imports
        }

        return WebAssembly.instantiateStreaming(fetch("index.wasm"), newImports).then(function(output) {
            var e = output.instance.exports
            odinMemoryInterface.setExports(e)
            odinMemoryInterface.setMemory(e.memory)
            successCallback(output.instance);

            // Calls any procedure marked with @init
            e._start();


            // run the main_start in main.odin
            e.main_start();

            // resize
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
            return output.instance.exports;
        });
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
