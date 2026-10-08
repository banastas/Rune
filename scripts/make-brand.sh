#!/usr/bin/env bash
# Rune's brand images (scripts/brand/rune-brand.html), rendered with WebKit
# (scripts/brand/render.swift) into site/brand/: rune-product-1600x1200.png (Lemon Squeezy's
# product image), rune-card-1200x630.png (the site's link preview, og:image) and
# rune-github-1280x640.png (the repository's social preview: GitHub › Settings › General). Run it
# after changing the page.
#
#   scripts/make-brand.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

mkdir -p site/brand build
swiftc -O -o build/render-page scripts/brand/render.swift
render() {   # render <fragment> <width> <height> <output>
  build/render-page "scripts/brand/rune-brand.html#$1" "$2" "$3" "$4"
  sips -z "$3" "$2" "$4" >/dev/null   # a Retina Mac draws it at 2×: exactly half, so the pixel art stays sharp
  echo "==> $4 ($(sips -g pixelWidth -g pixelHeight "$4" | awk '/pixel/ {print $2}' | paste -sd x -))"
}
render product 1600 1200 site/brand/rune-product-1600x1200.png
render card 1200 630 site/brand/rune-card-1200x630.png
render github 1280 640 site/brand/rune-github-1280x640.png
