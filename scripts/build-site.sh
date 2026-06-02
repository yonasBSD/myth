#!/usr/bin/env bash
# One-click full-site build (Linux / macOS).
# Produces ./dist with the VitePress site at the root and the Gallery under ./dist/gallery.
set -euo pipefail

# Move to the repository root (this script lives in ./scripts).
cd "$(dirname "$0")/.."

echo "==> Cleaning dist/"
rm -rf dist

echo "==> Building VitePress site (-> dist/)"
npm run docs:build

echo "==> Building Gallery & demo apps (-> dist/gallery/)"
cargo xtask build-gallery --release

echo ""
echo "Done. Full site is in ./dist"
echo "  - Docs site : dist/index.html"
echo "  - Gallery   : dist/gallery/index.html"
echo "Preview locally with: npm run docs:preview"
