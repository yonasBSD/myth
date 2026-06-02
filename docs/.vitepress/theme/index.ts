import DefaultTheme from 'vitepress/theme'
import { h } from 'vue'
import HeroVideo from './components/HeroVideo.vue'
import './custom.css'
import { inBrowser } from 'vitepress'

export default {
  extends: DefaultTheme,
  enhanceApp({ router }: { router: any }) {
    if (!inBrowser) return

    const locales = ['en']
    const defaultLocale = 'zh'

    const initializeLocaleRoute = () => {
      const path = router.route.path
      
      if (path !== '/' && path !== '/index.html') return

      const savedLocale = localStorage.getItem('user-locale')
      let targetLocale = savedLocale

      if (!targetLocale) {
        const browserLang = navigator.language || (navigator as any).userLanguage || ''
        if (browserLang.startsWith('en')) {
          targetLocale = 'en'
        } else {
          targetLocale = defaultLocale
        }
      }

      if (targetLocale === 'en' && path === '/') {
        router.go('/en/')
      }
    }

    initializeLocaleRoute()

    router.onAfterRouteChanged = (to: string) => {
      if (to.startsWith('/en/')) {
        localStorage.setItem('user-locale', 'en')
      } else if (to === '/' || to.startsWith('/guide/') || to.startsWith('/architecture/')) {
        localStorage.setItem('user-locale', 'zh')
      }
    }
  },
  Layout() {
    return h(DefaultTheme.Layout, null, {
      // An engine-rendered demo video in the hero image area (right side).
      'home-hero-image': () => h(HeroVideo)
    })
  }
}
