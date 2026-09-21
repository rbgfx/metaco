# Changelog

## Unreleased

- Add resizable windows, logical and framebuffer size reporting, Retina-aware dimensions, resize events, and resize-safe pixel/compute resources.
- Release closed windows promptly when explicitly destroyed or collected.

## 0.2.0 - 2026-09-09

- Replace integer window pointers with GC-managed `Metaco::Window` handles. Validate closed handles, main-thread access, dimensions, and pixel buffer capacity.
- Preserve Ruby exception cleanup, UTF-8/NUL key input, and right/middle mouse and drag events. Complete the unsupported-platform API without hiding macOS load errors.
- Preserve RGBA colors through a Metal render pass, synchronize GPU work without holding the GVL, propagate GPU errors, and validate all rendering/compute allocations.
- Keep the previous shader on recompilation failure; reject uniforms over 256 bytes and zero unused bytes. Dispatch exactly the image dimensions within pipeline limits.
- Add native pixel readback and fault-injection regressions; run GUI tests in macOS CI and support mandatory Metal validation on a GPU runner.

## 0.1.0 - 2026-01-02

- Initial release.
