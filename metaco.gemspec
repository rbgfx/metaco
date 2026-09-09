# frozen_string_literal: true

require_relative "lib/metaco/version"

Gem::Specification.new do |spec|
  spec.name = "metaco"
  spec.version = Metaco::VERSION
  spec.authors = ["Yudai Takada"]
  spec.email = ["t.yudai92@gmail.com"]

  spec.summary = "Native macOS Cocoa/Metal bridge for Ruby graphics applications"
  spec.description = "A Ruby C extension providing native macOS window management and Metal GPU acceleration for graphics applications."
  spec.homepage = "https://github.com/rbgfx/metaco"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"

  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (File.expand_path(f) == __FILE__) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end
  spec.require_paths = ["lib"]
  spec.extensions = ["ext/metaco/extconf.rb"]
end
