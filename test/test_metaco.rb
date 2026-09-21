# frozen_string_literal: true

require "test_helper"

class TestMetaco < Test::Unit::TestCase
  def self.gui_available?
    return false if ENV["METACO_SKIP_GUI"] == "1"
    return false unless RUBY_PLATFORM.include?("darwin")

    true
  end

  sub_test_case "VERSION" do
    test "is defined" do
      assert_not_nil Metaco::VERSION
    end

    test "is a string" do
      assert_kind_of String, Metaco::VERSION
    end

    test "follows semantic versioning format" do
      assert_match(/\A\d+\.\d+\.\d+/, Metaco::VERSION)
    end
  end

  sub_test_case "module structure" do
    test "Metaco module is defined" do
      assert_const_defined Object, :Metaco
    end

    test "Metaco is a module" do
      assert_kind_of Module, Metaco
    end
  end

  sub_test_case "window methods" do
    test "init method is defined" do
      assert_respond_to Metaco, :init
    end

    test "window_create method is defined" do
      assert_respond_to Metaco, :window_create
    end

    test "window_destroy method is defined" do
      assert_respond_to Metaco, :window_destroy
    end

    test "set_pixels method is defined" do
      assert_respond_to Metaco, :set_pixels
    end

    test "present method is defined" do
      assert_respond_to Metaco, :present
    end

    test "poll_events method is defined" do
      assert_respond_to Metaco, :poll_events
    end

    test "should_close? method is defined" do
      assert_respond_to Metaco, :should_close?
    end

    test "readback and size methods are defined" do
      assert_respond_to Metaco, :read_pixels
      assert_respond_to Metaco, :window_size
      assert_respond_to Metaco, :framebuffer_size
      if RUBY_PLATFORM.include?("darwin")
        assert_raise(ArgumentError) { Metaco.read_pixels(Object.new, source: :unknown) }
      end
    end
  end

  sub_test_case "compute shader methods" do
    test "metal_compute_available? method is defined" do
      assert_respond_to Metaco, :metal_compute_available?
    end

    test "compile_compute_shader method is defined" do
      assert_respond_to Metaco, :compile_compute_shader
    end

    test "dispatch_compute method is defined" do
      assert_respond_to Metaco, :dispatch_compute
    end

    test "present_compute method is defined" do
      assert_respond_to Metaco, :present_compute
    end

    test "has_compute_shader? method is defined" do
      assert_respond_to Metaco, :has_compute_shader?
    end
  end

  sub_test_case "initialization" do
    test "init returns nil" do
      omit unless TestMetaco.gui_available?
      assert_nil Metaco.init
    end
  end

  sub_test_case "window lifecycle" do
    setup do
      omit unless TestMetaco.gui_available?
      Metaco.init
    end

    test "window_create returns a handle" do
      handle = Metaco.window_create(320, 240, "Test")
      assert_kind_of Metaco::Window, handle
      Metaco.window_destroy(handle)
    end

    test "window_destroy returns nil" do
      handle = Metaco.window_create(320, 240, "Test")
      assert_nil Metaco.window_destroy(handle)
    end

    test "closed handles are safe and cannot refer to a later window" do
      handle = Metaco.window_create(1, 1, "Closed")
      Metaco.window_destroy(handle)
      replacement = Metaco.window_create(1, 1, "Replacement")
      assert_nil Metaco.window_destroy(handle)
      {
        should_close?: [], poll_events: [], present: [], metal_compute_available?: [],
        has_compute_shader?: [], present_compute: [], set_pixels: ["\0" * 4, 1, 1],
        compile_compute_shader: [""], dispatch_compute: [""]
      }.each do |method, args|
        assert_raise(ArgumentError) { Metaco.public_send(method, handle, *args) }
      end
      assert_false Metaco.should_close?(replacement)
    ensure
      Metaco.window_destroy(replacement) if replacement
    end

    test "should_close? returns false for new window" do
      handle = Metaco.window_create(320, 240, "Test")
      assert_false Metaco.should_close?(handle)
      Metaco.window_destroy(handle)
    end

    test "poll_events returns an array" do
      handle = Metaco.window_create(320, 240, "Test")
      events = Metaco.poll_events(handle)
      assert_kind_of Array, events
      Metaco.window_destroy(handle)
    end

    test "metal_compute_available? returns boolean" do
      handle = Metaco.window_create(320, 240, "Test")
      result = Metaco.metal_compute_available?(handle)
      assert_boolean result
      Metaco.window_destroy(handle)
    end

    test "has_compute_shader? returns false initially" do
      handle = Metaco.window_create(320, 240, "Test")
      assert_false Metaco.has_compute_shader?(handle)
      Metaco.window_destroy(handle)
    end
  end

  sub_test_case "pixel operations" do
    setup do
      omit unless TestMetaco.gui_available?
      Metaco.init
      @handle = Metaco.window_create(320, 240, "Test")
    end

    teardown do
      if @handle
        Metaco.window_destroy(@handle)
      end
    end

    test "set_pixels accepts valid buffer" do
      width = 320
      height = 240
      buffer = "\x00" * (width * height * 4)
      assert_nil Metaco.set_pixels(@handle, buffer, width, height)
    end

    test "set_pixels raises error for small buffer" do
      width = 320
      height = 240
      buffer = "\x00" * 100
      assert_raise(ArgumentError) do
        Metaco.set_pixels(@handle, buffer, width, height)
      end
    end

    test "set_pixels rejects dimensions that differ from the window" do
      [[1, 1], [640, 480], [240, 320]].each do |w, h|
        assert_raise(ArgumentError) { Metaco.set_pixels(@handle, "\0" * (w * h * 4), w, h) }
      end
    end

    test "present returns nil" do
      width = 320
      height = 240
      buffer = "\x00" * (width * height * 4)
      Metaco.set_pixels(@handle, buffer, width, height)
      assert_nil Metaco.present(@handle)
    end
  end

  sub_test_case "argument validation" do
    setup do
      omit unless TestMetaco.gui_available?
      Metaco.init
    end

    test "window_create requires integer width" do
      assert_raise(TypeError) do
        Metaco.window_create("invalid", 240, "Test")
      end
    end

    test "window_create requires integer height" do
      assert_raise(TypeError) do
        Metaco.window_create(320, "invalid", "Test")
      end
    end

    test "window_create requires string title" do
      assert_raise(TypeError) do
        Metaco.window_create(320, 240, 123)
      end
    end

    test "set_pixels requires string buffer" do
      handle = Metaco.window_create(320, 240, "Test")
      assert_raise(TypeError) do
        Metaco.set_pixels(handle, 123, 320, 240)
      end
      Metaco.window_destroy(handle)
    end
  end

  sub_test_case "window edge cases" do
    setup do
      omit unless TestMetaco.gui_available?
      Metaco.init
    end

    test "window with empty title" do
      handle = Metaco.window_create(320, 240, "")
      assert_kind_of Metaco::Window, handle
      Metaco.window_destroy(handle)
    end

    test "window with Japanese title" do
      handle = Metaco.window_create(320, 240, "テストウィンドウ")
      assert_kind_of Metaco::Window, handle
      Metaco.window_destroy(handle)
    end

    test "window with emoji title" do
      handle = Metaco.window_create(320, 240, "Test 🎮")
      assert_kind_of Metaco::Window, handle
      Metaco.window_destroy(handle)
    end

    test "small window size" do
      handle = Metaco.window_create(1, 1, "Tiny")
      assert_kind_of Metaco::Window, handle
      Metaco.window_destroy(handle)
    end

    test "large window size" do
      handle = Metaco.window_create(1920, 1080, "Large")
      assert_kind_of Metaco::Window, handle
      Metaco.window_destroy(handle)
    end
  end

  sub_test_case "multiple windows" do
    setup do
      omit unless TestMetaco.gui_available?
      Metaco.init
      @handles = []
    end

    teardown do
      return unless @handles

      @handles.each do |handle|
        Metaco.window_destroy(handle)
      end
    end

    test "create multiple windows" do
      3.times do |i|
        handle = Metaco.window_create(320, 240, "Window #{i}")
        assert_kind_of Metaco::Window, handle
        @handles << handle
      end
      assert_equal 3, @handles.size
    end

    test "each window has unique handle" do
      3.times do |i|
        @handles << Metaco.window_create(320, 240, "Window #{i}")
      end
      assert_equal @handles.uniq.size, @handles.size
    end

    test "windows are independent" do
      @handles << Metaco.window_create(320, 240, "Window 1")
      @handles << Metaco.window_create(320, 240, "Window 2")

      assert_false Metaco.should_close?(@handles[0])
      assert_false Metaco.should_close?(@handles[1])
    end
  end

  sub_test_case "pixel buffer patterns" do
    setup do
      omit unless TestMetaco.gui_available?
      Metaco.init
      @width = 64
      @height = 64
      @handle = Metaco.window_create(@width, @height, "Pixel Test")
    end

    teardown do
      Metaco.window_destroy(@handle) if @handle
    end

    test "solid color buffer" do
      buffer = "\xFF\x00\x00\xFF" * (@width * @height)
      assert_nil Metaco.set_pixels(@handle, buffer, @width, @height)
    end

    test "gradient buffer" do
      buffer = String.new(capacity: @width * @height * 4)
      @height.times do |y|
        @width.times do |x|
          r = (x * 255 / @width) & 0xFF
          g = (y * 255 / @height) & 0xFF
          buffer << [r, g, 128, 255].pack("C4")
        end
      end
      assert_nil Metaco.set_pixels(@handle, buffer, @width, @height)
    end

    test "binary buffer encoding" do
      buffer = "\x00\x00\x00\xFF" * (@width * @height)
      buffer.force_encoding(Encoding::BINARY)
      assert_nil Metaco.set_pixels(@handle, buffer, @width, @height)
    end

    test "exact buffer size required" do
      exact_size = @width * @height * 4
      buffer = "\x00" * exact_size
      assert_nil Metaco.set_pixels(@handle, buffer, @width, @height)
    end
  end

  sub_test_case "compute shader" do
    VALID_SHADER = <<~MSL
      #include <metal_stdlib>
      using namespace metal;

      kernel void compute_shader(
          texture2d<float, access::write> output [[texture(0)]],
          constant float4 &uniforms [[buffer(0)]],
          uint2 gid [[thread_position_in_grid]])
      {
          float2 uv = float2(gid) / float2(output.get_width(), output.get_height());
          output.write(float4(uv.x, uv.y, 0.5, 1.0), gid);
      }
    MSL

    INVALID_SHADER = "this is not valid MSL code"

    setup do
      omit unless TestMetaco.gui_available?
      Metaco.init
      @handle = Metaco.window_create(320, 240, "Compute Test")
    end

    teardown do
      Metaco.window_destroy(@handle) if @handle
    end

    test "compile valid shader" do
      omit unless Metaco.metal_compute_available?(@handle)
      assert_true Metaco.compile_compute_shader(@handle, VALID_SHADER)
    end

    test "has_compute_shader? returns true after compile" do
      omit unless Metaco.metal_compute_available?(@handle)
      Metaco.compile_compute_shader(@handle, VALID_SHADER)
      assert_true Metaco.has_compute_shader?(@handle)
    end

    test "compile invalid shader raises error" do
      omit unless Metaco.metal_compute_available?(@handle)
      assert_raise(RuntimeError) do
        Metaco.compile_compute_shader(@handle, INVALID_SHADER)
      end
    end

    test "failed recompilation preserves the working shader" do
      omit unless Metaco.metal_compute_available?(@handle)
      Metaco.compile_compute_shader(@handle, VALID_SHADER)
      [INVALID_SHADER, VALID_SHADER.sub("compute_shader", "different_name")].each do |source|
        assert_raise(RuntimeError) { Metaco.compile_compute_shader(@handle, source) }
        assert_true Metaco.has_compute_shader?(@handle)
        assert_nil Metaco.dispatch_compute(@handle, "")
      end
    end

    test "uniform buffers accept up to 256 bytes and reject truncation" do
      omit unless Metaco.metal_compute_available?(@handle)
      Metaco.compile_compute_shader(@handle, VALID_SHADER)
      [0, 4, 256].each { |length| assert_nil Metaco.dispatch_compute(@handle, "\0" * length) }
      assert_raise(ArgumentError) { Metaco.dispatch_compute(@handle, "\0" * 257) }
    end

    test "dispatch_compute with uniforms" do
      omit unless Metaco.metal_compute_available?(@handle)
      Metaco.compile_compute_shader(@handle, VALID_SHADER)
      uniforms = [1.0, 0.0, 0.0, 1.0].pack("f4")
      assert_nil Metaco.dispatch_compute(@handle, uniforms)
    end

    test "present_compute after dispatch" do
      omit unless Metaco.metal_compute_available?(@handle)
      Metaco.compile_compute_shader(@handle, VALID_SHADER)
      uniforms = [1.0, 0.0, 0.0, 1.0].pack("f4")
      Metaco.dispatch_compute(@handle, uniforms)
      assert_nil Metaco.present_compute(@handle)
    end

    test "dispatch without compile raises error" do
      omit unless Metaco.metal_compute_available?(@handle)
      uniforms = [1.0, 0.0, 0.0, 1.0].pack("f4")
      assert_raise(RuntimeError) do
        Metaco.dispatch_compute(@handle, uniforms)
      end
    end
  end

  sub_test_case "event structure" do
    setup do
      omit unless TestMetaco.gui_available?
      Metaco.init
      @handle = Metaco.window_create(320, 240, "Event Test")
    end

    teardown do
      Metaco.window_destroy(@handle) if @handle
    end

    test "poll_events returns empty array when no events" do
      events = Metaco.poll_events(@handle)
      assert_kind_of Array, events
    end

    test "multiple poll_events calls are safe" do
      10.times do
        events = Metaco.poll_events(@handle)
        assert_kind_of Array, events
      end
    end
  end

  sub_test_case "rapid operations" do
    setup do
      omit unless TestMetaco.gui_available?
      Metaco.init
    end

    test "rapid window create and destroy" do
      10.times do
        handle = Metaco.window_create(100, 100, "Rapid")
        Metaco.window_destroy(handle)
      end
    end

    test "rapid pixel updates" do
      handle = Metaco.window_create(64, 64, "Rapid Pixels")
      buffer = "\xFF\x00\x00\xFF" * (64 * 64)
      10.times do
        Metaco.set_pixels(handle, buffer, 64, 64)
        Metaco.present(handle)
      end
      Metaco.window_destroy(handle)
    end

    test "rapid poll_events" do
      handle = Metaco.window_create(100, 100, "Rapid Events")
      100.times do
        Metaco.poll_events(handle)
      end
      Metaco.window_destroy(handle)
    end
  end
end
