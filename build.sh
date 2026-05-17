#!/bin/sh

set -xe
odin build src/main_desktop -out:jpx -o:speed -debug
