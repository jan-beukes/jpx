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
        const dstArray = new Uint8Array(odinInterface.memory.buffer, ptr, byteArray.length);
        dstArray.set(byteArray);

        exports.fetch_callback(ptr, byteArray.length, tileX, tileY, tileZ);

        exports.free(ptr);
    })
        .catch(error => console.error("Fetch failed:", error));
}

function dropEvent(event) {
    var canvas = document.getElementById("canvas");
    event.preventDefault();
    event.stopPropagation();
    canvas.classList.remove('drag-over');
    console.log('Drop Event');

    const files = event.dataTransfer.files;

    if (files.length > 0) {
        const file = files[0];
        const reader = new FileReader();

        // on successful read
        reader.onload = function(e) {
            const fileData = e.target.result; // ArrayBuffer
            const byteArray = new Uint8Array(fileData);

            const exports = odinInterface.exports;
            console.log(byteArray.length);
            // alloc in wasm
            const ptr = exports.malloc(byteArray.length);
            const dstArray = new Uint8Array(odinInterface.memory.buffer, ptr, byteArray.length);
            dstArray.set(byteArray);

            // call wasm to handle opened file
            exports.track_load_callback(ptr, dstArray.length)
        };

        reader.onerror = function(e) {
            console.error("Error reading file:", e);
        };

        // read the file
        const fileName = file.name.toLowerCase();
        if (fileName.endsWith(".gpx")) {
            reader.readAsArrayBuffer(file)
        } else {
            console.error("Unsupported file type:", fileName);
        }
    }
}

// The Module is used as configuration for emscripten.
var Module = {
    // This is called by emscripten when it starts up.
    instantiateWasm: (imports, successCallback) => {

        // extra imports
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

        e._start();
        e.main_start();

        function send_resize() {
            var canvas = document.getElementById("canvas");
            e.web_window_size_changed(canvas.width, canvas.height);
        }

        // resize callback
        window.addEventListener("resize", function(event) {
            send_resize();
        }, true);

        send_resize();

        var canvas = document.getElementById("canvas");

        //--- Drag and drop events---
        canvas.addEventListener("dragenter", function(event) {
            event.preventDefault();
            event.stopPropagation();
            canvas.classList.add("drag-over"); // visual stuff
        })

        canvas.addEventListener("dragover", function(event) {
            event.preventDefault(); // for drop event to fire
            event.stopPropagation();
        })

        canvas.addEventListener('dragleave', (event) => {
            event.preventDefault();
            event.stopPropagation();
            canvas.classList.remove('drag-over');
            console.log('Drag Leave');
        });

        canvas.addEventListener("drop", dropEvent)

        // Runs the "main loop".
        function do_main_update() {
            if (!e.main_update()) {
                e.main_end();

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
