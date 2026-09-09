# frozen_string_literal: true

require "test_helper"
require "open3"
require "rbconfig"

class TestSafety < Test::Unit::TestCase
  OPERATIONS = {
    window_destroy: [], should_close?: [], poll_events: [], present: [],
    metal_compute_available?: [], has_compute_shader?: [], present_compute: [],
    set_pixels: ["\0" * 4, 1, 1], compile_compute_shader: [""], dispatch_compute: [""]
  }.freeze

  test "invalid handles are rejected without accessing Cocoa" do
    omit unless RUBY_PLATFORM.include?("darwin")
    [nil, 0, 1, -1, 2**128, Object.new].each do |handle|
      OPERATIONS.each do |method, args|
        assert_raise(TypeError, "#{method}(#{handle.inspect})") { Metaco.public_send(method, handle, *args) }
      end
    end
    assert_raise(TypeError) { Metaco::Window.allocate }
  end

  test "invalid dimensions are rejected without creating a window" do
    omit unless RUBY_PLATFORM.include?("darwin")
    [[0, 1], [1, 0], [-1, 1], [1, -1], [65536, 65536], [16385, 1], [1, 16385]].each do |w, h|
      assert_raise(ArgumentError) { Metaco.window_create(w, h, "Invalid") }
      assert_raise(ArgumentError) { Metaco.set_pixels(nil, "", w, h) }
    end
    assert_raise(RangeError) { Metaco.window_create(2**128, 1, "Invalid") }
  end

  test "AppKit operations reject worker threads" do
    omit unless RUBY_PLATFORM.include?("darwin")
    Thread.new do
      assert_raise(ThreadError) { Metaco.init }
      assert_raise(ThreadError) { Metaco.window_create(1, 1, "Invalid") }
      OPERATIONS.each do |method, args|
        assert_raise(ThreadError) { Metaco.public_send(method, nil, *args) }
      end
    end.value
  end

  test "unsupported platforms expose the entire API" do
    script = <<~'CODE'
      Object.send(:remove_const, :RUBY_PLATFORM)
      RUBY_PLATFORM = "x86_64-linux"
      require "metaco"
      abort unless Metaco.metal_compute_available?(nil) == false
      abort unless Metaco.has_compute_shader?(nil) == false
      methods = {init: [], window_create: [1, 1, ""], window_destroy: [nil],
                 set_pixels: [nil, "", 1, 1], present: [nil], poll_events: [nil],
                 should_close?: [nil], compile_compute_shader: [nil, ""],
                 dispatch_compute: [nil, ""], present_compute: [nil]}
      methods.each do |name, args|
        begin
          Metaco.public_send(name, *args)
          abort "#{name} did not raise"
        rescue LoadError => error
          abort unless error.message == "Metaco is only available on macOS"
        end
      end
    CODE
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script)
    assert_predicate status, :success?, output
  end

  test "macOS extension load errors retain their original diagnostic" do
    script = <<~'CODE'
      Object.send(:remove_const, :RUBY_PLATFORM)
      RUBY_PLATFORM = "arm64-darwin"
      module Kernel
        alias original_require require
        def require(name)
          raise LoadError, "incompatible native ABI" if name == "metaco/metaco"
          original_require(name)
        end
      end
      begin
        require "metaco"
        abort "load unexpectedly succeeded"
      rescue LoadError => error
        abort error.message unless error.message == "incompatible native ABI"
      end
    CODE
    output, status = Open3.capture2e(RbConfig.ruby, "-Ilib", "-e", script)
    assert_predicate status, :success?, output
  end
end
