#!/bin/bash -e

# Point this to where you installed emscripten. Optional on systems that already
EMSCRIPTEN_SDK_DIR="$HOME/Software/emsdk"
OUT_DIR="web_build"

mkdir -p $OUT_DIR

release=false
if [[ "$#" -gt 0 && $1 = "release" ]]; then
    release=true
    # make sure we have the repo set up
    if [[ ! -d "$OUT_DIR/.git" ]]; then
        (
            cd $OUT_DIR
            git init
            git remote add origin git@github.com:jan-beukes/jpx-web.git
            git pull origin main
        )
    fi
fi

export EMSDK_QUIET=1
[[ -f "$EMSCRIPTEN_SDK_DIR/emsdk_env.sh" ]] && . "$EMSCRIPTEN_SDK_DIR/emsdk_env.sh"

# Note RAYLIB_WASM_LIB=env.o -- env.o is an internal WASM object file. You can
# see how RAYLIB_WASM_LIB is used inside <odin>/vendor/raylib/raylib.odin.
#
# The emcc call will be fed the actual raylib library file. That stuff will end
# up in env.o
#
(set -x; odin build src/main_web -out:"$OUT_DIR/jpx.wasm.obj" -target:js_wasm32 -build-mode:obj -define:RAYLIB_WASM_LIB=env.o -debug)

ODIN_PATH=$(odin root)

cp $ODIN_PATH/core/sys/wasm/js/odin.js $OUT_DIR
cp src/main_web/jpx.js $OUT_DIR

files="$OUT_DIR/jpx.wasm.obj ${ODIN_PATH}/vendor/raylib/v6/wasm/libraylib.web.a"

flags="-sUSE_GLFW=3 -sWASM_BIGINT -sWARN_ON_UNDEFINED_SYMBOLS=0 -sASSERTIONS -sALLOW_MEMORY_GROWTH --shell-file src/main_web/index_template.html"

# For debugging: Add `-g` to `emcc`
(set -x; emcc -o $OUT_DIR/index.html $files $flags)

rm $OUT_DIR/jpx.wasm.obj

echo "Web build created in '${OUT_DIR}'"

# copy resources create commit and push to web build
if $release; then
    echo -e "\033[32mReleasing web build\033[m"

    LAST_COMMIT=$(git rev-parse --short HEAD)

    cd $OUT_DIR
    echo web build of https://github.com/jan-beukes/jpx > README.md
    cp ../res/icon.png .

    git add .
    git commit -m "Changes based on $LAST_COMMIT"
    git push --force origin main

    echo -e "\033[32mWeb build pushed!\033[m"
fi
