# frozen_string_literal: true

require_relative "metaco/version"

begin
  require "metaco/metaco"
rescue LoadError
  # Extension not compiled - this is expected on non-macOS platforms
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
  end
end
