<script setup lang="ts">
import { withBase } from 'vitepress'

// Transparent-background assets rendered offline by the `hero_capture`
// example (see scripts/build-hero-video.ps1). The WebM carries a real alpha
// channel (VP9) so it blends into both the light and dark themes; 
// Safari does not support VP9 alpha, so the MOV is a fallback for that and similar platforms.
const videoSrcWebm = withBase('/media/demo.webm')
const videoSrcMov = withBase('/media/demo.mov')
const poster = withBase('/images/hero.png')
</script>

<template>
  <div class="hero-video">
    <div class="hero-video__glow" aria-hidden="true"></div>
    <video
      class="hero-video__media"
      :poster="poster"
      autoplay
      muted
      loop
      playsinline
      preload="metadata"
    >
      <source :src="videoSrcMov" type='video/mp4; codecs="hvc1"'>
      <source :src="videoSrcWebm" type="video/webm">
  </video>
  </div>
</template>

<style scoped>
.hero-video {
  position: relative;
  width: 100%;
  aspect-ratio: 1 / 1;
  margin: 0 auto;
  background: transparent;
}

/* The media has a transparent background, so no frame/shadow/fill — it must
   blend straight into the page in both light and dark mode. */
.hero-video__media {
  position: relative;
  z-index: 1;
  display: block;
  width: 100%;
  height: 100%;
  object-fit: contain;
  background: transparent;
}

/* Soft brand-colored aura behind the character, echoing the VitePress hero
   blur. Kept subtle so it reads well on both themes. */
.hero-video__glow {
  position: absolute;
  inset: 8% 6% 2%;
  z-index: 0;
  border-radius: 50%;
  filter: blur(80px);
  opacity: 0.4;
  background-image: linear-gradient(
    -45deg,
    var(--vp-c-brand-3) 30%,
    var(--vp-c-brand-1) 70%
    /* #bd34fe 50%,
    #47caff 50% */
  );
}
</style>
