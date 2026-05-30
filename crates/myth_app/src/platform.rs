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

        export function emit_status(text) {
            if (typeof text !== 'string' || text.length === 0) {
                return;
            }

            if (typeof document !== 'undefined' && document.title !== text) {
                document.title = text;
            }

            if (typeof window === 'undefined') {
                return;
            }

            if (window.__mythRuntimeStatus === text) {
                return;
            }

            window.__mythRuntimeStatus = text;

            if (typeof window.CustomEvent === 'function') {
                window.dispatchEvent(new CustomEvent('myth-status-update', {
                    detail: { text }
                }));
            }
        }
    "#)]
    extern "C" {
        fn emit_progress(message: &str, percentage: f32);
        fn emit_ready();
        fn emit_status(text: &str);
    }

    #[inline(always)]
    pub fn update_loading_progress(message: &str, percentage: f32) {
        emit_progress(message, percentage);
    }

    #[inline(always)]
    pub fn notify_scene_ready() {
        emit_ready();
    }

    #[inline(always)]
    pub fn update_status_text(text: &str) {
        emit_status(text);
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

    #[inline(always)]
    #[allow(dead_code)]
    pub fn update_status_text(_text: &str) {}
}
