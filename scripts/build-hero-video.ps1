<#
.SYNOPSIS
    Renders the transparent homepage hero animation and encodes it into a
    transparent WebM (VP9 / yuva420p) plus a transparent PNG poster.

.DESCRIPTION
    1. Runs the `hero_capture` example, which replicates the showcase Cinematic
       scene on a transparent background and writes an RGBA PNG sequence to
       target/hero_frames/. The frame count equals exactly one loop of the
       character's facial animation, captured at 30 fps real-time.
    2. Encodes the frames into docs/public/media/demo.webm with a real alpha
       channel (VP9) at the same 30 fps, so the animation plays at its natural
       speed and loops seamlessly. This is what the homepage <video> plays.
    3. Copies a representative frame to docs/public/images/hero.png as the
       poster / Safari fallback (Safari does not honour VP9 alpha in <video>).

.PARAMETER SkipRender
    Reuse the existing PNG sequence and only run the ffmpeg encode step.

.PARAMETER Size
    Square render resolution in pixels (default 1024).
#>
param(
    [switch]$SkipRender,
    [int]$Size = 1024
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# Capture frame rate — must match the encode frame rate below and the fixed
# dt used inside examples/hero_capture.rs (1/30 s).
$fps = 30

# Locate ffmpeg (PATH first, then the known local install).
$ffmpegCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
$ffmpeg = if ($ffmpegCmd) { $ffmpegCmd.Source } else { $null }
if (-not $ffmpeg) {
    $candidate = 'D:\ffmpeg\bin\ffmpeg.exe'
    if (Test-Path $candidate) { $ffmpeg = $candidate }
}
if (-not $ffmpeg) { throw 'ffmpeg not found in PATH or D:\ffmpeg\bin\ffmpeg.exe' }
Write-Host "Using ffmpeg: $ffmpeg"

$framesDir = Join-Path $repoRoot 'target/hero_frames'

if (-not $SkipRender) {
    Write-Host "Rendering transparent frames at ${Size}x${Size} (one animation loop)..."
    Remove-Item Env:\HERO_FRAMES -ErrorAction SilentlyContinue
    $env:HERO_SIZE = "$Size"
    $env:RUST_LOG = 'warn'
    cargo run --release --features gltf-meshopt --example hero_capture
    if ($LASTEXITCODE -ne 0) { throw 'hero_capture render failed' }
}

$firstFrame = Join-Path $framesDir 'frame_0000.png'
if (-not (Test-Path $firstFrame)) { throw "No frames found in $framesDir" }

$mediaDir = Join-Path $repoRoot 'docs/public/media'
$imagesDir = Join-Path $repoRoot 'docs/public/images'
New-Item -ItemType Directory -Force -Path $mediaDir, $imagesDir | Out-Null

# Display size on the homepage is ~600px, so 768 square is ample and keeps the
# file web-light. CRF 40 + cpu-used 2 yields a clean skin look at ~2 MB.
$outRes = 768

$webm = Join-Path $mediaDir 'demo.webm'
Write-Host "Encoding transparent WebM (VP9, yuva420p, ${fps}fps, ${outRes}px) -> $webm"
& $ffmpeg -y -framerate $fps -i (Join-Path $framesDir 'frame_%04d.png') `
    -c:v libvpx-vp9 -pix_fmt yuva420p -b:v 0 -crf 40 -deadline good -cpu-used 2 `
    -row-mt 1 -vf "scale=${outRes}:${outRes}" -r $fps -an $webm
if ($LASTEXITCODE -ne 0) { throw 'WebM encode failed' }

# Poster / Safari fallback: a representative mid-animation frame, scaled to
# match the WebM resolution so it stays transparent and light.
$frameCount = (Get-ChildItem (Join-Path $framesDir 'frame_*.png')).Count
$posterIndex = [int][math]::Floor($frameCount / 4)
$posterSrc = Join-Path $framesDir ('frame_{0:D4}.png' -f $posterIndex)
$posterDst = Join-Path $imagesDir 'hero.png'
& $ffmpeg -y -i $posterSrc -vf "scale=${outRes}:${outRes}" -update 1 $posterDst
if ($LASTEXITCODE -ne 0) { throw 'Poster encode failed' }
Write-Host "Poster -> $posterDst (frame $posterIndex of $frameCount)"

Write-Host 'Done.'
Write-Host ("  WebM:   {0:n2} MB" -f ((Get-Item $webm).Length / 1MB))
Write-Host ("  Poster: {0:n0} KB" -f ((Get-Item $posterDst).Length / 1KB))
