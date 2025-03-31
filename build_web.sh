#!/bin/bash -eu

# Point this to where you installed emscripten. Optional on systems that already
EMSCRIPTEN_SDK_DIR="$HOME/Software/emsdk"
OUT_DIR="web_build"

mkdir -p $OUT_DIR

export EMSDK_QUIET=1
[[ -f "$EMSCRIPTEN_SDK_DIR/emsdk_env.sh" ]] && . "$EMSCRIPTEN_SDK_DIR/emsdk_env.sh"

# Note RAYLIB_WASM_LIB=env.o -- env.o is an internal WASM object file. You can
# see how RAYLIB_WASM_LIB is used inside <odin>/vendor/raylib/raylib.odin.
#
# The emcc call will be fed the actual raylib library file. That stuff will end
# up in env.o
#
odin build src/main_web -target:js_wasm32 -build-mode:obj -define:RAYLIB_WASM_LIB=env.o -out:$OUT_DIR/jpx -debug

ODIN_PATH=$(odin root)

cp $ODIN_PATH/core/sys/wasm/js/odin.js $OUT_DIR
cp src/main_web/jpx.js $OUT_DIR

files="$OUT_DIR/jpx.wasm.o ${ODIN_PATH}/vendor/raylib/wasm/libraylib.a"

flags="-sUSE_GLFW=3 -sWASM_BIGINT -sWARN_ON_UNDEFINED_SYMBOLS=0 -sASSERTIONS --shell-file src/main_web/index_template.html"

# For debugging: Add `-g` to `emcc`
emcc -o $OUT_DIR/index.html $files $flags

rm $OUT_DIR/jpx.wasm.o

echo "Web build created in ${OUT_DIR}"
