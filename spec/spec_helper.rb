# frozen_string_literal: true

require "ruby_llm/code_mode"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.syntax = :expect
  end
  config.disable_monkey_patching!
  config.order = :random
  config.filter_run_when_matching :focus
end