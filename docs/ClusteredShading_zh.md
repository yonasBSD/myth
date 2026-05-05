# 集群渲染

Myth 现在在依赖 punctual lights 的前向场景通道中启用了 clustered forward lighting，包括 Opaque、Transparent，以及 BasicForward 路径下的 SimpleForward。

## 渲染流程

1. `Cluster_Build_Pass`
   根据当前相机投影矩阵和视口尺寸，为每个 cluster 构建 View Space AABB。
2. `Cluster_Cull_Pass`
   对每个 cluster 遍历场景光源，筛出可见光源并写入该 cluster 的光源索引列表。
3. 前向着色
   Fragment Shader 使用屏幕坐标和 View Depth 计算 cluster 索引，读取 cluster record，再只遍历该 cluster 对应的光源索引。

## 核心 GPU 数据

- `ClusteredLightingParams`
  保存屏幕尺寸、cluster 网格尺寸、每个 cluster 的光源预算，以及 compute/fragment 共用的对数深度切片参数。
- `ClusterAabb`
  每个 cluster 的 View Space 最小/最大边界。
- `ClusterRecord`
  `(offset, count)` 对，用来把 cluster 映射到全局光源索引缓冲的连续片段。
- 光源索引缓冲
  扁平化的 `u32` 数组，存储所有 cluster 的可见光源 ID。

## 当前实现取舍

- 第一版使用“每个 cluster 固定容量”的光源片段，而不是全局原子追加缓冲。
  这样可以避免高竞争 atomic 路径，并保持实现简单、稳定、可预测。
- 方向光会被注入到所有 cluster 中。
- 点光使用 View Space 下的 Sphere-vs-AABB 测试。
- SpotLight 在剔除阶段暂时复用 range sphere 近似。
  最终光照计算仍然使用完整的 spotlight 锥角，因此这是保守剔除，不会带来错误光照，只会让少量 cluster 多保留一些候选灯光。
- Cluster 数据通过现有的 screen/transient bind group 暴露给 Opaque / Transparent / SimpleForward。

## 限制与保护

- 光源索引缓冲会依据 `maxStorageBufferBindingSize` 自动截断。
  如果目标设备的单个 storage buffer 限制不足以容纳期望预算，Myth 会下调有效的 `max_lights_per_cluster` 并打印警告日志。
- 默认网格参数大约是 `120x120` 像素 tile，深度方向 `24` 个对数切片。
- 当前实现主要面向 Myth 默认的 reverse-Z 透视相机路径。

## 验证方式

当前 clustered 路径已经通过以下运行时验证：

- Physical 前向材质 headless 渲染
- Phong 前向材质 headless 渲染
- 方向光 + 点光混合的多光源场景 headless 渲染

可视化示例：

- `examples/clustered_lighting.rs`
- `examples/clustered_stress.rs`

## 后续扩展建议

- 结合 prepass 增加 cluster depth min/max 归约，减少深度方向跨度过大的无效保留。
- 将 SpotLight 剔除从 range sphere 升级为 cone-vs-AABB。
- 如果内容侧频繁触发固定容量上限，再增加 overflow metrics 或 spill buffer 方案。