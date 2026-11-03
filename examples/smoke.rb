# Smoke test against a real kosa8 daemon: create, pull, run, checkpoint, rewind, delete.
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "kosa8"

k = Kosa8::Client.new
puts "daemon #{k.version}"
name = "rbsdk-smoke"
t = Time.now
k.create_sandbox(name: name, egress: "deny")
puts format("created in %.1fs", Time.now - t)
sb = k.sandbox(name)
begin
  sb.pull("alpine:latest")
  r = sb.run("alpine:latest", ["sh", "-c", "echo hello from kosa8-rb; uname -r"])
  puts "run exit=#{r.exit_code} out=#{r.stdout.inspect}"
  puts "checkpoint #{sb.checkpoint(label: 'base')['checkpoint']['id']}"
  puts "rewind restore_ms #{sb.rewind['restore_ms']}"
  puts "egress policy #{sb.egress['policy']}"
ensure
  puts "delete #{sb.delete}"
end
