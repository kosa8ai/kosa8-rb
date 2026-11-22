# frozen_string_literal: true

require "json"
require "uri"

# RL training on kosa8 Cloud: leases that die with the trainer, runs that
# record rollouts (shown on app.kosa8.com, RL runs), and Run#map, one
# training step over forks with a sealed grader.
module Kosa8
  module RL
    # Default lease: a sandbox is deleted this long after the last heartbeat.
    DEFAULT_LEASE_S = 600
    # Rows per POST /v1/rl/runs/{id}/rollouts.
    MAX_ROWS_PER_CALL = 500
    # Failure classes masked by default: the sandbox or the platform failed,
    # not the policy, so the rollout must not train as reward 0. "error" is
    # your own solve raising (a harness bug). Add "timeout" to mask timeouts.
    DEFAULT_MASK = %w[infra quota error].freeze
    MASKABLE = %w[ok exit_nonzero timeout infra quota client error].freeze
    STDOUT_TAIL = 64 * 1024
    ROW_STDOUT_TAIL = 4096
    META_MAX = 8192

    # Keeps leased sandboxes alive while the trainer is, and deletes them
    # when it stops. A thread sends a heartbeat every +interval_s+ (default a
    # third of +lease_s+) for the sandboxes picked by run_id:, labels: or
    # ids:. On #close (and at exit) the thread stops and, with drain: true,
    # every matching sandbox is deleted. If the process is killed outright
    # the heartbeats stop and kosa8 Cloud deletes them lease_s later.
    class Lease
      attr_reader :beats, :last_error, :drained, :lease_s, :interval_s

      def initialize(cloud, run_id: nil, labels: nil, ids: nil, lease_s: DEFAULT_LEASE_S, interval_s: nil, drain: true,
                     on_tick: nil)
        raise ArgumentError, "a lease needs run_id:, labels: or ids: (which sandboxes)" if run_id.nil? && labels.nil? && ids.nil?

        Cloud.check_lease(lease_s)
        @cloud = cloud
        @selector = { run_id: run_id, labels: labels, ids: ids }
        @lease_s = lease_s
        @interval_s = interval_s.nil? ? [5.0, lease_s / 3.0].max : interval_s.to_f
        @drain = drain
        @on_tick = on_tick
        @beats = 0
        @last_error = nil
        @drained = nil
        @lock = Mutex.new
        @cv = ConditionVariable.new
        @stopped = false
        @closed = false
        @thread = nil
      end

      def start
        return self unless @thread.nil?

        @thread = Thread.new { loop_beats }
        @thread.report_on_exception = false
        lease = self
        at_exit { lease.close }
        self
      end

      # One heartbeat (and the tick) now.
      def beat
        @beats += 1 if @cloud.sandboxes.heartbeat(**@selector).is_a?(Integer)
      rescue StandardError => e
        @last_error = e
      ensure
        tick
      end

      # Stop heartbeating, run the last tick, and drain (drain: true). Safe to call twice.
      def close
        @lock.synchronize do
          return if @closed

          @closed = true
          @stopped = true
          @cv.broadcast
        end
        @thread&.join(5)
        tick
        return unless @drain

        begin
          @drained = @cloud.sandboxes.drain(**@selector)
        rescue StandardError => e
          @last_error = e
        end
      end

      private

      def tick
        @on_tick&.call
      rescue StandardError => e
        @last_error = e
      end

      def loop_beats
        loop do
          @lock.synchronize do
            @cv.wait(@lock, @interval_s) unless @stopped
          end
          break if @stopped

          beat
        end
      end
    end

    # One rollout. +masked+ means leave it out of the gradient (the failure
    # was not the policy's); then +reward+ is nil, never 0.
    RolloutResult = Struct.new(:task, :group, :index, :step, :reward, :failure_class, :masked, :metrics, :output,
                               :exit_code, :stdout, :stderr, :error, :attempts, :duration_ms, :sandbox_id,
                               :grader_id, :tokens, :cost_usd, :recorded, :meta, keyword_init: true) do
      def ok?
        %w[ok exit_nonzero].include?(failure_class) && !masked
      end

      # The row POST /v1/rl/runs/{id}/rollouts takes.
      def to_row
        m = (meta || {}).dup
        m["metrics"] = metrics if metrics && !metrics.empty?
        m["masked"] = true if masked
        m["error"] = error.to_s[0, 2000] if error
        m["attempts"] = attempts if attempts.to_i > 1
        # The server keeps the classes it knows; the SDK's own "error" (solve
        # raised) is recorded as "client", with the error in meta.
        fc = failure_class == "error" ? "client" : failure_class
        m["sdk_failure_class"] = "error" if failure_class == "error"
        row = { "step" => step, "group" => group.to_s, "index" => index, "sandbox_id" => sandbox_id,
                "reward" => reward, "failure_class" => fc, "exit" => exit_code, "duration_ms" => duration_ms,
                "meta" => m.empty? ? nil : RL.fit_meta(m), "stdout_tail" => (stdout || "")[-ROW_STDOUT_TAIL..-1] || stdout,
                "tokens" => tokens, "cost_usd" => cost_usd }
        row.reject { |_, v| v.nil? }
      end
    end

    # The results of a map, in input order (task-major, group_size per task).
    class Rollouts < Array
      # Each reward, nil where masked.
      def rewards
        map(&:reward)
      end

      # true where the rollout should train (not masked).
      def mask
        map { |r| !r.masked }
      end

      def mean_reward
        vals = map(&:reward).compact
        vals.empty? ? nil : vals.sum.to_f / vals.size
      end

      def by_class
        each_with_object(Hash.new(0)) { |r, h| h[r.failure_class] += 1 }
      end

      # The rollouts of each task together, for group-relative advantages (GRPO).
      def groups
        group_by(&:group).sort_by { |k, _| k }.map { |_, v| v }
      end
    end

    # Drop the largest meta values until it fits in +limit+ bytes as JSON.
    def self.fit_meta(meta, limit = META_MAX)
      m = meta.dup
      while JSON.generate(m).bytesize > limit && !m.empty?
        k = m.max_by { |_, v| JSON.generate(v).bytesize }[0]
        m.delete(k)
        m["truncated"] = true
      end
      m
    end

    # The hidden grader files a task carries: task["files"] (or "hidden_files").
    def self.task_files(task)
      return nil unless task.is_a?(Hash)

      %w[files hidden_files].each do |k|
        v = task[k] || task[k.to_sym]
        return v if v.is_a?(Hash)
      end
      nil
    end

    def self.task_id(task)
      return nil unless task.is_a?(Hash)

      %w[id task_id instance_id].each do |k|
        v = task[k] || task[k.to_sym]
        return v unless v.nil?
      end
      nil
    end

    # A grade that answered 200 but whose command did not finish on a
    # retryable failure: raised so the retry loop grades again (a new
    # Idempotency-Key, since a replay would give the same answer).
    class GradeDidNotFinish < Error
      attr_reader :grade

      def initialize(grade)
        super(grade.message || grade.error || "the grader did not finish",
              body: { "failure_class" => grade.failure_class, "retryable" => true })
        @grade = grade
      end
    end

    # One RL training run on kosa8 Cloud.
    #
    #   Kosa8::RL::Run.open(cloud, "my-grpo-run") do |run|
    #     base = cloud.sandboxes.create(template: "python")
    #     results = run.map(base, tasks, grade_cmd: ["python", "/grader/test.py"]) do |box, task|
    #       box.exec(["python", "solve.py", task["prompt"]])
    #     end
    #   end
    #
    # Starting it creates the run (or attaches to run_id:) and starts a Lease:
    # every sandbox this cloud makes while the run is open is labelled
    # kosa8.run=<id> and leased for lease_s, heartbeats keep them alive, and
    # finishing records what is left, deletes the run's sandboxes
    # (drain_on_exit) and marks the run finished or failed.
    class Run
      attr_reader :cloud, :name, :id, :project, :config, :lease_s, :recorded, :status, :info, :lease

      def self.open(cloud, name = nil, **kw)
        run = new(cloud, name, **kw).start
        return run unless block_given?

        begin
          r = yield run
        rescue Exception # rubocop:disable Lint/RescueException (Ctrl-C too: drain, then re-raise)
          run.finish("failed")
          raise
        end
        run.finish("finished")
        r
      end

      # A Run for an existing run (to keep recording after a restart).
      def self.attach(cloud, run_id, **kw)
        new(cloud, nil, run_id: run_id, **kw)
      end

      # The org's runs, newest first, each with a short summary.
      def self.list(cloud, project: nil, status: nil, name: nil, limit: nil)
        q = [["project", project], ["status", status], ["name", name], ["limit", limit]].reject { |_, v| v.nil? }
        r = cloud.request("GET", "/v1/rl/runs" + (q.empty? ? "" : "?#{URI.encode_www_form(q.map { |k, v| [k, v.to_s] })}"))
        r.is_a?(Hash) ? (r["runs"] || []) : []
      end

      def initialize(cloud, name = nil, run_id: nil, project: nil, config: nil, lease_s: DEFAULT_LEASE_S,
                     drain_on_exit: true, flush_every: 100, heartbeat_s: nil)
        raise ArgumentError, "give the run a name, or run_id: to attach to one" if (name.nil? || name.to_s.empty?) && run_id.nil?
        unless flush_every.is_a?(Integer) && flush_every.between?(1, MAX_ROWS_PER_CALL)
          raise ArgumentError, "flush_every must be from 1 to #{MAX_ROWS_PER_CALL}"
        end

        Cloud.check_lease(lease_s)
        @cloud = cloud
        @name = name
        @id = run_id
        @project = project
        @config = config
        @lease_s = lease_s
        @drain_on_exit = drain_on_exit
        @flush_every = flush_every
        @heartbeat_s = heartbeat_s
        @info = {}
        @recorded = 0
        @status = nil
        @buf = []
        @buf_lock = Mutex.new
        @flush_lock = Mutex.new
        @lease = nil
        @prev_defaults = nil
        @step = 0
        @open = false
      end

      def inspect
        "#<Kosa8::RL::Run id=#{@id.inspect} name=#{@name.inspect}>"
      end

      def open?
        @open
      end

      # Create (or attach to) the run and start its lease.
      def start
        return self if @open

        if @id.nil?
          body = { "name" => @name.to_s }
          body["project"] = @project.to_s unless @project.nil?
          body["config"] = @config unless @config.nil?
          @info = run_of(@cloud.request("POST", "/v1/rl/runs", body))
          @id = @info["id"]
          raise Error, "kosa8 Cloud answered no run id" if @id.nil?
        end
        @status = "running"
        @prev_defaults = @cloud.run_defaults
        @cloud.run_defaults = { "run_id" => @id, "lease_s" => @lease_s }
        @lease = Lease.new(@cloud, run_id: @id, lease_s: @lease_s, drain: @drain_on_exit, interval_s: @heartbeat_s,
                                   on_tick: -> { tick })
        @lease.start
        @open = true
        self
      end

      # Record what is buffered, drain the run's sandboxes (drain_on_exit)
      # and mark the run finished (or failed). Safe to call twice.
      def finish(status = "finished")
        raise ArgumentError, "status is finished or failed" unless %w[finished failed].include?(status)
        return unless @open

        @open = false
        lease = @lease
        @lease = nil
        lease ? lease.close : tick
        @cloud.run_defaults = @prev_defaults
        begin
          update(status: status)
        rescue StandardError => e
          warn "kosa8: could not mark run #{@id} #{status}: #{e.message}"
        end
        @status = status
      end

      # Buffer one rollout or many (a RolloutResult or a Hash with step,
      # group, index, reward, failure_class, exit, duration_ms, tokens,
      # cost_usd, meta, stdout_tail). They are sent in batches of
      # flush_every (at most 500 a call), every heartbeat, and at finish.
      def record(rollouts, flush: nil)
        list = rollouts.is_a?(Hash) || rollouts.is_a?(RolloutResult) ? [rollouts] : rollouts.to_a
        rows = list.map { |r| r.is_a?(RolloutResult) ? r.to_row : r.map { |k, v| [k.to_s, v] }.to_h }
        full = @buf_lock.synchronize do
          @buf.concat(rows)
          @buf.size >= @flush_every
        end
        self.flush if flush || (flush.nil? && full)
        nil
      end

      # Send every buffered rollout now; returns how many were recorded. On
      # an error the unsent rows stay buffered and the error is raised.
      def flush
        sent = 0
        @flush_lock.synchronize do
          loop do
            chunk = @buf_lock.synchronize { @buf.shift(MAX_ROWS_PER_CALL) }
            return sent if chunk.empty?

            begin
              r = @cloud.request("POST", path("/rollouts"), { "rollouts" => chunk })
            rescue Exception # rubocop:disable Lint/RescueException
              @buf_lock.synchronize { @buf.unshift(*chunk) }
              raise
            end
            n = r.is_a?(Hash) && r["recorded"].is_a?(Integer) ? r["recorded"] : chunk.size
            sent += n
            @recorded += n
          end
        end
      end

      # Rollouts buffered, not yet sent.
      def pending
        @buf_lock.synchronize { @buf.size }
      end

      # The run with its summary (rewards, failure classes, live sandboxes,
      # cost) and recommendations.
      def summary
        r = @cloud.request("GET", path)
        @info = run_of(r) unless run_of(r).empty?
        r
      end

      def update(status: nil, name: nil)
        body = {}
        body["status"] = status unless status.nil?
        body["name"] = name unless name.nil?
        raise ArgumentError, "give status: or name:" if body.empty?

        i = run_of(@cloud.request("PATCH", path, body))
        @info = i unless i.empty?
        @info
      end

      # One page of recorded rollouts: {"rollouts" => [...], "next_cursor" => ...}.
      def rollouts(step: nil, failure_class: nil, min_reward: nil, max_reward: nil, sandbox_id: nil, limit: nil,
                   cursor: nil)
        q = [["step", step], ["failure_class", failure_class], ["min_reward", min_reward], ["max_reward", max_reward],
             ["sandbox_id", sandbox_id], ["limit", limit], ["cursor", cursor]].reject { |_, v| v.nil? }
        @cloud.request("GET", path("/rollouts" + (q.empty? ? "" : "?#{URI.encode_www_form(q.map { |k, v| [k, v.to_s] })}")))
      end

      # Every rollout as JSON lines (binary String); written to +file+ when given.
      def export(file = nil)
        data = @cloud.request_bytes("GET", path("/export?format=jsonl"), raw: true)
        File.binwrite(file, data) unless file.nil?
        data
      end

      # Delete the run's sandboxes now (the run stays open).
      def drain
        @cloud.sandboxes.drain(run_id: @id)
      end

      # One training step: the block (sandbox, task) for every task
      # (group_size samples each, e.g. GRPO's G), +concurrency+ at a time.
      #
      # For each rollout: fork +base+ (a CloudSandbox; or a Hash of create
      # options, or a Proc(task) returning a sandbox), run the block in it,
      # grade it in a sealed fork with grade_cmd: and the task's hidden files
      # (task["files"], or files: a Hash or Proc(task)), record it on the run,
      # delete the sandbox. Without grade_cmd:, reward: Proc(sandbox, task,
      # output) or the block's own return (a number, or {"reward" => x})
      # is the reward.
      #
      # Infra failures and rate limits are retried +retries+ times on a fresh
      # sandbox with backoff and jitter (a failed grade is retried alone
      # first). What still fails in +mask+ comes back masked with reward nil,
      # never 0. timeout_s: caps the block. step: defaults to this run's
      # count of maps. Results in task order: Rollouts.
      def map(base, tasks, grade_cmd: nil, files: nil, grade_timeout_s: nil, grade_env: nil, reward: nil,
              concurrency: 16, group_size: 1, step: nil, retries: 2, timeout_s: nil, mask: DEFAULT_MASK,
              keep: false, meta: nil, &solve)
        raise ArgumentError, "the run is not open: use Run.open(...) or run.start" unless @open
        raise ArgumentError, "map needs a block (sandbox, task)" if solve.nil?
        raise ArgumentError, "group_size must be a whole number of at least 1" unless group_size.is_a?(Integer) && group_size >= 1
        raise ArgumentError, "retries must be a whole number of at least 0" unless retries.is_a?(Integer) && retries >= 0

        mask = mask.map(&:to_s)
        unknown = mask - MASKABLE
        raise ArgumentError, "unknown failure classes in mask: #{unknown.join(', ')}" unless unknown.empty?

        if step.nil?
          step = @step
          @step += 1
        end
        tasks = tasks.to_a
        n = tasks.size * group_size
        policy = RetryPolicy.new(attempts: retries + 1)
        pool = if base.is_a?(CloudSandbox)
                 ForkMap::ChildPool.new(@cloud, base: base, run_id: @id, lease_s: @lease_s)
               else
                 ForkMap::ChildPool.new(@cloud, make: maker(base))
               end
        stop = { stopped: false }
        files_for = lambda do |task|
          next files.call(task) if files.respond_to?(:call)
          next files unless files.nil?

          RL.task_files(task)
        end
        worker = lambda do |i|
          ti, g = i.divmod(group_size)
          task = tasks[ti]
          res = RolloutResult.new(task: task, group: ti, index: g, step: step, failure_class: "ok", masked: false,
                                  metrics: {}, stdout: "", stderr: "", attempts: 0, recorded: false, meta: {})
          tid = RL.task_id(task)
          res.meta["task"] = tid unless tid.nil?
          t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          out = nil
          (1..(retries + 1)).each do |attempt|
            res.attempts = attempt
            if stop[:stopped]
              res.failure_class = "error"
              res.error = "cancelled before it ran"
              break
            end
            child = nil
            begin
              child = pool.take(task)
              res.sandbox_id = child.id
              c = child
              out = ForkMap.call_with_timeout(timeout_s, -> { pool.release(c) }, child, task, &solve)
              res.output = out
              res.failure_class = "ok"
              res.error = nil
              gave = RL.from_output(res, out)
              if !grade_cmd.nil?
                info = { "group" => res.group, "index" => res.index, "step" => res.step }
                info["meta"] = res.meta.dup unless res.meta.empty?
                gc = child
                gr = begin
                  Kosa8.with_retry(policy, sleeper: ->(s) { @cloud.sleeper.call(s) unless stop[:stopped] }) do
                    r = gc.grade(grade_cmd, files: files_for.call(task), timeout_s: grade_timeout_s, env: grade_env,
                                            run_id: @id, rollout: info)
                    raise GradeDidNotFinish, r if r.reward.nil? && r.retryable

                    r
                  end
                rescue GradeDidNotFinish => e
                  e.grade # still not finished: masked below
                end
                RL.apply_grade(res, gr)
              elsif !reward.nil?
                raise TypeError, "reward: must return a number or {\"reward\" => x}" unless RL.from_output(res, reward.call(child, task, out))
              elsif !gave
                raise ArgumentError, "no reward: pass grade_cmd: (a sealed grader), reward: ->(sandbox, task, output) { }, " \
                                     "or return a number or {\"reward\" => x} from the block"
              end
              break
            rescue StandardError => e
              fc, retryable = Kosa8.classify_failure(e)
              res.failure_class = fc
              res.error = "#{e.class}: #{e.message}"
              res.reward = nil
              break if !retryable || attempt > retries

              pool.release(child) unless child.nil?
              child = nil
              ForkMap.backoff(@cloud, policy, e, attempt, stop)
            ensure
              unless child.nil?
                if keep && res.failure_class != "infra"
                  pool.forget(child)
                else
                  pool.release(child)
                end
              end
            end
          end
          res.duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).to_i
          res.meta.update((meta.call(task, out) || {}).map { |k, v| [k.to_s, v] }.to_h) unless meta.nil?
          res.masked = mask.include?(res.failure_class)
          res.reward = nil if res.masked
          unless res.recorded
            begin
              record(res)
            rescue StandardError
              nil # recording never fails a rollout
            end
          end
          res
        end
        begin
          pool.prefork([n, concurrency].min) if n.positive?
        rescue Exception # rubocop:disable Lint/RescueException
          pool.close
          raise
        end
        Rollouts.new(ForkMap.run_pool(n, concurrency, stop, -> { pool.close }, &worker))
      end

      private

      def tick
        flush
      rescue StandardError => e
        warn "kosa8: recording rollouts of run #{@id} failed, will retry: #{e.message}"
      end

      def path(suffix = "")
        raise ArgumentError, "the run has not started: use Run.open(...) or run.start" if @id.nil?

        "/v1/rl/runs/#{Kosa8.enc(@id)}#{suffix}"
      end

      def run_of(answer)
        return answer["run"] if answer.is_a?(Hash) && answer["run"].is_a?(Hash)

        answer.is_a?(Hash) ? answer : {}
      end

      # How to make each rollout's sandbox when base is not a sandbox to fork.
      def maker(base)
        return ->(task) { base.call(task) } if base.respond_to?(:call)
        raise ArgumentError, "base is a CloudSandbox to fork, a Hash of create options, or a Proc(task)" unless base.is_a?(Hash)

        opts = base.map { |k, v| [k.to_sym, v] }.to_h
        ->(_task) { @cloud.sandboxes.create(**opts.merge(run_id: @id, lease_s: @lease_s)) }
      end
    end

    # Take reward/metrics/tokens/meta from what solve returned; true if it gave a reward.
    def self.from_output(res, out)
      return false if out == true || out == false
      if out.is_a?(Numeric)
        res.reward = out.to_f
        return true
      end
      return false unless out.is_a?(Hash)

      h = out.map { |k, v| [k.to_s, v] }.to_h
      res.tokens = h["tokens"] if h["tokens"].is_a?(Integer)
      res.cost_usd = h["cost_usd"].to_f if h["cost_usd"].is_a?(Numeric)
      res.meta.update(h["meta"].map { |k, v| [k.to_s, v] }.to_h) if h["meta"].is_a?(Hash)
      r = h["reward"]
      return false unless r.is_a?(Numeric)

      res.reward = r.to_f
      res.metrics = h["metrics"] if h["metrics"].is_a?(Hash)
      true
    end

    def self.apply_grade(res, g)
      res.reward = g.reward
      res.metrics = g.metrics
      res.exit_code = g.exit_code
      res.stdout = g.stdout[-STDOUT_TAIL..-1] || g.stdout
      res.stderr = g.stderr[-STDOUT_TAIL..-1] || g.stderr
      res.failure_class = g.failure_class
      res.grader_id = g.grader_id
      res.error = "grader: #{g.error}: #{g.message}".sub(/:\s*\z/, "") if g.reward.nil? && g.error
      # kosa8 Cloud recorded it (source "grade") when given a run: never twice.
      res.recorded = g.recorded == true
    end
  end
end
