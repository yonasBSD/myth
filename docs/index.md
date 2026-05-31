---
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "Myth Engine"
  text: "Next-Gen Rendering in Rust"
  tagline: 跨平台现代图形架构，专为下一代实时 3D 交互设计
  image:
    src: /images/hero.jpg
    alt: Myth Engine Hero Image
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/introduction
    - theme: alt
      text: Gallery
      link: https://myth.panxinmiao.com
    - theme: alt
      text: GitHub
      link: https://github.com/panxinmiao/myth

features:
  - title: 纯粹的 Rust 核心
    details: 无 GC 负担，内存安全。基于 Rust 提供极致的底层性能释放。
  - title: 现代渲染管线
    details: 深度整合 GPU 驱动的集群光照 (Clustered Lighting) 与 Render Graph 架构。
  - title: 原生 3D 高斯溅射
    details: 作为引擎第一等公民的 3D Gaussian Splatting 支持，解锁下一代神经渲染。
---