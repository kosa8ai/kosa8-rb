# frozen_string_literal: true

# The thread-pool engine behind Cloud#fork_map and Kosa8::RL::Run#map: hand
# out forks of a base sandbox, run work in them, retry what can pass, and
# never leave a child behind (Ctrl-C included).
module Kosa8
  # One item of a fork_map: the +item+, what the block returned (+value+) or
  # raised (+error+), its +failure_class+ ("ok" on success), how many
  # +attempts+ it took, the +sandbox_id+ of its last fork and +ms+.
  ForkResult = Struct.new(:item, :value, :error, :failure_class, :attempts, :sandbox_id, :ms, keyword_init: true) do
    def ok?
      error.nil?
    end
  end

  # The map was stopped before this item ran.
  class CancelledError < Error
    def initialize(message = "cancelled before it ran")
      super(message, body: { "failure_class" => "error", "retryable" => false })
    end
  end

  # An item ran past the map's timeout_s; its sandbox was deleted.
  class ItemTimeoutError < TimeoutError
    def initialize(timeout_s)
      super("gave up after #{timeout_s} s; its sandbox was deleted",
            body: { "failure_class" => "timeout", "retryable" => false }, code: "timeout")
    end
  end

  module ForkMap
    # Children forked ahead of the workers in one call, at most.
    PREFORK_MAX = 100

    # A failed[] entry of a batch or fork answer as an exception.
    def self.failure_from_entry(entry)
      e = entry.is_a?(Hash) ? entry : {}
      ApiError.new((e["message"] || e["code"] || "not created").to_s, code: e["code"],
                                                                     body: e.merge("failure_class" => e["failure_class"] || "infra",
                                                                                   "retryable" => e.key?("retryable") ? e["retryable"] == true : true))
    end

    # Forks of +base+ (or sandboxes from make.call(arg)) for workers to take.
    # Every child it made and has not released is tracked, so #close deletes
    # them all, even mid-call.
    class ChildPool
      attr_reader :closed

      def initialize(cloud, base: nil, make: nil, labels: nil, run_id: nil, lease_s: nil)
        raise ArgumentError, "give a base sandbox to fork, or make: to create each sandbox" if base.nil? == make.nil?

        @cloud = cloud
        @base = base
        @make = make
        @labels = labels
        @run_id = run_id
        @lease_s = lease_s
        @ready = []
        @live = {}
        @lock = Mutex.new
        @closed = false
      end

      def prefork(n)
        return unless @make.nil?

        left = n
        while left.positive? && !@closed
          k = [left, PREFORK_MAX].min
          begin
            kids = fork(k, true)
          rescue StandardError
            return # each worker forks its own and sees the error
          end
          @lock.synchronize { @ready.concat(kids) }
          left -= k
        end
      end

      def take(arg = nil)
        raise CancelledError if @closed

        unless @make.nil?
          child = @make.call(arg)
          adopt([child])
          return child
        end
        child = @lock.synchronize { @ready.shift }
        child || fork(1, nil)[0]
      end

      # Delete a child taken from the pool (once; later calls do nothing).
      def release(child)
        mine = @lock.synchronize { !@live.delete(child.id).nil? }
        ForkMap.quiet_delete(child) if mine
      end

      # Stop tracking a child without deleting it (keep).
      def forget(child)
        @lock.synchronize { @live.delete(child.id) }
      end

      def live_ids
        @lock.synchronize { @live.keys }
      end

      # Delete every child not yet released (queued or in use): one drain
      # call for the lot, then one by one if that failed.
      def close
        kids = @lock.synchronize do
          @closed = true
          @ready.clear
          k = @live.values
          @live.clear
          k
        end
        return if kids.empty?

        begin
          @cloud.sandboxes.drain(ids: kids.map(&:id))
        rescue StandardError
          kids.each { |k| ForkMap.quiet_delete(k) }
        end
      end

      private

      def adopt(kids)
        closed = @lock.synchronize do
          kids.each { |k| @live[k.id] = k } unless @closed
          @closed
        end
        return unless closed

        kids.each { |k| ForkMap.quiet_delete(k) }
        raise CancelledError
      end

      def fork(n, partial_ok)
        kids = @base.fork(n, labels: @labels, run_id: @run_id, lease_s: @lease_s, partial_ok: partial_ok)
        adopt(kids)
        if kids.empty?
          failed = kids.respond_to?(:failed) ? kids.failed : []
          raise ForkMap.failure_from_entry(failed.first || { "message" => "the fork made no sandbox" })
        end
        kids.to_a
      end
    end

    def self.quiet_delete(box)
      box.delete
    rescue StandardError
      nil # gone already, or its lease deletes it
    end

    # block.call(*args); past timeout_s run on_timeout (delete the sandbox, so
    # the abandoned call fails fast) and raise ItemTimeoutError.
    def self.call_with_timeout(timeout_s, on_timeout, *args, &block)
      return block.call(*args) if timeout_s.nil?

      box = {}
      t = Thread.new do
        Thread.current.report_on_exception = false
        begin
          box[:value] = block.call(*args)
        rescue Exception => e # rubocop:disable Lint/RescueException (handed to the caller)
          box[:error] = e
        end
      end
      unless t.join(timeout_s)
        on_timeout.call
        raise ItemTimeoutError, timeout_s
      end
      raise box[:error] if box.key?(:error)

      box[:value]
    end

    # worker.call(i) for i in 0...n on +concurrency+ threads, results in
    # order. Whatever ends the wait (an exception, Interrupt) stops the
    # workers, and +cleanup+ always runs.
    def self.run_pool(n, concurrency, stop, cleanup, &worker)
      raise ArgumentError, "concurrency must be a whole number of at least 1" unless concurrency.is_a?(Integer) && concurrency >= 1

      results = Array.new(n)
      threads = []
      begin
        nxt = 0
        lock = Mutex.new
        [concurrency, n].min.times do
          threads << Thread.new do
            Thread.current.report_on_exception = false
            loop do
              i = lock.synchronize do
                j = nxt
                nxt += 1
                j
              end
              break if i >= n

              results[i] = worker.call(i)
            end
          end
        end
        threads.each(&:join)
      rescue Exception # rubocop:disable Lint/RescueException (Ctrl-C: stop, clean up, re-raise)
        stop[:stopped] = true
        cleanup.call
        threads.each(&:kill)
        raise
      end
      cleanup.call
      results
    end

    # Wait before the next attempt, in short steps so a stop is seen.
    def self.backoff(cloud, policy, exc, attempt, stop)
      wait = policy.delay(exc, attempt)
      cloud.sleeper.call(wait) unless stop[:stopped]
    end

    def self.run(cloud, base, items, concurrency: 16, retries: 2, timeout_s: nil, labels: nil, run_id: nil,
                 lease_s: nil, policy: nil, &block)
      raise ArgumentError, "fork_map needs a block (child, item)" if block.nil?
      raise ArgumentError, "retries must be a whole number of at least 0" unless retries.is_a?(Integer) && retries >= 0

      items = items.to_a
      policy ||= RetryPolicy.new(attempts: retries + 1)
      pool = ChildPool.new(cloud, base: base, labels: labels, run_id: run_id, lease_s: lease_s)
      stop = { stopped: false }
      worker = lambda do |i|
        res = ForkResult.new(item: items[i], attempts: 0, failure_class: "ok")
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        (1..(retries + 1)).each do |attempt|
          res.attempts = attempt
          if stop[:stopped]
            res.error = CancelledError.new
            res.failure_class = "error"
            break
          end
          child = nil
          begin
            child = pool.take
            res.sandbox_id = child.id
            c = child
            res.value = call_with_timeout(timeout_s, -> { pool.release(c) }, child, items[i], &block)
            res.error = nil
            res.failure_class = "ok"
            break
          rescue StandardError => e
            res.value = nil
            res.error = e
            fc, retryable = Kosa8.classify_failure(e)
            res.failure_class = fc
            break if !retryable || attempt > retries

            pool.release(child) unless child.nil?
            child = nil
            backoff(cloud, policy, e, attempt, stop)
          ensure
            pool.release(child) unless child.nil?
          end
        end
        res.ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).to_i
        res
      end
      begin
        pool.prefork([items.size, concurrency].min) unless items.empty?
      rescue Exception # rubocop:disable Lint/RescueException
        pool.close
        raise
      end
      run_pool(items.size, concurrency, stop, -> { pool.close }, &worker)
    end
  end
end
