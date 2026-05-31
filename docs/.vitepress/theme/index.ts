import DefaultTheme from 'vitepress/theme'
import { h } from 'vue'
import HeroVideo from './components/HeroVideo.vue'
import './custom.css'

export default {
  extends: DefaultTheme,
  Layout() {
    return h(DefaultTheme.Layout, null, {
      // An engine-rendered demo video in the hero image area (right side).
      'home-hero-image': () => h(HeroVideo)
    })
  }
}
