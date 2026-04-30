#[cfg(target_arch = "wasm32")]
pub mod web {
    use wasm_bindgen::prelude::*;

    #[wasm_bindgen(inline_js = r#"
        export function emit_progress(message, percentage) {
            if (typeof window !== 'undefined' && typeof window.CustomEvent === 'function') {
                window.dispatchEvent(new CustomEvent('myth-loading-progress', {
                    detail: { message, percentage }
                }));
            }
        }

        export function emit_ready() {
            if (typeof window !== 'undefined' && typeof window.CustomEvent === 'function') {
                window.dispatchEvent(new CustomEvent('myth-scene-ready'));
            }
        }
    "#)]
    extern "C" {
        fn emit_progress(message: &str, percentage: f32);
        fn emit_ready();
    }

    #[inline(always)]
    pub fn update_loading_progress(message: &str, percentage: f32) {
        emit_progress(message, percentage);
    }

    #[inline(always)]
    pub fn notify_scene_ready() {
        emit_ready();
    }
}

#[cfg(not(target_arch = "wasm32"))]
pub mod web {
    #[inline(always)]
    #[allow(dead_code)]
    pub fn update_loading_progress(_message: &str, _percentage: f32) {}

    #[inline(always)]
    #[allow(dead_code)]
    pub fn notify_scene_ready() {}
}