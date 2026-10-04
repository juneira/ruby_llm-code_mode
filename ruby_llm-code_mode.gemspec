# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "ruby_llm-code_mode"
  spec.version = File.read("lib/ruby_llm/code_mode.rb")[/VERSION = "([0-9]+\.[0-9]+\.[0-9]+)"/, 1]
  raise "Version constant not found in lib/ruby_llm/code_mode.rb" unless spec.version
  spec.authors = ["Juneira"]
  spec.summary = "Secure sandboxed Ruby code execution tool for RubyLLM, powered by SecurityBox."
  spec.description = <<~DESC
    A RubyLLM tool that runs model-generated Ruby code inside a secure
    WebAssembly sandbox (SecurityBox), with explicit read-only and read-write
    folder mounts so agents can work on host project folders safely.
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.homepage = "https://github.com/juneira/ruby_llm-code_mode"
  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/juneira/ruby_llm-code_mode"
  spec.metadata["bug_tracker_uri"] = "https://github.com/juneira/ruby_llm-code_mode/issues"
  spec.metadata["changelog_uri"] = "https://github.com/juneira/ruby_llm-code_mode/releases"

  spec.files = Dir.glob("lib/**/*") + Dir.glob(%w[LICENSE README.md])
  spec.require_paths = ["lib"]

  spec.add_dependency "ruby_llm", ">= 2.0"
  spec.add_dependency "security_box", ">= 0.6"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "rake", "~> 13.2"
end