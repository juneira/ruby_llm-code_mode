# frozen_string_literal: true

require "rspec/core/rake_task"
require "bundler/gem_tasks"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

namespace :version do
  desc "Bump the gem version (major, minor or patch; default: patch)"
  task :bump, [:part] do |_task, args|
    part = args[:part].to_s
    unless %w[major minor patch].include?(part) || part.empty?
      abort "Unknown version part #{part.inspect}; use major, minor or patch"
    end

    file = "lib/ruby_llm/code_mode.rb"
    content = File.read(file)
    current = content[/VERSION = "(\d+\.\d+\.\d+)"/, 1]
    abort "VERSION constant not found in #{file}" unless current

    major, minor, patch = current.split(".").map(&:to_i)
    next_version = case part
                   when "major" then "#{major + 1}.0.0"
                   when "minor" then "#{major}.#{minor + 1}.0"
                   else "#{major}.#{minor}.#{patch + 1}"
                   end
    File.write(file, content.sub(/VERSION = "\d+\.\d+\.\d+"/, "VERSION = \"#{next_version}\""))
    puts "Bumped #{current} -> #{next_version} (#{file})"
    puts "Next: commit the change, then run `rake release`"
  end
end