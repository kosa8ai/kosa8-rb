# frozen_string_literal: true

module Kosa8
  # The outcome of a run, exec or attach.
  ExecResult = Struct.new(:exit_code, :stdout, :stderr, keyword_init: true) do
    def ok?
      exit_code.zero?
    end
  end

  ExploreBranch = Struct.new(:name, :variant, :exit, :output, :error, :duration_ms, keyword_init: true)
  ExploreResult = Struct.new(:parent, :branches, :winner, :removed, keyword_init: true)

  TRANSIENT = /connection refused|EOF|connection reset|broken pipe|no such file or directory|stream ended|ECONNREFUSED|ECONNRESET|unreachable/i.freeze

  # Typed client for the kosa8 native API (/kosa8/v1) over the daemon's unix
  # socket, or a remote worker via KOSA8_HOST / KOSA8_TOKEN.
  #
  #   k = Kosa8::Client.new
  #   k.create_sandbox(name: "demo", egress: "deny")
  #   k.pull_into_sandbox("demo", "alpine:latest")
  #   puts k.run("demo", "alpine:latest", ["echo", "hi"]).stdout
  class Client
    include Toolbox

    attr_reader :transport, :checkpoints

    def initialize(socket_path: nil, host: nil, token: nil, insecure: false, actor: "tool", agent_token: nil,
                   headers: {}, timeout: nil, checkpoint_store: nil, env: ENV)
      @transport = Transport.new(socket_path: socket_path, host: host, token: token, insecure: insecure, actor: actor,
                                 agent_token: agent_token, headers: headers, timeout: timeout, env: env)
      @checkpoints = CheckpointBook.new(checkpoint_store || FileCheckpointStore.new)
      @stdin_sent = {}
      @stdin_mu = Mutex.new
    end

    # --- daemon ---------------------------------------------------------------

    # GET /kosa8/v1/health: daemon status and version.
    def health
      @transport.json("GET", "/kosa8/v1/health")
    end

    def version
      health["version"]
    end

    # POST /kosa8/v1/pull: pull an image into the host engine.
    def pull(ref, approval: nil)
      @transport.json("POST", "/kosa8/v1/pull", body: { ref: ref }, approval: approval)
    end

    # --- sandboxes ------------------------------------------------------------

    def list_sandboxes
      @transport.json("GET", "/kosa8/v1/sandboxes") || []
    end

    # By id, then by name; nil when there is none.
    def get_sandbox(id_or_name)
      l = list_sandboxes
      l.find { |s| s["id"] == id_or_name } || l.find { |s| s["name"] == id_or_name }
    end

    # POST /kosa8/v1/sandboxes: boot a microVM sandbox.
    # egress: "deny" | "any" | "fakenet" | "allow:host,host" | { allow: [...] }
    #
    # auto_stop_min stops it after that many idle minutes, ttl_min that long
    # after creation, auto_delete_min deletes it once stopped that long, and
    # ephemeral deletes it whenever it stops. template starts it with a
    # template's image (see build_template).
    def create_sandbox(name: nil, cpus: nil, mem_mb: nil, disk_gb: nil, mounts: nil, egress: nil, egress_allow: nil,
                       capture: nil, labels: nil, broker: nil, auto_stop_min: nil, auto_delete_min: nil, ttl_min: nil,
                       ephemeral: false, template: nil, approval: nil)
      body = {}
      body[:name] = name if name
      body[:cpus] = cpus if cpus
      body[:mem_mb] = mem_mb if mem_mb
      body[:disk_gb] = disk_gb if disk_gb
      body[:mounts] = mounts if mounts
      e = Client.egress_string(egress, egress_allow)
      body[:egress] = e if e
      body[:capture] = capture unless capture.nil?
      body[:labels] = labels if labels
      body[:broker] = broker if broker
      { auto_stop_min: auto_stop_min, auto_delete_min: auto_delete_min, ttl_min: ttl_min }.each do |k, v|
        body[k] = v if v && v.positive?
      end
      body[:ephemeral] = true if ephemeral
      body[:template] = template if template
      @transport.json("POST", "/kosa8/v1/sandboxes", body: body, approval: approval)
    end

    # POST …/up: boot a stopped sandbox from its own disk.
    def start_sandbox(sandbox, approval: nil)
      @transport.json("POST", sb(sandbox, "up"), approval: approval)
    end

    # POST …/down: stop without deleting (the disk is kept).
    def stop_sandbox(sandbox, approval: nil)
      @transport.json("POST", sb(sandbox, "down"), approval: approval)
    end

    # DELETE /kosa8/v1/sandboxes/{id}; its checkpoints go too unless keep_checkpoints.
    def delete_sandbox(sandbox, wipe: false, keep_checkpoints: false, approval: nil)
      out = @transport.json("DELETE", sb(sandbox), query: { wipe: wipe }, approval: approval) || {}
      dropped = 0
      unless keep_checkpoints
        begin
          ids = @checkpoints.forget(sandbox)
          ids.each do |sid|
            delete_snapshot(sid, wipe: wipe, approval: approval)
          rescue Error
            nil
          end
          dropped = ids.length
        rescue Error
          nil # bookkeeping debris, not a failed delete
        end
      end
      out.merge("checkpoints_dropped" => dropped)
    end

    # POST …/pull: pull an image into the sandbox's private engine.
    def pull_into_sandbox(sandbox, ref, approval: nil)
      @transport.json("POST", sb(sandbox, "pull"), body: { ref: ref }, approval: approval)
    end

    def sandbox_images(sandbox)
      @transport.json("GET", sb(sandbox, "images")) || []
    end

    def sandbox_containers(sandbox)
      @transport.json("GET", sb(sandbox, "containers")) || []
    end

    # GET …/egress: the policy the host enforces and what it decided.
    def sandbox_egress(sandbox)
      @transport.json("GET", sb(sandbox, "egress"))
    end

    # --- processes ------------------------------------------------------------

    # POST …/run: run a container to completion. The image must already be in
    # the sandbox (pull_into_sandbox). Callbacks see output as it arrives.
    def run(sandbox, image, args = [], env: nil, on_stdout: nil, on_stderr: nil, on_status: nil, timeout: nil, approval: nil)
      body = { image: image, args: args.to_a }
      e = Client.env_list(env)
      body[:env] = e if e
      collect(on_stdout, on_stderr, on_status) do |h|
        @transport.frames("POST", sb(sandbox, "run"), body: body, approval: approval, timeout: timeout, &h)
      end
    end

    # POST …/start: start a detached container; returns its id.
    def start_container(sandbox, image, args = [], approval: nil)
      @transport.json("POST", sb(sandbox, "start"), body: { image: image, args: args.to_a }, approval: approval)["id"]
    end

    # POST …/exec: run a command in a running container of the sandbox.
    def exec(sandbox, container, args, on_stdout: nil, on_stderr: nil, timeout: nil, approval: nil)
      collect(on_stdout, on_stderr, nil) do |h|
        exec_frames(sandbox, container, args, timeout: timeout, approval: approval, &h)
      end
    end

    # The raw frame stream of an exec; yields each frame.
    def exec_frames(sandbox, container, args, timeout: nil, approval: nil, &blk)
      @transport.frames("POST", sb(sandbox, "exec"), body: { container: container, args: args.to_a },
                                                    approval: approval, timeout: timeout, &blk)
    end

    # POST …/start-interactive: start a container with stdin held open.
    def start_interactive(sandbox, image, args = [], env: nil, tty: false, approval: nil)
      @transport.json("POST", sb(sandbox, "start-interactive"),
                      body: { image: image, args: args.to_a, env: Client.env_list(env), tty: tty },
                      approval: approval)["id"]
    end

    # POST …/containers/{cid}/stdin: a String, an IO, or an Enumerable of chunks (sent chunked).
    #
    # The request body is the container's whole stdin: the daemon closes stdin
    # when the body ends, so this can be called once per container. To feed
    # input over time, pass an IO or an Enumerable that yields as it goes.
    # A second call raises instead of reporting success for input the process
    # would never see.
    def write_stdin(sandbox, container, data, approval: nil)
      key = [sandbox.to_s, container.to_s]
      @stdin_mu.synchronize do
        if @stdin_sent[key]
          raise Error, "stdin of container #{container} in #{sandbox} was already sent and is closed: the daemon " \
                       "treats one write_stdin body as the whole of stdin. Pass an IO or an Enumerable to stream input"
        end

        @stdin_sent[key] = true
      end
      @transport.json("POST", sb(sandbox, "containers", Kosa8.enc(container), "stdin"), raw_body: data, approval: approval)
    end

    # POST …/containers/{cid}/attach: follow a container's output until it exits.
    def attach(sandbox, container, on_stdout: nil, on_stderr: nil, timeout: nil, approval: nil)
      collect(on_stdout, on_stderr, nil) do |h|
        @transport.frames("POST", sb(sandbox, "containers", Kosa8.enc(container), "attach"),
                          approval: approval, timeout: timeout, &h)
      end
    end

    # --- snapshots and forks --------------------------------------------------

    # POST …/snapshot: capture memory, processes and disks.
    def snapshot(sandbox, id: nil, encrypt: false, approval: nil)
      body = {}
      body[:id] = id if id
      body[:encrypt] = true if encrypt
      @transport.json("POST", sb(sandbox, "snapshot"), body: body, approval: approval)
    end

    def list_snapshots
      @transport.json("GET", "/kosa8/v1/snapshots") || []
    end

    # POST /kosa8/v1/snapshots/{id}/restore: boot a sandbox from a snapshot, processes resumed.
    def restore_snapshot(snapshot_id, name: nil, label: nil, allow_tampered: false, approval: nil)
      body = {}
      body[:name] = name if name
      body[:label] = label if label
      body[:allow_tampered] = true if allow_tampered
      @transport.json("POST", "/kosa8/v1/snapshots/#{Kosa8.enc(snapshot_id)}/restore", body: body, approval: approval)
    end

    def delete_snapshot(snapshot_id, wipe: false, force: false, approval: nil)
      @transport.json("DELETE", "/kosa8/v1/snapshots/#{Kosa8.enc(snapshot_id)}",
                      query: { wipe: wipe, force: force }, approval: approval)
    end

    # POST …/fork: n live copies of a running sandbox.
    # Returns { "forks" => [...], "snapshot" => ..., "fork_ms" => ..., "count" => n }.
    def fork(sandbox, n = 1, prefix: nil, label: nil, approval: nil)
      body = { n: n }
      body[:prefix] = prefix if prefix
      body[:label] = label if label
      @transport.json("POST", sb(sandbox, "fork"), body: body, approval: approval)
    end

    # Best-of-N, as `kosa8 explore`: forks the sandbox once per variant, runs
    # each (sh -c VARIANT in image) concurrently in its own branch, keeps the
    # fastest successful branch and deletes the rest.
    def explore(sandbox, variants, image: "alpine:latest", keep_all: false, keep: nil, timeout: 120, prefix: nil,
                pull: true, approval: nil)
      variants = variants.to_a
      raise Error, "give at least two variants; with one there is nothing to compare" if variants.length < 2

      pull_into_sandbox(sandbox, image, approval: approval) if pull
      prefix ||= "#{sandbox}-explore-#{Time.now.to_i % 100_000}"
      forked = fork(sandbox, variants.length, prefix: prefix, approval: approval)
      names = (forked["forks"] || []).map { |f| f["id"] }.select { |x| x.is_a?(String) }
      if names.length < variants.length
        raise Error, "forked #{names.length} branches for #{variants.length} variants; see list_sandboxes for what was created"
      end

      branches = names.zip(variants).map do |name, v|
        Thread.new { run_branch(name, image, v, timeout, approval) }
      end.map(&:value)
      winner = ""
      best = nil
      branches.each do |b|
        if b.error.nil? && b.exit.zero? && (best.nil? || b.duration_ms < best)
          winner = b.name
          best = b.duration_ms
        end
      end
      if keep
        raise Error, "keep #{keep} is not one of the branches (#{names.join(', ')}); all of them were kept" unless names.include?(keep)

        winner = keep
      end
      removed = 0
      unless keep_all
        branches.each do |b|
          next if b.name == winner

          begin
            @transport.json("DELETE", sb(b.name), approval: approval)
            removed += 1
          rescue Error
            nil # reported by the count
          end
        end
      end
      ExploreResult.new(parent: sandbox, branches: branches, winner: winner, removed: removed)
    end

    # --- checkpoints (client-side over snapshots, as pkg/checkpoint) ------------

    # Save a restore point: a snapshot <sandbox>-ckpt-<n> on the sandbox's stack,
    # the same store `kosa8 checkpoint` uses; the oldest is evicted past 10.
    def checkpoint(sandbox, label: "", approval: nil)
      snap = nil
      # Two checkpoints taken at once (here or by the CLI) can pick the same
      # next id; the loser's snapshot is refused with 409. The winner records
      # its id only once its snapshot is done, so step past the taken id
      # rather than re-reading the store.
      cid, evict = @checkpoints.next_id(sandbox)
      10.times do |attempt|
        begin
          snap = snapshot(sandbox, id: cid, approval: approval)
          break
        rescue ConflictError => e
          raise if attempt == 9 || !(e.daemon_message || e.message).to_s.include?("already exists")

          cid = "#{sandbox}-ckpt-#{CheckpointBook.seq(cid, sandbox) + 1}"
        end
      end
      evict.each do |old| # evict only once the replacement exists
        delete_snapshot(old, approval: approval)
      rescue Error
        nil
      end
      rec = @checkpoints.record(cid, sandbox, label, evict)
      { "checkpoint" => rec, "evicted" => evict, "snapshot" => snap }
    end

    # A sandbox's restore points, oldest first.
    def list_checkpoints(sandbox)
      @checkpoints.list(sandbox)
    end

    # Undo: put the sandbox back to a checkpoint (id or label; default the
    # latest) under the same name, processes resumed. Checkpoints taken after
    # the target are discarded. The current state is lost.
    def rewind(sandbox, to: nil, approval: nil)
      target = to ? @checkpoints.resolve(sandbox, to) : @checkpoints.latest(sandbox)
      # The sandbox must go first: the restored VM takes its name. A refusal
      # here leaves everything as it was, and is raised as is.
      @transport.json("DELETE", sb(sandbox), approval: approval)
      begin
        restored = restore_snapshot(target["id"], name: sandbox, approval: approval)
      rescue Error => e
        raise CheckpointError, "restore failed and #{sandbox} no longer exists (it was deleted to free its name " \
                               "for the restore): #{e.message} — the checkpoint is intact; recover with " \
                               "restore_snapshot(#{target['id'].inspect}, name: #{sandbox.inspect})"
      end
      dropped = []
      begin
        dropped = @checkpoints.pop(sandbox, target["id"])
        dropped.each do |sid|
          delete_snapshot(sid, approval: approval)
        rescue Error
          nil
        end
      rescue Error
        nil # bookkeeping
      end
      { "sandbox" => restored["sandbox"], "checkpoint" => target, "dropped" => dropped,
        "restore_ms" => restored["restore_ms"] }
    end

    # A handle bound to one sandbox.
    def sandbox(sandbox_id)
      Sandbox.new(self, sandbox_id)
    end

    def self.egress_string(egress, allow)
      if allow && !allow.empty?
        raise Error, "egress_allow already limits the network to the hosts it lists; do not also set egress" if egress && egress != "deny"

        return "allow:" + allow.map { |h| h.to_s.strip }.join(",")
      end
      return nil if egress.nil?
      return egress if egress.is_a?(String)

      hosts = (egress[:allow] || egress["allow"] || []).to_a
      raise Error, 'an egress allow-list needs at least one host; use egress: "deny" for no network' if hosts.empty?

      "allow:" + hosts.map { |h| h.to_s.strip }.join(",")
    end

    def self.env_list(env)
      return nil if env.nil?
      return env.map { |k, v| "#{k}=#{v}" } if env.is_a?(Hash)

      env.to_a
    end

    private

    def sb(id, *rest)
      (["/kosa8/v1/sandboxes", Kosa8.enc(id)] + rest).join("/")
    end

    def collect(on_stdout, on_stderr, on_status)
      out = +"".b
      err = +"".b
      result = nil
      handler = lambda do |f|
        next if result

        if f["done"]
          if f["error"]
            raise StreamError.new(f["error"], stdout: Client.utf8(out), stderr: Client.utf8(err), daemon_message: f["error"])
          end

          result = ExecResult.new(exit_code: f["exit"].is_a?(Integer) ? f["exit"] : 0, stdout: Client.utf8(out),
                                  stderr: Client.utf8(err))
          next
        end
        data = f["data"]
        next if data.nil? || data.empty?

        case f["stream"]
        when "stderr"
          err << data
          on_stderr&.call(data)
        when "status"
          on_status&.call(data)
        else
          out << data
          on_stdout&.call(data)
        end
      end
      yield handler
      result || raise(StreamError.new("stream ended unexpectedly (no final frame)", stdout: Client.utf8(out),
                                                                                    stderr: Client.utf8(err)))
    end

    def self.utf8(b)
      b.dup.force_encoding(Encoding::UTF_8).scrub
    end

    def run_branch(name, image, variant, timeout, approval)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      b = ExploreBranch.new(name: name, variant: variant, exit: -1, output: "", error: nil)
      # A freshly restored branch can refuse the first connection while its
      # engine settles; retry connection-level failures briefly, as the CLI does.
      4.times do |attempt|
        begin
          res = run(name, image, ["sh", "-c", variant], timeout: timeout, approval: approval)
          b.exit = res.exit_code
          b.output = (res.stdout + res.stderr).chomp
          b.error = nil
          break
        rescue Error => e
          b.error = e.message
          b.output = (e.stdout + e.stderr).chomp if e.is_a?(StreamError)
          break if e.is_a?(TimeoutError) || b.error !~ TRANSIENT || attempt == 3

          sleep((attempt + 1) * 0.5)
        end
      end
      b.duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000).to_i
      b
    end
  end

  # The client's sandbox methods bound to one sandbox id.
  class Sandbox
    attr_reader :id, :client

    def initialize(client, id)
      @client = client
      @id = id
    end

    def inspect
      "#<Kosa8::Sandbox #{@id}>"
    end

    def info
      @client.get_sandbox(@id)
    end

    def checkpoints
      @client.list_checkpoints(@id)
    end

    def images
      @client.sandbox_images(@id)
    end

    def containers
      @client.sandbox_containers(@id)
    end

    def egress
      @client.sandbox_egress(@id)
    end

    def run(image, args = [], **kw)
      @client.run(@id, image, args, **kw)
    end

    def start_container(image, args = [], **kw)
      @client.start_container(@id, image, args, **kw)
    end

    def exec(container, args, **kw)
      @client.exec(@id, container, args, **kw)
    end

    def pull(ref, **kw)
      @client.pull_into_sandbox(@id, ref, **kw)
    end

    def fork(n = 1, **kw)
      @client.fork(@id, n, **kw)
    end

    def explore(variants, **kw)
      @client.explore(@id, variants, **kw)
    end

    def exec_frames(container, args, **kw, &blk)
      @client.exec_frames(@id, container, args, **kw, &blk)
    end

    def start_interactive(image, args = [], **kw)
      @client.start_interactive(@id, image, args, **kw)
    end

    def write_stdin(container, data, **kw)
      @client.write_stdin(@id, container, data, **kw)
    end

    def attach(container, **kw)
      @client.attach(@id, container, **kw)
    end

    # The toolbox, bound to this sandbox: sandbox.run_code("print(1)"),
    # sandbox.write_file("a.txt", "hi"), sandbox.shell("ls"), …
    %i[run_code list_files stat_file read_file read_text write_file delete_file make_dir move_file git git_clone
       git_status git_commit create_session list_sessions session_exec shell delete_session start_pty resize_pty
       create_preview].each do |name|
      define_method(name) { |*args, **kw, &blk| @client.public_send(name, @id, *args, **kw, &blk) }
    end

    def set_lifecycle(**kw)
      @client.set_lifecycle(@id, **kw)
    end

    { start: :start_sandbox, stop: :stop_sandbox, delete: :delete_sandbox, snapshot: :snapshot,
      checkpoint: :checkpoint, rewind: :rewind }.each do |name, target|
      define_method(name) { |**kw| @client.public_send(target, @id, **kw) }
    end
  end
end
