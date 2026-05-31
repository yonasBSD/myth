<script setup lang="ts">
import { withBase } from 'vitepress'

const videoSrc = withBase('/media/demo.mp4')
const poster = withBase('/images/hero.png')
</script>

<template>
  <div class="hero-video">
    <div class="hero-video__glow" aria-hidden="true"></div>
    <video
      class="hero-video__media"
      :src="videoSrc"
      :poster="poster"
      autoplay
      muted
      loop
      playsinline
      preload="metadata"
    ></video>
  </div>
</template>

<style scoped>
.hero-video {
  position: relative;
  width: 100%;
  max-width: 540px;
  aspect-ratio: 16 / 10;
  margin: 0 auto;
}

.hero-video__media {
  position: relative;
  z-index: 1;
  width: 100%;
  height: 100%;
  object-fit: cover;
  border-radius: 20px;
  box-shadow:
    0 18px 60px -12px rgba(0, 0, 0, 0.55),
    0 0 0 1px rgba(255, 255, 255, 0.06) inset;
  background: var(--vp-c-bg-soft);
}

/* Soft brand-colored glow behind the video, echoing the VitePress hero blur. */
.hero-video__glow {
  position: absolute;
  inset: -14% -10%;
  z-index: 0;
  border-radius: 50%;
  filter: blur(72px);
  opacity: 0.55;
  background-image: linear-gradient(
    -45deg,
    var(--vp-c-brand-3) 30%,
    var(--vp-c-brand-1) 70%
  );
}

@media (max-width: 960px) {
  .hero-video {
    max-width: 420px;
    margin-top: 16px;
  }
}

@media (prefers-reduced-motion: reduce) {
  .hero-video__media {
    /* Respect users who prefer no motion: the poster still conveys the visual. */
  }
}
</style>
