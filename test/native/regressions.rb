# frozen_string_literal: true

require "metaco_test"
require "test/unit"

class TestNativeRegressions < Test::Unit::TestCase
  COLOR_SHADER = <<~MSL
    #include <metal_stdlib>
    using namespace metal;
    kernel void compute_shader(texture2d<float, access::write> output [[texture(0)]],
                               constant float4 &color [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
      output.write(color, gid);
    }
  MSL

  setup do
    if ENV["METACO_REQUIRE_METAL"] == "1"
      assert_not_equal "1", ENV["METACO_SKIP_GUI"], "Mandatory GPU tests require a GUI session"
    end
    omit "GUI explicitly disabled" if ENV["METACO_SKIP_GUI"] == "1"
    MetacoTest.failure = "none"
    Metaco.init
    @handles = []
  end

  teardown do
    MetacoTest.failure = "none"
    @handles&.each { |handle| Metaco.window_destroy(handle) }
  end

  def window(width = 17, height = 17, metal: true)
    handle = Metaco.window_create(width, height, "Native regression")
    @handles << handle
    if metal
      available = Metaco.metal_compute_available?(handle)
      assert_true available, "A working Metal device is required" if ENV["METACO_REQUIRE_METAL"] == "1"
      omit "Metal device unavailable" unless available
    end
    handle
  end

  def compile(handle)
    Metaco.compile_compute_shader(handle, COLOR_SHADER)
  end

  def assert_window_released
    pump = window(1, 1, metal: false)
    100.times do
      Metaco.poll_events(pump)
      break unless MetacoTest.watched_alive?
      sleep 0.01
    end
    assert_false MetacoTest.watched_alive?
  end

  test "normal and compute render passes preserve RGBA colors and orientation" do
    handle = window(2, 2)
    rgba = [255, 0, 0, 255, 0, 0, 255, 255, 0, 255, 0, 128, 64, 32, 16, 64].pack("C*")
    bgra = rgba.bytes.each_slice(4).flat_map { |r, g, b, a| [b, g, r, a] }.pack("C*")
    Metaco.set_pixels(handle, rgba, 2, 2)
    assert_equal rgba, MetacoTest.read_pixels(handle, false, false)
    assert_equal bgra, MetacoTest.read_pixels(handle, false, true)
    Metaco.present(handle)
    compile(handle)
    Metaco.dispatch_compute(handle, [1.0, 0.0, 0.0, 0.5].pack("f4"))
    assert_equal [0, 0, 255, 128].pack("C4") * 4, MetacoTest.read_pixels(handle, true, true)
    Metaco.present_compute(handle)
  end

  test "bitmap fallback validates both capacities and preserves RGBA including alpha" do
    MetacoTest.failure = "no_device"
    handle = window(2, 2, metal: false)
    assert_false Metaco.metal_compute_available?(handle)
    rgba = [255, 0, 0, 255, 0, 0, 255, 255, 0, 255, 0, 128, 64, 32, 16, 64].pack("C*")
    Metaco.set_pixels(handle, rgba, 2, 2)
    [[1, 1], [3, 3]].each do |w, h|
      assert_raise(ArgumentError) { Metaco.set_pixels(handle, "\0" * (w * h * 4), w, h) }
      assert_equal rgba, MetacoTest.read_pixels(handle, false, false)
    end
    assert_raise(ArgumentError) { Metaco.set_pixels(handle, "", 2, 2) }
    assert_equal rgba, MetacoTest.read_pixels(handle, false, false)
    Metaco.present(handle)
  end

  test "short and empty uniforms clear previous values and long uniforms are rejected" do
    handle = window
    compile(handle)
    Metaco.dispatch_compute(handle, [1.0, 1.0, 1.0, 1.0].pack("f4"))
    Metaco.dispatch_compute(handle, [1.0].pack("f"))
    assert_equal [255, 0, 0, 0].pack("C4") * 289, MetacoTest.read_pixels(handle, true, false)
    Metaco.dispatch_compute(handle, "")
    assert_equal "\0" * (289 * 4), MetacoTest.read_pixels(handle, true, false)
    Metaco.dispatch_compute(handle, [0.0, 1.0, 0.0, 1.0].pack("f4") + "\0" * 240)
    assert_raise(ArgumentError) { Metaco.dispatch_compute(handle, "\0" * 257) }
    assert_equal [0, 255, 0, 255].pack("C4") * 289, MetacoTest.read_pixels(handle, true, false)
  end

  test "all compute creation failures preserve the previous resources" do
    handle = window
    %w[compute_pipeline texture uniform].each do |failure|
      MetacoTest.inject_failure(handle, failure)
      assert_raise(RuntimeError) { compile(handle) }
      assert_false Metaco.has_compute_shader?(handle)
      MetacoTest.inject_failure(handle, "none")
    end
    compile(handle)
    %w[compute_pipeline texture uniform].each do |failure|
      MetacoTest.inject_failure(handle, failure)
      assert_raise(RuntimeError) { compile(handle) }
      assert_true Metaco.has_compute_shader?(handle)
      MetacoTest.inject_failure(handle, "none")
      Metaco.dispatch_compute(handle, [1.0, 0.0, 0.0, 1.0].pack("f4"))
      assert_equal [255, 0, 0, 255].pack("C4") * 289, MetacoTest.read_pixels(handle, true, false)
    end
  end

  test "initial Metal resource failures fall back to a usable bitmap" do
    window # First establish actual hardware availability.
    %w[queue texture render_pipeline].each do |failure|
      MetacoTest.failure = failure
      handle = window(2, 2, metal: false)
      assert_false Metaco.metal_compute_available?(handle)
      rgba = [255, 0, 0, 255].pack("C4") * 4
      Metaco.set_pixels(handle, rgba, 2, 2)
      assert_equal rgba, MetacoTest.read_pixels(handle, false, false)
    end
  end

  test "compute and presentation failures reach Ruby and leave the handle usable" do
    handle = window
    compile(handle)
    %w[command_buffer compute_encoder gpu].each do |failure|
      MetacoTest.inject_failure(handle, failure)
      error = assert_raise(RuntimeError) { Metaco.dispatch_compute(handle, "") }
      if failure == "gpu"
        assert_equal Encoding::UTF_8, error.message.encoding
        assert_equal 2048, error.message.length
        assert_match(/Injected GPU failure/, error.message)
      end
      MetacoTest.inject_failure(handle, "none")
      assert_nil Metaco.dispatch_compute(handle, "")
    end
    Metaco.set_pixels(handle, "\0" * (17 * 17 * 4), 17, 17)
    %w[command_buffer render_encoder gpu].each do |failure|
      MetacoTest.inject_failure(handle, failure)
      assert_raise(RuntimeError) { Metaco.present(handle) }
      assert_raise(RuntimeError) { Metaco.present_compute(handle) }
      MetacoTest.inject_failure(handle, "none")
      assert_nil Metaco.present(handle)
    end
  end

  test "dispatch invokes exactly one thread per pixel at awkward dimensions" do
    shader = COLOR_SHADER.sub("output.write(color, gid);", <<~MSL)
      uint2 last(output.get_width() - 1, output.get_height() - 1);
      if (gid.x == last.x && gid.y == last.y) {
        output.write(float4(grid.x == output.get_width() && grid.y == output.get_height(), 0, 0, 1), gid);
      }
    MSL
    shader = shader.sub("uint2 gid [[thread_position_in_grid]]", "uint2 gid [[thread_position_in_grid]], uint2 grid [[threads_per_grid]]")
    [[1, 1], [17, 17], [800, 600]].each do |w, h|
      handle = window(w, h)
      Metaco.compile_compute_shader(handle, shader)
      Metaco.dispatch_compute(handle, "")
      assert_equal [255, 0, 0, 255].pack("C4"), MetacoTest.read_pixels(handle, true, false).byteslice(-4, 4)
    end
  end

  test "GPU waits release the GVL and Ruby interrupts still release native ownership" do
    handle = window
    compile(handle)
    MetacoTest.watch_window(handle)
    MetacoTest.inject_failure(handle, "slow_gpu")
    progressed = false
    worker = Thread.new do
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
      until MetacoTest.gpu_waiting? || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        Thread.pass
      end
      progressed = MetacoTest.gpu_waiting?
      Thread.main.raise Interrupt, "test interrupt" if progressed
    end
    assert_raise(Interrupt) { Metaco.dispatch_compute(handle, "") }
    worker.join
    assert_true progressed
    MetacoTest.inject_failure(handle, "none")
    assert_nil Metaco.dispatch_compute(handle, "")
    Metaco.window_destroy(handle)
    assert_window_released
  ensure
    worker&.join
  end

  test "UTF-8 and NUL key text, all mouse buttons, and drags reach the event queue" do
    handle = window(64, 64, metal: false)
    Metaco.poll_events(handle)
    MetacoTest.post_events(handle)
    events = Metaco.poll_events(handle)
    key = events.find { |event| event[:type] == :key_press }
    assert_equal "あ🎮a\0b", key.fetch(:char)
    assert_equal Encoding::UTF_8, key.fetch(:char).encoding
    assert_equal %i[shift command], key.fetch(:modifiers)
    scroll = events.find { |event| event[:type] == :scroll }
    assert_kind_of Numeric, scroll.fetch(:dx)
    assert_kind_of Numeric, scroll.fetch(:dy)
    assert_include scroll.fetch(:modifiers), :shift
    assert_include events.map { |event| event[:type] }, :focus
    assert_include events.map { |event| event[:type] }, :blur
    %i[mouse_press mouse_release].each do |type|
      assert_equal [0, 1, 2], events.select { |event| event[:type] == type }.map { |event| event[:button] }
    end
    assert_operator events.count { |event| event[:type] == :mouse_move }, :>=, 4
  end

  test "event conversion exceptions preserve events and unwind ARC ownership" do
    handle = window(64, 64, metal: false)
    MetacoTest.watch_window(handle)
    MetacoTest.post_events(handle)
    MetacoTest.failure = "event"
    10.times { assert_raise(RuntimeError) { Metaco.poll_events(handle) } }
    MetacoTest.failure = "none"
    assert_equal "あ🎮a\0b", Metaco.poll_events(handle).find { |event| event[:type] == :key_press }.fetch(:char)
    Metaco.window_destroy(handle)
    assert_window_released
  end

  def abandon_window
    handle = Metaco.window_create(1, 1, "GC")
    MetacoTest.watch_window(handle)
    nil
  end

  test "GC releases abandoned windows even when collection runs on a worker" do
    abandon_window
    Thread.new { 3.times { GC.start } }.join
    # The main queue performs AppKit cleanup for collections on other threads.
    assert_window_released
  end
end
