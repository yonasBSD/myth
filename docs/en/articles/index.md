# Articles

In-depth long-form writing on the internal design of Myth Engine. These articles cover the architecture, trade-offs, and measured data behind the engine's core subsystems — for developers who want to understand *why* things are designed the way they are.

## All Articles

### [Building an SSA-Based Declarative Render Graph](/en/blog/render-graph-design)

The full design journey of Myth's render graph compiler: from a linear hardcoded prototype, through a failed "blackboard" pattern, to a strict declarative RenderGraph built on **SSA (Static Single Assignment)**. Covers the compiler lifecycle, automatic memory aliasing, dead-pass elimination (DPE), plus ~1.6µs per-frame compilation benchmarks and auto-generated topology graphs.

---

> Looking for the concise, user-facing architecture overview? Read the [Render Graph](/en/architecture/render-graph) chapter.
