[English](AdvancedCustomization.md)

---

# Myth 高级扩展与自定义指南

Myth 提供了一套面向高级用户的自定义扩展机制：

1. 通过 `#[myth_material]` 或手写 `RenderableMaterialTrait` 定义自定义网格材质。
2. 通过内置命名模板、注册命名模板、或内联 WGSL 来扩展着色器模板。
3. 通过 Template Pass 系统扩展自定义的 fullscreen/render/compute 图节点。

这份文档聚焦于这套能力的当前正式契约，尤其是引擎会自动生成哪些 WGSL 接口，以及高级用户可以稳定依赖哪些能力。

## 1. 如何选择扩展入口

| 目标 | 推荐 API | 你需要写什么 | 参考示例 |
| --- | --- | --- | --- |
| 想写一个仍然走标准几何材质管线的自定义网格材质 | `#[myth_material(shader = "...", shader_src = WGSL)]` | 只写材质自己的 WGSL 逻辑 body | [examples/custom_material_hologram.rs](../examples/custom_material_hologram.rs), [examples/custom_material_dissolve.rs](../examples/custom_material_dissolve.rs) |
| 想完全控制一个网格材质的完整 WGSL 模板 | `#[myth_material(shader = "...", shader_template_src = WGSL)]` | 完整模板源码 | [examples/custom_material_template_aurora_gate.rs](../examples/custom_material_template_aurora_gate.rs) |
| 材质的 Rust 侧资源模型已经超出宏能描述的范围 | 手写 `RenderableMaterialTrait` | 完整 trait 实现和 WGSL | `myth_resources::material` 中的内置材质 |
| 想做自定义全屏后处理 | `RenderPassBuilder::fullscreen(...)` | fullscreen WGSL + 图资源绑定 | [examples/custom_post_fx.rs](../examples/custom_post_fx.rs) |
| 想做自定义 compute pass / GPU 数据生成 pass | `ComputePassBuilder::new(...)` | compute WGSL + 图资源绑定 | [examples/gpu_driven_particle_lights.rs](../examples/gpu_driven_particle_lights.rs) |
| 想覆盖某个 `ShaderSource::File("name")` 的命名模板 | `renderer.register_shader_template(name, source)` | 完整模板源码 | 应用级命名模板或对引擎模板的覆盖 |

最核心的选择原则只有两条：

- 普通自定义材质优先用 `shader_src`。
- 只有当你确实需要完整模板控制权时，才用 `shader_template_src` 或 Template Pass。

## 2. Myth 的着色器模板模型

### 2.1 命名模板与内联源码

在内部，Myth 将着色器来源分成两种：

| 来源类型 | 含义 | 用户通常从哪里接触到 |
| --- | --- | --- |
| `ShaderSource::File("name")` | 通过名字查找模板。若存在注册模板则优先使用，否则回退到内置嵌入模板。 | 内置材质模板、`RenderPassBuilder::shader_template(...)`、`ComputePassBuilder::shader_template(...)` |
| `ShaderSource::Inline { ... }` | 直接使用调用方提供的 WGSL 字符串。 | `shader_src`、`shader_template_src`、`inline_shader_template(...)` |

这点很重要，因为现在 custom material 的内嵌源码会直接跟着材质实例走，**不会**先注册到全局模板表再去回退查找。

### 2.2 Template 模式与 MaterialBody 模式

除了来源类型，Myth 还区分两种解释模式：

| 模式 | 含义 | 用户侧入口 |
| --- | --- | --- |
| `ShaderTemplateMode::Template` | 源码是完整 WGSL 模板，你自己拥有完整的 entry-point 与模板结构控制权。 | `shader_template_src`、`inline_shader_template(...)`、`register_shader_template(...)` |
| `ShaderTemplateMode::MaterialBody` | 源码只是标准几何材质模板中的“材质 body”，引擎会自动补标准前导块。 | `shader_src` |

所以，`shader_src` 才是大多数高级材质作者的默认路径。它的目标不是“限制你”，而是“把标准几何材质必须重复的样板交给引擎处理”。

### 2.3 模板语法

Myth 使用 Minijinja，并配置了适合 WGSL 的分隔符：

| 语法 | 含义 |
| --- | --- |
| `{{ name }}` | 展开变量或注入的代码块 |
| `{$ include 'path' $}` | 包含内置 shader chunk |
| `$$ if SOME_DEFINE is defined` | 行语句形式的条件分支 |

模板环境还提供了 `loc.next()`，用于在模板里自动分配 `@location(...)`。

### 2.4 引擎会自动注入什么模板上下文

每次 shader 编译时，Myth 都会把 `defines` 和 `code_blocks` 扁平化注入模板上下文。标准几何材质路径会自动注入这些键：

| 注入键 | 含义 |
| --- | --- |
| `vertex_input_code` | 根据当前 `Geometry` 布局自动生成的 `VertexInput` WGSL 结构体 |
| `binding_code` | 当前 bind group 的 WGSL 声明拼接结果 |
| `scene_lighting_structs` | 场景光照相关 WGSL 结构体，包含 `Struct_lights`、`LightBufferMetadata` 等 |
| `clustered_lighting_structs` | 集群光照启用时额外注入的结构体 |

对于 `shader_src` 的 body 模式，引擎还会自动补入：

- `core/vertex_output`
- `core/fragment_output`

这就是为什么 body 模式的 shader 可以直接写 `VertexOutput`、`FragmentOutput`、`pack_fragment_output(...)`，而不用每个材质都手写完整模板样板。

### 2.5 define 的来源

最终进入模板系统的 define 来自多层合并：

| define 来源 | 常见示例 |
| --- | --- |
| 材质设置与纹理 | `ALPHA_MODE`、`HAS_MAP`、`MAP_UV` |
| 几何布局与几何特性 | `HAS_POSITION`、`HAS_NORMAL`、`HAS_UV`、`HAS_COLOR`、`HAS_MORPH_TARGETS`、`SUPPORT_SKINNING` |
| 场景状态 | `HAS_SHADOWS`、`USE_SSAO`、`USE_SSS`、`USE_SSR`、`DEBUG_VIEW_ALBEDO` |
| 单个渲染项状态 | `HAS_SKINNING`、`RECEIVE_SHADOWS` |
| 管线/Pass 状态 | `USE_CLUSTERED_SHADING`、`HDR`、`IN_TRANSPARENT_PASS`、`HAS_MRT_SSSS`、`ALPHA_TO_COVERAGE`、`SHADOW_PASS` |

这些 define 不是“实现细节噪音”，而是当前 Myth 着色器作者应该明确掌握的一部分正式接口。

## 3. `#[myth_material]`：高级材质的首选入口

`#[myth_material]` 是当前 Myth 自定义材质的首选高层 API。

### 3.1 宏会生成什么

对于一个声明式材质 struct，宏会自动生成：

1. 一个 GPU 可上传、std140 对齐的 uniform struct。
2. 内部 CPU buffer 与版本跟踪，用于自动触发管线缓存失效。
3. getter / setter / `with_xxx(...)` builder。
4. 纹理 slot 访问器和配置辅助方法。
5. `Default` 与 `from_uniforms(...)` 构造路径。
6. `MaterialTrait` 与 `RenderableMaterialTrait` 实现。
7. 自动材质绑定声明。
8. 基于纹理存在性和材质设置自动生成的 shader_define。

### 3.2 结构体级属性

| 属性 | 含义 |
| --- | --- |
| `shader = "name"` | 必填，逻辑 shader 名称 |
| `shader_src = WGSL_EXPR` | 内嵌材质 body，引擎自动补标准几何材质前导块 |
| `shader_template_src = WGSL_EXPR` | 内嵌完整模板源码，你拥有完整 WGSL 控制权 |
| `crate_path = "..."` | 覆盖宏内部使用的 `myth_resources` 路径 |

### 3.3 字段级属性

| 属性 | 含义 |
| --- | --- |
| `#[uniform]` | 生成 uniform 字段与访问器 |
| `#[uniform(default = "expr")]` | 同上，并设置默认值 |
| `#[uniform(hidden)]` | 进入 uniform struct，但不生成公开访问器 |
| `#[uniform(skip_builder)]` | 保留访问器，但跳过自动生成的 `with_xxx(...)` builder |
| `#[texture]` | 添加一个纹理 slot，并自动生成 WGSL 绑定与 define |
| `#[internal(...)]` | 保留 Rust 侧字段，不进入标准 uniform/texture 生成路径 |

### 3.4 一个最小的 body 模式示例

```rust
use myth::prelude::*;
use myth::resources::myth_material;

const HOLO_SHADER: &str = r#"
@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    let world_pos = u_model.world_matrix * vec4<f32>(in.position.xyz, 1.0);
    out.position = u_render_state.view_projection * world_pos;
    out.world_position = world_pos.xyz / world_pos.w;

    $$ if HAS_NORMAL is defined
    out.geometry_normal = normalize(in.normal.xyz);
    out.normal = normalize(u_model.normal_matrix * in.normal.xyz);
    $$ endif

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> FragmentOutput {
    let pulse = 0.5 + 0.5 * sin(u_render_state.time * u_material.speed);
    let color = u_material.base_color.rgb * (0.4 + pulse * 0.6);
    return pack_fragment_output(vec4<f32>(color, u_material.opacity));
}
"#;

#[myth_material(shader = "examples/holo", shader_src = HOLO_SHADER)]
pub struct HoloMaterial {
    #[uniform(default = "Vec4::new(0.1, 0.8, 1.2, 1.0)")]
    pub base_color: Vec4,

    #[uniform(default = "1.0")]
    pub opacity: f32,

    #[uniform(default = "2.0")]
    pub speed: f32,
}
```

仓库里的完整示例可以看 [examples/custom_material_hologram.rs](../examples/custom_material_hologram.rs) 和 [examples/custom_material_dissolve.rs](../examples/custom_material_dissolve.rs)。

### 3.5 宏会自动映射哪些 WGSL 名字

如果你有这样一个字段：

```rust
#[texture]
pub map: TextureSlot,
```

那么 Myth 会自动生成：

- 纹理绑定 `t_map`
- 采样器绑定 `s_map`
- `u_material` 中的 `map_transform`
- 纹理存在 define `HAS_MAP`
- UV 通道 define `MAP_UV`（当通道不是默认 0 时）

同理，每个 `#[uniform]` 字段都会成为 `u_material` 中同名字段。

宏生成的 `shader_defines()` 还会自动加入材质设置相关 define，例如 `ALPHA_MODE`，最后再调用 `extra_defines(...)`，给手写实现留下扩展余地。

### 3.6 什么时候用 `shader_src`，什么时候用 `shader_template_src`

优先用 `shader_src` 的场景：

- 你想留在标准网格材质管线里
- 你想直接使用 `VertexInput`、`VertexOutput`、`FragmentOutput`、`pack_fragment_output(...)`
- 你想直接访问自动生成的 bind group 声明与光照结构体
- 你只是想自定义材质逻辑，而不是重写整份模板骨架

使用 `shader_template_src` 的场景：

- 你要完全控制完整 WGSL 模板
- 你需要自己掌控 include 顺序、声明顺序与 entry-point 结构
- 你明确不希望使用引擎管理的几何材质前导块

完整示例可参考 [examples/custom_material_template_aurora_gate.rs](../examples/custom_material_template_aurora_gate.rs)。

## 4. 标准几何材质路径中，引擎会自动生成哪些 WGSL 接口

### 4.1 标准 bind group 分组

在标准几何材质路径里，`binding_code` 来自三个自动拼接的 bind group：

| Group | 常见变量名 | 来源 |
| --- | --- | --- |
| Group 0 | `u_render_state`、`u_environment`、`st_directional_lights`、`t_env_map`、`s_env_map`、`t_pmrem_map`、`s_pmrem_map`、`t_brdf_lut`、`s_brdf_lut` | RenderState + scene/global 绑定 |
| Group 1 | `u_material`、`t_<texture>`、`s_<texture>` | 材质绑定 |
| Group 2 | `u_model`、`u_morph_targets`、`st_morph_positions`、`st_morph_normals`、`st_morph_tangents`、`st_skins`、`st_prev_skins` | object / mesh / geometry / skeleton 绑定 |

并不是每个变量都会始终存在。例如 morph 和 skinning 相关绑定只会在当前 mesh 真正使用这些特性时才出现。

### 4.2 Geometry 自动驱动的输入与 define

`Geometry` 会同时驱动顶点输入布局和几何 define。

当前规则是：

- 每个 attribute 名字都会变成 `VertexInput` 里的字段名。
- 每个 attribute 名字也会生成一个 `HAS_<NAME>` define。
- morph 数据会按需生成 `HAS_MORPH_TARGETS`、`HAS_MORPH_NORMALS`、`HAS_MORPH_TANGENTS`。
- 同时存在 `joints` 和 `weights` 时，会生成 `SUPPORT_SKINNING`。

这意味着自定义几何 attribute 不需要额外注册表。只要你的几何里有一个叫 `foo` 的 attribute，shader 里就可以测试 `HAS_FOO` 并读取 `in.foo`。

### 4.3 Scene / Item / Pipeline 层 define

渲染器还会继续叠加场景与 pass 状态：

- 场景层：`HAS_SHADOWS`、`USE_SSAO`、`USE_SCREEN_SPACE_FEATURES`、`USE_SSS`、`USE_SSR`、debug-view 相关 define
- 单物体层：`HAS_SKINNING`、`RECEIVE_SHADOWS`
- 管线层：`USE_CLUSTERED_SHADING`、`HDR`、`IN_TRANSPARENT_PASS`、`HAS_MRT_SSSS`、`ALPHA_TO_COVERAGE`

也正因为如此，同一份 WGSL 模板可以适配不同渲染路径和功能组合，而不需要复制出很多近似 shader。

### 4.4 body 模式自带的输出类型和 helper

在 `shader_src` 的 body 模式下，引擎还会自动引入：

- `VertexOutput`
- `FragmentOutput`
- `pack_fragment_output(...)`

`VertexOutput` 已经包含常见的世界空间数据，以及按 `HAS_*` define 条件展开的材质贴图 UV varying。

如果你的材质声明了 `#[texture]` 字段，并希望使用标准的变换后 UV varying，请在顶点 shader 中包含：

```wgsl
{$ include 'mixins/uv_vertex' $}
```

这个 mixin 会基于 `u_material.*_transform` 和对应 UV set 填充 `out.map_uv`、`out.normal_map_uv` 等字段。

### 4.5 一个稳妥的 body 模式材质清单

对于一个要长期维护的自定义网格材质，我建议从这份清单起步：

1. 默认使用 `shader_src`。
2. 通用引擎数据从 `u_render_state`、`u_model`、`u_material` 读取。
3. 除非你明确要自己管 MRT 输出，否则统一使用 `pack_fragment_output(...)`。
4. 只要用了 `#[texture]` 字段，就考虑在顶点 shader 里 include `mixins/uv_vertex`。
5. 如果材质参与 alpha clipping 或希望兼容 depth prepass，保留 `opacity` 和 `alpha_test`。

## 5. 手写 `RenderableMaterialTrait`

虽然宏已经很强，但 Myth 仍然保留了底层材质接口。

手写实现适合这些场景：

- 你想完全控制 Rust 侧的存储模型
- 你需要绑定一些宏目前难以描述的特殊资源
- 你要用一套完全不同于字段推导的 define 生成逻辑
- 你不想要宏生成的访问器 / builder 体系

一个完整的手写实现至少需要提供：

- `shader_name()`
- 可选的 `shader_template()` 与 `shader_template_mode()`
- `version()`
- `shader_defines()`
- `settings()`
- `define_bindings(...)`
- `uniform_buffer()` 与 `with_uniform_bytes(...)`

实践上，只有当你能明确说明“宏表达不了什么”时，才建议走手写路径。

## 6. Template Pass 系统

Template Pass 是给那些“不自然属于 Material”的工作准备的：

- 全屏后处理
- utility compute
- 图内的实验性渲染/数据生成节点

### 6.1 Builder 阶段和 Graph 阶段是分开的

这个系统刻意分成两阶段。

Builder 阶段：

- 选择 shader 来源：`shader_template(...)` 或 `inline_shader_template(...)`
- 声明静态 bind-group layout
- 用 `shader_options(...)` 注入编译期 define / code block
- 构建可复用的 `TemplateFullscreenPass` 或 `TemplateComputePass`

Graph 阶段：

- 把 pass 插入当前帧的 RDG
- 绑定本帧具体的图资源、tracked 外部 buffer、sampler 等

这样做的好处是：管线编译与布局声明可以复用，而每一帧仍然能绑定不同的图资源。

### 6.2 Fullscreen 示例

声明阶段：

```rust
let post_pass = RenderPassBuilder::fullscreen("Custom Post FX Pipeline")
    .inline_shader_template(CUSTOM_POST_SHADER_NAME, CUSTOM_POST_SHADER_TEMPLATE)
    .bind_texture_2d(0, 0, wgpu::ShaderStages::FRAGMENT, true)
    .bind_sampler(0, 1, wgpu::ShaderStages::FRAGMENT, wgpu::SamplerBindingType::Filtering)
    .color_target(wgpu::ColorTargetState {
        format: HDR_TEXTURE_FORMAT,
        blend: Some(wgpu::BlendState::REPLACE),
        write_mask: wgpu::ColorWrites::ALL,
    })
    .build(&mut engine.renderer);
```

插入图时：

```rust
let node = post_pass.build_node(
    builder,
    "Custom Post FX Pass",
    out,
    RenderTargetOps::DontCare,
    Some("CustomPostFX BindGroup"),
    |bindings| {
        bindings.bind_texture(0, 0, scene_color);
        bindings.bind_common_sampler(0, 1, CommonSampler::LinearClamp);
    },
);
```

完整版本可参考 [examples/custom_post_fx.rs](../examples/custom_post_fx.rs)。

如果你希望 fullscreen pass 不是一次性后处理，而是一个可复用的功能模块，可以把编译后的 `TemplateFullscreenPass` 和它依赖的 tracked 资源一起封装进 helper。海洋示例展示了这条路径的两个版本：

- [examples/procedural_ocean.rs](../examples/procedural_ocean.rs) 直接用自定义海洋结果替换 `scene_color`。
- [examples/ocean_composite_scene.rs](../examples/ocean_composite_scene.rs) 同时绑定 `scene_color` 与 `scene_depth`，只在普通 3D 几何体背后的背景像素上填充海洋。

做这种 depth-aware 合成时，需要在声明阶段额外绑定深度纹理：

```rust
let composite_pass = RenderPassBuilder::fullscreen("Ocean Composite Pipeline")
    .inline_shader_template(OCEAN_SHADER_NAME, OCEAN_SHADER_TEMPLATE)
    .bind_uniform_buffer(0, 0, wgpu::ShaderStages::FRAGMENT)
    .bind_texture_2d(0, 1, wgpu::ShaderStages::FRAGMENT, true)
    .bind_sampler(0, 2, wgpu::ShaderStages::FRAGMENT, wgpu::SamplerBindingType::Filtering)
    .bind_depth_texture_2d(0, 3, wgpu::ShaderStages::FRAGMENT)
    .build(&mut engine.renderer);
```

### 6.3 Compute 示例

声明阶段：

```rust
let swarm_pass = ComputePassBuilder::new("GPU Particle Light Pipeline")
    .inline_shader_template(GPU_PARTICLE_LIGHT_SHADER_NAME, GPU_PARTICLE_LIGHT_SHADER_TEMPLATE)
    .shader_options(swarm_shader_options)
    .bind_uniform_buffer(0, 0, wgpu::ShaderStages::COMPUTE)
    .bind_storage_buffer(0, 1, wgpu::ShaderStages::COMPUTE, false)
    .bind_storage_buffer(0, 2, wgpu::ShaderStages::COMPUTE, false)
    .bind_storage_buffer(0, 3, wgpu::ShaderStages::COMPUTE, false)
    .build(&mut engine.renderer);
```

插入图时：

```rust
let node = swarm_pass.build_node(
    builder,
    "GPU Particle Light Pass",
    [GPU_LIGHT_COUNT.div_ceil(PARTICLE_LIGHT_WG_SIZE), 1, 1],
    Some("GPU Particle Light BG"),
    |bindings| {
        bindings.bind_tracked_buffer(0, 0, params_buffer);
        bindings.bind_buffer(0, 1, light_metadata);
        bindings.bind_buffer(0, 2, light_storage);
        bindings.bind_buffer(0, 3, indirect_count_buffer);
    },
);
```

完整流程可参考 [examples/gpu_driven_particle_lights.rs](../examples/gpu_driven_particle_lights.rs)。

### 6.4 Template Pass 的重要规则

请记住这几条：

1. bind group 索引必须从 0 开始并且连续。
2. inline 的 Template Pass shader 会被直接使用，不会先自动注册再回查。
3. `shader_template("name")` 走的是命名模板查找，因此注册模板覆盖在这里仍然有效。
4. Template Pass 不会拿到标准材质前导块；它的布局和 WGSL 契约就是你声明的那一套。

## 7. 命名模板覆盖能力

Myth 仍然保留了命名模板覆盖这一低级 escape hatch：

```rust
engine.renderer.register_shader_template(
    "my/custom/template",
    include_str!("shaders/my_custom_template.wgsl"),
);
```

这条 API 是给 `ShaderSource::File("my/custom/template")` 这种命名查找路径准备的。

它适合这些场景：

- 你想让多个 pass 复用同一个命名模板
- 你想有意覆盖某个命名模板路径
- 你明确就在 raw template 这一层工作

不要把它当成 `shader_src` 材质的前置步骤。对于 body 模式材质，内嵌源码已经会在创建管线时直接以 inline shader source 方式传入。

## 8. 实战建议与常见坑

1. 普通网格材质优先用 `shader_src`，这是最省样板、也最符合 Myth 标准管线的路径。
2. 只有在你真的需要完整模板控制权时，才用 `shader_template_src`。
3. 如果 `#[myth_material]` 类型带有 `#[texture]` 字段，并且它位于独立模块或示例里，请确保 `Mat3Uniform` 在作用域中，因为宏会为 UV 变换隐藏生成 `*_transform` uniform。
4. 若材质需要兼容 alpha clip 或 depth prepass，请保留 `opacity` 与 `alpha_test`。
5. Rust 字段名会直接变成 shader-facing 的 WGSL 标识符。字段重命名会同步影响 WGSL 名字。
6. 对于图内后处理和 compute 工作，请优先使用 Template Pass，而不要勉强把它们塞进 Material 模型里。

## 9. 参考示例

- [examples/custom_material_hologram.rs](../examples/custom_material_hologram.rs)
- [examples/custom_material_dissolve.rs](../examples/custom_material_dissolve.rs)
- [examples/custom_material_template_aurora_gate.rs](../examples/custom_material_template_aurora_gate.rs)
- [examples/custom_material_texture_flow.rs](../examples/custom_material_texture_flow.rs)
- [examples/custom_material_slope_blend.rs](../examples/custom_material_slope_blend.rs)
- [examples/custom_material_triplanar.rs](../examples/custom_material_triplanar.rs)
- [examples/custom_post_fx.rs](../examples/custom_post_fx.rs)
- [examples/procedural_ocean.rs](../examples/procedural_ocean.rs)
- [examples/ocean_composite_scene.rs](../examples/ocean_composite_scene.rs)
- [examples/gpu_driven_particle_lights.rs](../examples/gpu_driven_particle_lights.rs)

如果你不确定该从哪条扩展路径开始，优先从这些示例复制出一个最接近的案例，再逐步决定是否需要降到 raw template 或手写 trait 的层级。