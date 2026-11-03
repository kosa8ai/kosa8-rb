# frozen_string_literal: true

require_relative "lib/kosa8/version"

Gem::Specification.new do |s|
  s.name = "kosa8"
  s.version = Kosa8::VERSION
  s.summary = "Ruby SDK for kosa8: microVM sandboxes for AI agents"
  s.description = "Typed client for the kosa8 daemon: sandboxes, run/exec streams, snapshots, fork, " \
                  "best-of-N explore and checkpoints shared with the kosa8 CLI. No dependencies."
  s.authors = ["kosa8"]
  s.homepage = "https://kosa8.com"
  s.license = "MIT"
  s.required_ruby_version = ">= 2.6"
  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  s.require_paths = ["lib"]
  s.metadata = { "source_code_uri" => "https://github.com/kosa8ai/kosa8-rb" }
end
