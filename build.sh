#!/bin/sh

jpx.odin

set -xe
odin build src/main_desktop -out:jpx -debug
