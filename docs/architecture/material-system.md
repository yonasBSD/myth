# 高性能材质系统

为了榨干每一滴 GPU 性能，Myth 引擎在底层材质体系的设计上有着极其严苛的要求。我们拒绝在渲染热路径 (Hot Path) 上引入任何不必要的开销。

## 1. 摒弃动态字典，拥抱强类型

在许多高层引擎或 Myth 早期的原型设计中，材质属性往往通过类似于 `HashMap<String, MaterialValue>` 的结构进行存储。这种设计虽然拥有极大的灵活性，但在每一帧需要遍历数千个材质实例构建 Bind Group 时，字符串哈希计算和不连续的内存访问会造成严重的性能瓶颈。

在经历了数轮深度重构后，Myth **彻底摒弃了基于 HashMap 的临时设计**。

目前的引擎采用了**内存紧凑且对缓存极为友好的强类型数据结构**。所有的材质属性都被严格布局为符合 `std140` 标准的 Rust `struct`，并利用 Rust 的宏系统 (`#[myth_material]`) 在编译期自动生成 GPU 映射代码。

```rust
// 强类型、内存紧凑的材质定义，告别 HashMap
#[myth_material(shader = "examples/holo", shader_src = HOLO_SHADER)]
pub struct HoloMaterial {
    #[uniform(default = "Vec4::new(0.1, 0.8, 1.2, 1.0)")]
    pub base_color: Vec4,

    #[uniform(default = "1.0")]
    pub opacity: f32,
    
    #[texture]
    pub normal_map: TextureSlot,
}

```

## 2. 宏驱动的管线生成

如上所示的 `#[myth_material]` 宏并不是简单的语法糖，它是连接 CPU 端紧凑数据与 GPU 端 Shader 契约的桥梁。对于每一个声明的材质，宏会自动生成：

1. **零开销的 GPU 可上传 Uniform Struct**：自动处理对齐问题。
2. **全自动的版本追踪 (Version Tracking)**：一旦材质属性（如贴图或参数）发生改变，引擎会自动触发对应管线缓存的失效与重建，而不需要开发者手动干预。
3. **WGSL 映射**：字段名自动映射为 Shader 中的 `u_material` 成员，`#[texture]` 自动生成纹理绑定和对应的 `HAS_MAP` 等宏定义。

## 3. Shader 模板注入系统

对于高级开发者，Myth 不强制你编写海量的样板代码。引擎的着色器模板模型分为 `Template` 模式与 `MaterialBody` 模式。

在默认的 `MaterialBody` 模式下，你只需要编写最核心的着色逻辑（如 `fs_main` 和 `vs_main` 的内部计算），引擎的编译器会自动为你注入：

* 场景光照结构体 (`scene_lighting_structs`)
* 集群光照定义 (`clustered_lighting_structs`)
* 基于几何布局自动生成的顶点输入结构 (`VertexInput`)

这种设计使得同一份材质代码能够无缝游走于前向渲染、深度预处理 (Depth Prepass) 和阴影投射 (Shadow Pass) 等多套管线中，实现了极高程度的代码复用。