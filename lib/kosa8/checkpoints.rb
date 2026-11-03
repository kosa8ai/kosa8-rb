# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module Kosa8
  # pkg/checkpoint MaxPerSandbox.
  MAX_CHECKPOINTS_PER_SANDBOX = 10

  def self.validate_sandbox_name(name)
    if !name.is_a?(String) || name.empty? || name.start_with?(".") || name.include?("/") || name.include?("\\")
      raise CheckpointError, "invalid sandbox name #{name.inspect}"
    end

    name
  end

  # Keeps stacks in memory; nothing is shared with the CLI.
  class MemoryCheckpointStore
    def initialize
      @data = {}
      @mu = Mutex.new
    end

    def load
      @mu.synchronize { Marshal.load(Marshal.dump(@data)) }
    end

    # Runs the block on the stacks and saves what it leaves.
    def update
      @mu.synchronize do
        d = Marshal.load(Marshal.dump(@data))
        r = yield d
        @data = d
        r
      end
    end
  end

  # The store the kosa8 CLI uses: ~/.kosa8/checkpoints.json (0600, rewritten
  # atomically), locked with the same flock on checkpoints.json.lock, so
  # `kosa8 rewind` sees checkpoints taken here and the other way round.
  class FileCheckpointStore
    attr_reader :path, :lock_timeout

    # lock_timeout: seconds to wait for checkpoints.json.lock (10, as @kosa8/sdk).
    def initialize(path = nil, lock_timeout: 10)
      @path = path || File.join(Dir.home, ".kosa8", "checkpoints.json")
      @lock_timeout = lock_timeout
      @mu = Mutex.new
    end

    def load
      d = JSON.parse(File.read(@path))
      d.is_a?(Hash) ? d : {}
    rescue Errno::ENOENT, JSON::ParserError
      {} # a corrupt store must not make the sandbox unusable
    end

    def update
      @mu.synchronize do
        FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
        File.open("#{@path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          acquire(lock)
          d = load
          r = yield d
          tmp = "#{@path}.tmp"
          File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |f| f.write(JSON.pretty_generate(d)) }
          File.chmod(0o600, tmp)
          File.rename(tmp, @path)
          r
        end
      end
    end

    private

    def acquire(lock)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @lock_timeout
      until lock.flock(File::LOCK_EX | File::LOCK_NB)
        if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
          raise CheckpointError, "timed out after #{@lock_timeout}s waiting for #{@path}.lock; another kosa8 " \
                                 "process is holding it"
        end
        sleep 0.05
      end
    end
  end

  # The stack logic of pkg/checkpoint over any store. Records are hashes with
  # the CLI's JSON keys: id, sandbox, label, auto (omitted when false), created.
  class CheckpointBook
    def initialize(store)
      @store = store
    end

    def self.seq(id, sandbox)
      pre = "#{sandbox}-ckpt-"
      return 0 unless id.start_with?(pre)

      id[pre.length..-1][/\A\d+/].to_i
    end

    # The next id and the ids to evict to stay at the cap.
    def next_id(sandbox)
      Kosa8.validate_sandbox_name(sandbox)
      list = @store.load[sandbox] || []
      n = list.length + 1
      list.each { |c| v = self.class.seq(c["id"].to_s, sandbox); n = v + 1 if v >= n }
      over = list.length + 1 - MAX_CHECKPOINTS_PER_SANDBOX
      evict = over.positive? ? list.first(over).map { |c| c["id"] } : []
      ["#{sandbox}-ckpt-#{n}", evict]
    end

    def record(id, sandbox, label, evicted = [])
      Kosa8.validate_sandbox_name(sandbox)
      rec = { "id" => id, "sandbox" => sandbox, "label" => label.to_s,
              "created" => Time.now.utc.iso8601(9) }
      @store.update do |d|
        d[sandbox] = (d[sandbox] || []).reject { |c| evicted.include?(c["id"]) } + [rec]
      end
      rec
    end

    # Oldest first.
    def list(sandbox)
      (@store.load[sandbox] || []).each_with_index.sort_by { |c, i| [Kosa8.parse_time(c["created"]), i] }.map(&:first)
    end

    def latest(sandbox)
      l = list(sandbox)
      raise CheckpointError, "no checkpoints for #{sandbox.inspect} — take one with checkpoint or `kosa8 checkpoint #{sandbox}`" if l.empty?

      l.last
    end

    # By id or (case-insensitive) label, newest first.
    def resolve(sandbox, ref)
      list(sandbox).reverse.find { |c| c["id"] == ref || c["label"].to_s.casecmp(ref.to_s).zero? } ||
        raise(CheckpointError, "no checkpoint #{ref.inspect} for sandbox #{sandbox.inspect}")
    end

    # Drops everything after id; returns the dropped ids.
    def pop(sandbox, id)
      @store.update do |d|
        list = d[sandbox] || []
        i = list.index { |c| c["id"] == id }
        raise CheckpointError, "no checkpoint #{id.inspect} for sandbox #{sandbox.inspect}" if i.nil?

        d[sandbox] = list.first(i + 1)
        list[(i + 1)..-1].map { |c| c["id"] }
      end
    end

    # Forgets a sandbox's stack; returns its ids.
    def forget(sandbox)
      @store.update { |d| (d.delete(sandbox) || []).map { |c| c["id"] } }
    end
  end

  def self.parse_time(s)
    Time.iso8601(s.to_s) # handles the Go CLI's nanosecond timestamps
  rescue ArgumentError
    Time.at(0)
  end
end
