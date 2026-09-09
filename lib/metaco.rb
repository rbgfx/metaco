# frozen_string_literal: true

require_relative "metaco/version"

if RUBY_PLATFORM.include?("darwin")
  require "metaco/metaco"
else
  module Metaco
    def self.init
      raise LoadError, "Metaco is only available on macOS"
    end

    def self.window_create(_w, _h, _t)
      raise LoadError, "Metaco is only available on macOS"
    end

    def self.window_destroy(_handle)
      raise LoadError, "Metaco is only available on macOS"
    end

    def self.set_pixels(_handle, _data, _w, _h)
      raise LoadError, "Metaco is only available on macOS"
    end

    def self.present(_handle)
      raise LoadError, "Metaco is only available on macOS"
    end

    def self.poll_events(_handle)
      raise LoadError, "Metaco is only available on macOS"
    end

    def self.should_close?(_handle)
      raise LoadError, "Metaco is only available on macOS"
    end

    def self.metal_compute_available?(_handle)
      false
    end

    def self.has_compute_shader?(_handle)
      false
    end

    def self.compile_compute_shader(_handle, _source)
      raise LoadError, "Metaco is only available on macOS"
    end

    def self.dispatch_compute(_handle, _uniforms)
      raise LoadError, "Metaco is only available on macOS"
    end

    def self.present_compute(_handle)
      raise LoadError, "Metaco is only available on macOS"
    end
  end
end
