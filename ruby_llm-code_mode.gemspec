# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "ruby_llm-code_mode"
  spec.version = "0.1.0"
  spec.authors = ["Juneira"]
  spec.summary = "Secure sandboxed Ruby code execution tool for RubyLLM, powered by SecurityBox."
  spec.description = <<~DESC
    A RubyLLM tool that runs model-generated Ruby code inside a secure
    WebAssembly sandbox (SecurityBox), with explicit read-only and read-write
    folder mounts so agents can work on host project folders safely.
  DESC
  spec.license = "MIT"
  spec.required_ruby_version = ">= 4.0.0"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"

  spec.files = Dir.glob("lib/**/*") + Dir.glob(%w[LICENSE README.md])
  spec.require_paths = ["lib"]

  spec.add_dependency "ruby_llm", ">= 2.0"
  spec.add_dependency "security_box", ">= 0.6"

  spec.add_development_dependency "rspec", "~> 3.13"
end