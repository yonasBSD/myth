import DefaultTheme from 'vitepress/theme'
import { h } from 'vue'
import HeroVideo from './components/HeroVideo.vue'
import './custom.css'

export default {
  extends: DefaultTheme,
  Layout() {
    return h(DefaultTheme.Layout, null, {
      // Replace the static hero image with a looping engine-rendered video.
      'home-hero-image': () => h(HeroVideo)
    })
  }
}
