#!/usr/bin/env bash
# Rune's brand images (scripts/brand/rune-brand.html), rendered with WebKit
# (scripts/brand/render.swift) into site/brand/: rune-product-1600x1200.png (Lemon Squeezy's
# product image), rune-card-1200x630.png (the site's link preview, og:image) and
# rune-github-1280x640.png (the repository's social preview: GitHub › Settings › General), and
# Product Hunt's images from scripts/brand/rune-ph.html into launch/product-hunt/. Run it after
# changing either page.
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
# Product Hunt (launch/product-hunt.md): the gallery at 1270×760, the thumbnail at 240×240.
mkdir -p launch/product-hunt
renderph() {   # renderph <fragment> <width> <height> <output>
  build/render-page "scripts/brand/rune-ph.html#$1" "$2" "$3" "$4"
  sips -z "$3" "$2" "$4" >/dev/null
  echo "==> $4 ($(sips -g pixelWidth -g pixelHeight "$4" | awk '/pixel/ {print $2}' | paste -sd x -))"
}
renderph hero 1270 760 launch/product-hunt/1-rune-1270x760.png
renderph conflict 1270 760 launch/product-hunt/2-conflicts-1270x760.png
renderph find 1270 760 launch/product-hunt/3-find-in-history-1270x760.png
renderph thumb 240 240 launch/product-hunt/thumbnail-240x240.png
