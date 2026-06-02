import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'

// Shared, language-agnostic configuration
const GITHUB_REPO = 'https://github.com/panxinmiao/myth'

// Deployment base. Local dev/preview uses '/'; CI sets DOCS_BASE='/myth/'
// so the site is served from https://panxinmiao.github.io/myth/.
const BASE = process.env.DOCS_BASE ?? '/'

// The Gallery is built as a static sub-app under <base>/gallery/.
// `target: '_self'` forces a full-page navigation out of the VitePress SPA.
const GALLERY_LINK = `${BASE}gallery/`

// ── Chinese (root) sidebar ──────────────────────────────────────────────
function sidebarZh() {
  return [
    {
      text: '基础指南',
      collapsed: false,
      items: [
        { text: '简介与愿景', link: '/guide/introduction' },
        { text: '核心特性总览', link: '/guide/features' },
        { text: '快速开始', link: '/guide/quick-start' },
        { text: '场景与节点系统', link: '/guide/scene-graph' },
        { text: '资产、glTF 与动画', link: '/guide/assets-animation' },
        { text: 'Python 绑定', link: '/guide/python' }
      ]
    },
    {
      text: '引擎架构',
      collapsed: false,
      items: [
        { text: '渲染路径与帧合成', link: '/architecture/rendering-pipeline' },
        { text: 'Render Graph 渲染图', link: '/architecture/render-graph' },
        { text: '异步资源与加载管线', link: '/architecture/asset-pipeline' },
        { text: '高性能材质系统', link: '/architecture/material-system' }
      ]
    },
    {
      text: '进阶渲染特性',
      collapsed: false,
      items: [
        { text: 'PBR 物理材质', link: '/advanced/pbr-materials' },
        { text: 'GPU-Driven 与聚类光照', link: '/advanced/clustered-shading' },
        { text: '后处理与屏幕空间特效', link: '/advanced/post-processing' },
        { text: '程序化天空与大气', link: '/advanced/procedural-sky' },
        { text: '3DGS 高斯溅射融合渲染', link: '/advanced/3dgs-integration' },
        { text: '自定义 Shader 与后处理', link: '/advanced/custom-shader' },
        { text: '离屏与无头渲染', link: '/advanced/headless-rendering' }
      ]
    }
  ]
}

// ── Chinese articles sidebar ────────────────────────────────
function sidebarArticlesZh() {
  return [
    {
      text: '技术文章',
      collapsed: false,
      items: [
        { text: '文章列表', link: '/articles/' },
        { text: '构建基于 SSA 的声明式渲染图', link: '/articles/render-graph-design' }
      ]
    }
  ]
}

// ── English sidebar ─────────────────────────────────────────────────────
function sidebarEn() {
  return [
    {
      text: 'Guide',
      collapsed: false,
      items: [
        { text: 'Introduction & Vision', link: '/en/guide/introduction' },
        { text: 'Feature Overview', link: '/en/guide/features' },
        { text: 'Quick Start', link: '/en/guide/quick-start' },
        { text: 'Scene & Node System', link: '/en/guide/scene-graph' },
        { text: 'Assets, glTF & Animation', link: '/en/guide/assets-animation' },
        { text: 'Python Bindings', link: '/en/guide/python' }
      ]
    },
    {
      text: 'Architecture',
      collapsed: false,
      items: [
        { text: 'Render Paths & Frame Composer', link: '/en/architecture/rendering-pipeline' },
        { text: 'Render Graph', link: '/en/architecture/render-graph' },
        { text: 'Async Asset Pipeline', link: '/en/architecture/asset-pipeline' },
        { text: 'Material System', link: '/en/architecture/material-system' }
      ]
    },
    {
      text: 'Advanced Rendering',
      collapsed: false,
      items: [
        { text: 'PBR Materials', link: '/en/advanced/pbr-materials' },
        { text: 'GPU-Driven Clustered Lighting', link: '/en/advanced/clustered-shading' },
        { text: 'Post-Processing & Screen-Space FX', link: '/en/advanced/post-processing' },
        { text: 'Procedural Sky & Atmosphere', link: '/en/advanced/procedural-sky' },
        { text: '3D Gaussian Splatting', link: '/en/advanced/3dgs-integration' },
        { text: 'Custom Shaders & Post FX', link: '/en/advanced/custom-shader' },
        { text: 'Headless & Offscreen Rendering', link: '/en/advanced/headless-rendering' }
      ]
    }
  ]
}

// ── English articles sidebar ───────────────────────────────
function sidebarArticlesEn() {
  return [
    {
      text: 'Articles',
      collapsed: false,
      items: [
        { text: 'All Articles', link: '/en/articles/' },
        { text: 'Building an SSA-based Declarative Render Graph', link: '/en/articles/render-graph-design' }
      ]
    }
  ]
}

export default withMermaid(
  defineConfig({
    title: 'Myth Engine',
    description: '极致性能的轻量级 Rust 渲染引擎 · A high-performance, lightweight Rust rendering engine',

    base: BASE,
    lastUpdated: true,
    cleanUrls: true,
    ignoreDeadLinks: true,
    // Build the docs site into the shared workspace `dist/`, where the Gallery
    // is nested under `dist/gallery/` (see [workspace.metadata.gallery]).
    outDir: '../dist',

    // The Gallery is a separately-built static sub-app living at
    // `dist/gallery/`. By default Vite wipes the whole `outDir` before each
    // build, which would delete that (slow-to-rebuild) gallery. Disabling
    // `emptyOutDir` makes the docs build overwrite only its own output and
    // leave `dist/gallery/` (and anything else) untouched.
    vite: {
      build: {
        emptyOutDir: false
      }
    },

    head: [
      ['meta', { name: 'theme-color', content: '#4a6f9f' }]
    ],

    themeConfig: {
      // logo: '/images/logo.svg',
      socialLinks: [{ icon: 'github', link: GITHUB_REPO }],
      search: { provider: 'local' }
    },

    locales: {
      root: {
        label: '简体中文',
        lang: 'zh-CN',
        themeConfig: {
          nav: [
            { text: '指南', link: '/guide/introduction', activeMatch: '/guide/' },
            { text: '架构', link: '/architecture/rendering-pipeline', activeMatch: '/architecture/' },
            { text: '进阶', link: '/advanced/pbr-materials', activeMatch: '/advanced/' },
            { text: '文章', link: '/articles/', activeMatch: '/articles/' },
            { text: 'Gallery', link: GALLERY_LINK, target: '_self' },
            {
              text: '更多',
              items: [
                { text: 'Examples 示例', link: `${GITHUB_REPO}/tree/main/examples` },
                { text: 'Python 绑定', link: `${GITHUB_REPO}/tree/main/bindings/python` },
                { text: 'Change Log', link: `${GITHUB_REPO}/tree/main/CHANGELOG.md` },
              ]
            }
          ],
          sidebar: {
            '/articles/': sidebarArticlesZh(),
            '/': sidebarZh()
          },
          outline: { label: '本页大纲', level: [2, 3] },
          docFooter: { prev: '上一页', next: '下一页' },
          lastUpdatedText: '最后更新于',
          returnToTopLabel: '回到顶部',
          sidebarMenuLabel: '菜单',
          darkModeSwitchLabel: '主题',
          lightModeSwitchTitle: '切换到浅色模式',
          darkModeSwitchTitle: '切换到深色模式',
          editLink: {
            pattern: `${GITHUB_REPO}/edit/main/docs/:path`,
            text: '在 GitHub 上编辑此页'
          },
          footer: {
            message: '基于 MIT / Apache-2.0 双协议发布',
            copyright: 'Copyright © 2026-present Pan Xinmiao'
          }
        }
      },
      en: {
        label: 'English',
        lang: 'en-US',
        link: '/en/',
        themeConfig: {
          nav: [
            { text: 'Guide', link: '/en/guide/introduction', activeMatch: '/en/guide/' },
            { text: 'Architecture', link: '/en/architecture/rendering-pipeline', activeMatch: '/en/architecture/' },
            { text: 'Advanced', link: '/en/advanced/pbr-materials', activeMatch: '/en/advanced/' },
            { text: 'Articles', link: '/en/articles/', activeMatch: '/en/articles/' },
            { text: 'Gallery', link: GALLERY_LINK, target: '_self' },
            {
              text: 'More',
              items: [
                { text: 'Examples', link: `${GITHUB_REPO}/tree/main/examples` },
                { text: 'Python Bindings', link: `${GITHUB_REPO}/tree/main/bindings/python` },
                { text: 'Change Log', link: `${GITHUB_REPO}/tree/main/CHANGELOG.md` },
              ]
            }
          ],
          sidebar: {
            '/en/articles/': sidebarArticlesEn(),
            '/en/': sidebarEn()
          },
          outline: { label: 'On this page', level: [2, 3] },
          editLink: {
            pattern: `${GITHUB_REPO}/edit/main/docs/:path`,
            text: 'Edit this page on GitHub'
          },
          footer: {
            message: 'Released under the MIT / Apache-2.0 dual license',
            copyright: 'Copyright © 2026-present Pan Xinmiao'
          }
        }
      }
    }
  })
)