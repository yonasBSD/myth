# Clustered Shading

Myth now uses clustered forward lighting for the scene-rendering passes that consume punctual lights: Opaque, Transparent, and BasicForward's SimpleForward path.

## Pipeline

1. `Cluster_Build_Pass`
   Builds one view-space AABB per cluster from the current camera projection and viewport.
2. `Cluster_Cull_Pass`
   Tests every punctual light against every cluster and writes a fixed-capacity light list per cluster.
3. Forward shading
   The fragment shader computes its cluster from screen-space position and view depth, fetches the cluster record, and only evaluates the light indices stored for that cluster.

## GPU Data

- `ClusteredLightingParams`
  Screen size, cluster grid dimensions, per-cluster light budget, and the logarithmic depth-slicing parameters used by both compute and fragment stages.
- `ClusterAabb`
  View-space min/max bounds for each cluster.
- `ClusterRecord`
  Offset/count pair that maps a cluster to its compact segment inside the global light-index buffer.
- Light-index buffer
  Flat `u32` array storing the visible light IDs for all clusters.

## Current Implementation Choices

- Fixed-capacity per-cluster segments are used instead of a global atomic append buffer.
  This avoids the worst atomic contention path and keeps the implementation deterministic for the first production rollout.
- Directional lights are injected into every cluster.
- Point lights use sphere-vs-AABB tests in view space.
- Spot lights currently reuse the same range-sphere approximation during culling.
  The lighting evaluation still uses the full spotlight cone, so this is conservative rather than incorrect.
- Cluster data is exposed through the existing screen/transient bind group used by scene forward passes.

## Limits

- The light-index buffer is clamped against `maxStorageBufferBindingSize`.
  If the requested per-cluster budget exceeds the device limit, Myth reduces the effective `max_lights_per_cluster` and logs a warning.
- The default grid is approximately `120x120` pixels per tile with `24` logarithmic depth slices.
- The current implementation targets Myth's reverse-Z perspective camera path.

## Validation

The clustered path is covered by:

- headless physical forward rendering
- headless phong forward rendering
- headless mixed multi-light scenes

Examples for manual inspection:

- `examples/clustered_lighting.rs`
- `examples/clustered_stress.rs`

## Extension Path

- Add a depth min/max reduction pass sourced from the prepass to reduce empty-depth overreach inside deep clusters.
- Upgrade spotlight culling from range-sphere to cone-vs-AABB.
- Add optional overflow metrics and spill-buffer support if content starts hitting the fixed per-cluster budget regularly.