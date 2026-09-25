# Changelog

## Unreleased

## 0.3.0 - 2026-09-25

- Resize windows and report logical and framebuffer dimensions correctly on Retina displays, including resize events.
- Use images as Metal input textures and read pixels from native windows.
- Release graphics resources when windows close or are collected without interrupting pending Metal commands.

## 0.2.0 - 2026-09-09

- Replace integer window handles with `Metaco::Window` objects that release resources automatically; reject closed windows, invalid sizes, and calls from the wrong thread.
- Handle UTF-8/NUL keyboard input, right and middle mouse buttons, and drag events; report unsupported-platform errors consistently.
- Preserve RGBA output and keep Ruby threads responsive while waiting for Metal operations; report GPU and allocation errors.
- Keep the previous shader if recompilation fails, reject oversized uniforms, and run compute shaders over the requested image dimensions.
- Read pixels from native windows.

## 0.1.0 - 2026-01-02

- Initial release.
