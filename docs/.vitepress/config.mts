import { defineConfig } from 'vitepress'
import { withMermaid } from 'vitepress-plugin-mermaid'

export default withMermaid(
  defineConfig({
    title: "Myth Engine",
    description: "极致性能的轻量级 Rust 渲染引擎",
    
    // 默认的主题配置
    themeConfig: {
      // 站点的 Logo，可以后续设计一个放在 public 目录下
      // logo: '/logo.svg',

      // 顶部导航栏
      nav: [
        { text: '指南', link: '/guide/introduction' },
        { text: '架构', link: '/architecture/render-graph' },
        { text: 'API 参考', link: '/api/' }, // 后续链接到 cargo doc
        // { text: '在线体验', link: '/gallery/' } // 预留给后续的 WebGPU WASM Demo
      ],

      // 侧边栏结构
      sidebar: [
        {
          text: '基础指南 (Guide)',
          items: [
            { text: '简介与愿景', link: '/guide/introduction' },
            { text: '快速开始', link: '/guide/quick-start' },
            { text: '场景与节点系统', link: '/guide/scene-graph' }
          ]
        },
        {
          text: '引擎架构 (Architecture)',
          items: [
            { text: 'Render Graph 渲染图', link: '/architecture/render-graph' },
            { text: '异步资源与加载管线', link: '/architecture/asset-pipeline' },
            { text: '高性能材质系统', link: '/architecture/material-system' }
          ]
        },
        {
          text: '进阶渲染特性 (Advanced)',
          items: [
            { text: 'GPU-Driven 与聚类光照', link: '/advanced/clustered-shading' },
            { text: '3DGS (高斯溅射) 融合渲染', link: '/advanced/3dgs-integration' },
            { text: '自定义 Shader 与后处理', link: '/advanced/custom-shader' }
          ]
        }
      ],

      socialLinks: [
        { icon: 'github', link: 'https://github.com/panxinmiao/myth' }
      ],

      outline: {
        label: '本页大纲',
        level: [2, 3]
      },
      
      search: {
        provider: 'local'
      }
    }
  })
)