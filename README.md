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
| `window_create(width, height, title)` | Create a new window, returns handle |
| `window_destroy(handle)` | Destroy the window |
| `should_close?(handle)` | Check if window should close |
| `poll_events(handle)` | Poll and return pending events |

### Rendering

| Method | Description |
|--------|-------------|
| `set_pixels(handle, buffer, width, height)` | Set pixel data (RGBA format) |
| `present(handle)` | Present the frame |

### Compute Shaders

| Method | Description |
|--------|-------------|
| `metal_compute_available?(handle)` | Check if Metal compute is available |
| `compile_compute_shader(handle, msl_source)` | Compile MSL compute shader |
| `dispatch_compute(handle, uniforms)` | Execute compute shader |
| `present_compute(handle)` | Present compute shader output |
| `has_compute_shader?(handle)` | Check if shader is compiled |

### Event Types

- `:key_press` - Key pressed (`:key`, `:char`)
- `:key_release` - Key released (`:key`)
- `:mouse_press` - Mouse button pressed (`:x`, `:y`, `:button`)
- `:mouse_release` - Mouse button released (`:x`, `:y`, `:button`)
- `:mouse_move` - Mouse moved (`:x`, `:y`)

## Development

```bash
# Install dependencies
bundle install

# Compile native extension
bundle exec rake compile

# Run tests
bundle exec rake test
```

## License

The gem is available as open source under the terms of the [MIT License](LICENSE).
