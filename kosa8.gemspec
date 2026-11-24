# frozen_string_literal: true

require_relative "lib/kosa8/version"

Gem::Specification.new do |s|
  s.name = "kosa8"
  s.version = Kosa8::VERSION
  s.summary = "Zero Trust cybersecurity infrastructure for AI agents: the kosa8 Ruby SDK"
  s.description = "Zero Trust cybersecurity infrastructure for AI agents: each agent in its own microVM. Typed client for the kosa8 daemon: sandboxes, run/exec streams, snapshots, fork, " \
                  "best-of-N explore and checkpoints shared with the kosa8 CLI, plus the kosa8 Cloud API. No dependencies."
  s.authors = ["kosa8"]
  s.homepage = "https://kosa8.com"
  s.license = "MIT"
  s.required_ruby_version = ">= 2.6"
  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
  s.require_paths = ["lib"]
  s.metadata = {
    "homepage_uri" => "https://kosa8.com",
    "source_code_uri" => "https://github.com/kosa8ai/kosa8-rb",
    "changelog_uri" => "https://github.com/kosa8ai/kosa8-rb/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/kosa8ai/kosa8-rb/issues",
    "documentation_uri" => "https://docs.kosa8.com"
  }
end
