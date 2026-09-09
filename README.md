# metaco

A Ruby C extension providing native macOS window management and Metal GPU acceleration for graphics applications.

## Requirements

- macOS
- Ruby 3.1+
- Xcode Command Line Tools

## Installation

Add this line to your application's Gemfile:

```ruby
gem "metaco"
```

And then execute:

```bash
bundle install
```

Or install it yourself as:

```bash
gem install metaco
```

## Usage

### Basic Window

```ruby
require "metaco"

# Initialize Cocoa
Metaco.init

# Create a window
handle = Metaco.window_create(800, 600, "My Window")

# Main loop
until Metaco.should_close?(handle)
  # Create pixel buffer (RGBA format)
  width, height = 800, 600
  buffer = "\xFF\x00\x00\xFF" * (width * height)  # Red

  # Update pixels and present
  Metaco.set_pixels(handle, buffer, width, height)
  Metaco.present(handle)

  # Handle events
  events = Metaco.poll_events(handle)
  events.each do |event|
    case event[:type]
    when :key_press
      puts "Key pressed: #{event[:key]}"
    when :mouse_press
      puts "Mouse clicked at: #{event[:x]}, #{event[:y]}"
    end
  end
end

# Cleanup
Metaco.window_destroy(handle)
```

### Metal Compute Shaders

```ruby
require "metaco"

Metaco.init
handle = Metaco.window_create(800, 600, "Compute Shader")

# Check Metal availability
if Metaco.metal_compute_available?(handle)
  # Compile shader (MSL)
  shader = <<~MSL
    #include <metal_stdlib>
    using namespace metal;

    kernel void compute_shader(
        texture2d<float, access::write> output [[texture(0)]],
        constant float4 &uniforms [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]])
    {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        float2 uv = float2(gid) / float2(output.get_width(), output.get_height());
        output.write(float4(uv.x, uv.y, uniforms.x, 1.0), gid);
    }
  MSL

  Metaco.compile_compute_shader(handle, shader)

  until Metaco.should_close?(handle)
    # Dispatch with uniforms
    time = Time.now.to_f
    uniforms = [Math.sin(time) * 0.5 + 0.5, 0.0, 0.0, 1.0].pack("f4")
    Metaco.dispatch_compute(handle, uniforms)
    Metaco.present_compute(handle)
    Metaco.poll_events(handle)
  end
end

Metaco.window_destroy(handle)
```

## API Reference

### Window Management

| Method | Description |
|--------|-------------|
| `init` | Initialize Cocoa application |
| `window_create(width, height, title)` | Create a new window, returns a `Metaco::Window` handle |
| `window_destroy(handle)` | Close and release the window; repeated calls are safe |
| `should_close?(handle)` | Check if window should close |
| `poll_events(handle)` | Poll and return pending events |

### Rendering

| Method | Description |
|--------|-------------|
| `set_pixels(handle, buffer, width, height)` | Set pixel data (RGBA format) |
| `present(handle)` | Present the frame and wait for GPU completion |

### Compute Shaders

| Method | Description |
|--------|-------------|
| `metal_compute_available?(handle)` | Check if Metal compute is available |
| `compile_compute_shader(handle, msl_source)` | Compile MSL compute shader |
| `dispatch_compute(handle, uniforms)` | Execute compute shader and wait for GPU completion |
| `present_compute(handle)` | Present compute shader output and wait for GPU completion |
| `has_compute_shader?(handle)` | Check if shader is compiled |

### Event Types

- `:key_press` - Key pressed (`:key`, `:char`)
- `:key_release` - Key released (`:key`)
- `:mouse_press` - Mouse button pressed (`:x`, `:y`, `:button`)
- `:mouse_release` - Mouse button released (`:x`, `:y`, `:button`)
- `:mouse_move` - Mouse moved (`:x`, `:y`)

### API contracts

- Call `init` before creating windows. All native APIs must run on the process's main thread; worker-thread calls raise `ThreadError`. GPU completion waits release Ruby's GVL.
- Handles are opaque `Metaco::Window` objects, replacing the integer pointers returned by 0.1.0. Pass them unchanged to Metaco methods. A closed handle raises `ArgumentError` on operations other than `window_destroy`; unrelated objects raise `TypeError`.
- Release windows in an `ensure` block. GC also releases abandoned windows, scheduling AppKit cleanup on the main thread when necessary; `poll_events` services this queue.
- Width and height must be between 1 and 16,384. `set_pixels` requires the original window dimensions and at least `width * height * 4` bytes of row-major RGBA data, with unpremultiplied alpha. Extra trailing bytes are ignored. Invalid dimensions or short buffers raise `ArgumentError`.
- Titles and shader sources must contain valid UTF-8. Key event `:char` strings use UTF-8 and preserve embedded NUL characters. Mouse buttons are numbered 0 (left), 1 (right), and 2 (middle); dragging produces `:mouse_move` events.
- Compute shaders use the entry point `compute_shader`, output texture 0, and a uniform buffer at index 0. Uniforms may contain 0–256 bytes; remaining bytes are zeroed on every dispatch. Larger inputs raise `ArgumentError`. Shader uniform structures must fit within 256 bytes.
- Failed compilation preserves the previous shader and its resources. Dispatch and compute presentation require a compiled shader. GPU command failures raise `RuntimeError` after native resources have been cleaned up.
- Dispatch covers exactly the window's pixels. Threadgroup dimensions may vary by pipeline and image width; shaders must not assume a fixed group size. The example's bounds check also makes it safe with other dispatch implementations.
- Presentation is synchronous so pixel uploads cannot overwrite an in-flight frame. An occluded window may have no drawable, in which case presentation is skipped. Rendering resource allocation failures select the bitmap fallback; compute availability then returns `false`.
- On unsupported platforms both compute availability queries return `false`, and other APIs raise `LoadError`. On macOS, native extension loading errors retain their original diagnostics.

## Development

```bash
# Install dependencies
bundle install

# Compile native extension
bundle exec rake compile

# Run tests
bundle exec rake test

# Require actual GPU execution and validate Metal commands/shaders
METACO_REQUIRE_METAL=1 MTL_DEBUG_LAYER=1 MTL_SHADER_VALIDATION=1 bundle exec rake test
```

The test task includes a separate native test extension for GPU pixel readback, allocation and command failure injection, Unicode input, and GC/exception cleanup. These helpers are excluded from the gem. CI runs window and bitmap tests on macOS even when Metal is unavailable; only GPU-specific tests are omitted in that case. Set `METACO_SKIP_GUI=1` explicitly for a session without WindowServer. Argument and fallback tests still run.

The optional `run_metal` workflow-dispatch input runs the same suite with mandatory GPU execution on a self-hosted runner labeled `macOS` and `metal`. It requires a logged-in GUI session and a Metal device.

## License

The gem is available as open source under the terms of the [MIT License](LICENSE).
