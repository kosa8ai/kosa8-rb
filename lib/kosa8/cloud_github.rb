# frozen_string_literal: true

# GitHub repos: the org connects the kosa8 GitHub App once, then a sandbox
# starts from a repo (repo: on sandboxes.create) and sends changes back
# (CloudSandbox#push, #pull_request). kosa8 mints a GitHub token for one
# repo, for one operation, that expires within an hour; it never enters the
# sandbox, is never returned, and every use is audited.
module Kosa8
  class Cloud
    # owner/name, as GitHub allows them.
    REPO_NAME = %r{\A[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}\z}.freeze

    # The org's connected GitHub: status, repos, branches (a CloudGitHub).
    attr_reader :github

    alias initialize_without_github initialize
    def initialize(**kw)
      initialize_without_github(**kw)
      @github = CloudGitHub.new(self)
    end

    # +name+ when it is owner/name, else ArgumentError.
    def self.check_repo_name(name)
      unless name.is_a?(String) && REPO_NAME.match?(name)
        raise ArgumentError, "repo must be owner/name (optionally @ref), got #{name.inspect}"
      end

      name
    end

    # The repo field of a create, checked: "owner/name" or "owner/name@ref"
    # stays a String; a Hash (name:, ref:, path:, depth:) is sent as
    # {"name", "ref", "path", "depth"}.
    def self.repo_body(spec)
      if spec.is_a?(String)
        name, at, ref = spec.partition("@")
        check_repo_name(name)
        raise ArgumentError, "repo #{spec} has an empty ref after @" if !at.empty? && ref.empty?

        return spec
      end
      raise ArgumentError, 'repo must be "owner/name[@ref]" or {name:, ref:, path:, depth:}' unless spec.is_a?(Hash)

      h = spec.transform_keys(&:to_s)
      out = { "name" => check_repo_name(h["name"]) }
      out["ref"] = h["ref"].to_s unless h["ref"].nil?
      out["path"] = h["path"].to_s unless h["path"].nil?
      unless h["depth"].nil?
        d = h["depth"]
        raise ArgumentError, "repo depth must be a whole number from 1, got #{d.inspect}" unless d.is_a?(Integer) && d >= 1

        out["depth"] = d
      end
      out
    end
  end

  # cloud.github: the org's connected GitHub. Connecting and disconnecting is
  # done once by an admin (app.kosa8.com Settings, or `kosa8 github connect`);
  # listing repos needs only the normal sandbox scope.
  class CloudGitHub
    def initialize(cloud)
      @cloud = cloud
    end

    def inspect
      "#<Kosa8::CloudGitHub>"
    end

    # {"configured", "connected", "can_manage", "install_url" (admins only,
    # else nil), "installations" => [{"installation_id", "account_login",
    # "account_type", "repository_selection", "repo_count", "manage_url",
    # "missing_permissions"}]}.
    def status
      @cloud.request("GET", "/v1/github")
    end

    # Repos the org's installations can see, most recently pushed first;
    # +query+ filters by substring. Each Hash has "full_name", "private",
    # "default_branch", "description", "pushed_at", "html_url",
    # "installation_id" and "language".
    def repos(query = nil, page: nil)
      repos_page(query, page: page)["repos"]
    end

    # One page of #repos: {"repos" => [...], "next_page" => Integer or nil}.
    def repos_page(query = nil, page: nil)
      q = []
      q << "q=#{Kosa8.enc(query.to_s)}" unless query.nil? || query.to_s.empty?
      q << "page=#{Integer(page)}" unless page.nil?
      r = @cloud.request("GET", "/v1/github/repos#{q.empty? ? "" : "?#{q.join("&")}"}")
      r = {} unless r.is_a?(Hash)
      { "repos" => r["repos"] || [], "next_page" => r["next_page"] }
    end

    # A repo's (owner/name) default branch and first 100 branches:
    # {"default_branch", "branches" => [{"name", "sha", "protected"}]}.
    def branches(repo)
      owner, name = Cloud.check_repo_name(repo).split("/", 2)
      @cloud.request("GET", "/v1/github/repos/#{Kosa8.enc(owner)}/#{Kosa8.enc(name)}/branches")
    end
  end

  class CloudSandbox
    # The GitHub repo it was started from: {"full_name", "ref", "sha",
    # "path", "status" ("cloned", "pending" or "failed"), "error",
    # "changes" => {"files_changed", "insertions", "deletions"}}. A clone
    # still pending is tried again. Also kept in info["repo"].
    def repo
      r = @cloud.request("GET", "/v1/sandboxes/#{Kosa8.enc(id)}/repo")
      r = r["repo"] if r.is_a?(Hash) && r["repo"].is_a?(Hash)
      @info["repo"] = r if @info.is_a?(Hash)
      r
    end

    # Commit everything that changed in its repo and push it to +branch+
    # (default kosa8/<short id>). kosa8 pushes with a token for this one
    # repo that never enters the sandbox. Returns {"branch", "sha",
    # "compare_url", "files_changed"}; nothing changed raises
    # Kosa8::NoChangesError.
    def push(branch: nil, message: nil, path: nil)
      body = {}
      body["branch"] = branch.to_s unless branch.nil?
      body["message"] = message.to_s unless message.nil?
      body["path"] = path.to_s unless path.nil?
      @cloud.request("POST", "/v1/sandboxes/#{Kosa8.enc(id)}/github/push", body)
    end

    # Push (as #push) and open a pull request, a draft unless draft: false.
    # Returns {"number", "url", "branch", "sha"}.
    def pull_request(title: nil, body: nil, base: nil, branch: nil, draft: nil)
      b = {}
      b["title"] = title.to_s unless title.nil?
      b["body"] = body.to_s unless body.nil?
      b["base"] = base.to_s unless base.nil?
      b["branch"] = branch.to_s unless branch.nil?
      b["draft"] = draft == true unless draft.nil?
      @cloud.request("POST", "/v1/sandboxes/#{Kosa8.enc(id)}/github/pull-request", b)
    end
  end
end
