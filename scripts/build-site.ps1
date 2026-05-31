#!/usr/bin/env pwsh
# One-click full-site build (Windows / PowerShell).
# Produces ./dist with the VitePress site at the root and the Gallery under ./dist/gallery.
$ErrorActionPreference = 'Stop'

# Move to the repository root (this script lives in ./scripts).
Set-Location (Split-Path $PSScriptRoot -Parent)

Write-Host '==> Cleaning dist/' -ForegroundColor Cyan
if (Test-Path dist) { Remove-Item dist -Recurse -Force }

Write-Host '==> Building VitePress site (-> dist/)' -ForegroundColor Cyan
npm run docs:build

Write-Host '==> Building Gallery & demo apps (-> dist/gallery/)' -ForegroundColor Cyan
cargo xtask build-gallery --release

Write-Host ''
Write-Host 'Done. Full site is in ./dist' -ForegroundColor Green
Write-Host '  - Docs site : dist/index.html'
Write-Host '  - Gallery   : dist/gallery/index.html'
Write-Host 'Preview locally with: npm run site:preview'
