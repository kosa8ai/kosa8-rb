# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift __dir__
require "minitest/autorun"
require "kosa8"
require "fake_cloud"

# GitHub repos: cloud.github, repo: on create, box.repo/push/pull_request and
# the typed errors, against a fake API.
class CloudGitHubTest < Minitest::Test
  RUNNING = { "id" => "sb_abc", "state" => "running", "template" => "base" }.freeze
  REPO = { "full_name" => "acme/api", "ref" => "main", "sha" => "abc", "path" => "/workspace/api",
           "status" => "cloned" }.freeze

  def teardown
    @fake&.close
  end

  def cloud(&handler)
    @fake = FakeCloud.new(&handler)
    @fake.cloud(retry_policy: Kosa8::RetryPolicy::NONE)
  end

  def test_status_repos_and_branches_use_the_contract_paths
    c = cloud do |req|
      case req[:path].split("?", 2)[0]
      when "/v1/github"
        [200, { "configured" => true, "connected" => true, "can_manage" => false, "install_url" => nil,
                "installations" => [] }]
      when "/v1/github/repos"
        [200, { "repos" => [{ "full_name" => "acme/api", "private" => true, "default_branch" => "main" }],
                "next_page" => 2 }]
      else
        [200, { "default_branch" => "main", "branches" => [{ "name" => "main", "sha" => "abc", "protected" => true }] }]
      end
    end
    assert c.github.status["connected"]
    assert_equal "acme/api", c.github.repos("api")[0]["full_name"]
    assert_equal 2, c.github.repos_page("x y", page: 2)["next_page"]
    assert c.github.branches("acme/api")["branches"][0]["protected"]
    assert_equal ["GET /v1/github", "GET /v1/github/repos?q=api", "GET /v1/github/repos?q=x%20y&page=2",
                  "GET /v1/github/repos/acme/api/branches"],
                 @fake.seen.map { |s| "#{s[:method]} #{s[:path]}" }
  end

  def test_bad_repo_names_are_refused_before_any_request
    c = cloud { [200, {}] }
    assert_raises(ArgumentError) { c.github.branches("acme") }
    assert_raises(ArgumentError) { c.sandboxes.create(repo: "not a repo") }
    assert_raises(ArgumentError) { c.sandboxes.create(repo: "acme/api@") }
    assert_raises(ArgumentError) { c.sandboxes.create(repo: { name: "acme/api", depth: 0 }) }
    assert_empty @fake.seen
  end

  def test_repo_on_create_string_stays_a_string_hash_in_api_spelling
    c = cloud { [200, { "sandbox" => RUNNING.merge("repo" => REPO) }] }
    box = c.sandboxes.create(repo: "acme/api@main")
    assert_equal "cloned", box.info["repo"]["status"]
    assert_equal "acme/api@main", @fake.seen[0][:body]["repo"]
    c.sandboxes.create(repo: { name: "acme/api", ref: "v1.2", path: "/workspace/x", depth: 5 })
    assert_equal({ "name" => "acme/api", "ref" => "v1.2", "path" => "/workspace/x", "depth" => 5 },
                 @fake.seen[1][:body]["repo"])
  end

  def test_repo_push_and_pull_request
    c = cloud do |req|
      case req[:path]
      when %r{/repo\z}
        [200, { "repo" => REPO.merge("changes" => { "files_changed" => 2 }) }]
      when %r{/github/push\z}
        [200, { "branch" => "kosa8/abc", "sha" => "def", "compare_url" => "https://github.com/acme/api/compare/kosa8/abc",
                "files_changed" => 2 }]
      when %r{/github/pull-request\z}
        [200, { "number" => 12, "url" => "https://github.com/acme/api/pull/12", "branch" => "fix", "sha" => "def" }]
      else
        [200, { "sandbox" => RUNNING }]
      end
    end
    box = c.sandboxes.get("sb_abc")
    assert_equal 2, box.repo["changes"]["files_changed"]
    assert_equal "acme/api", box.info["repo"]["full_name"]
    assert_equal "kosa8/abc", box.push["branch"]
    assert_equal "def", box.push(branch: "fix", message: "m")["sha"]
    assert_equal 12, box.pull_request(title: "Fix", base: "main", draft: false)["number"]
    calls = @fake.seen.drop(1).map { |s| ["#{s[:method]} #{s[:path]}", s[:body]] }
    assert_equal [["GET /v1/sandboxes/sb_abc/repo", nil],
                  ["POST /v1/sandboxes/sb_abc/github/push", {}],
                  ["POST /v1/sandboxes/sb_abc/github/push", { "branch" => "fix", "message" => "m" }],
                  ["POST /v1/sandboxes/sb_abc/github/pull-request", { "title" => "Fix", "base" => "main", "draft" => false }]],
                 calls
  end

  def pr_error(status, body)
    c = cloud { |req| req[:method] == "GET" ? [200, { "sandbox" => RUNNING }] : [status, body] }
    box = c.sandboxes.get("sb_abc")
    assert_raises(Kosa8::ApiError) { box.pull_request }
  end

  def test_github_not_connected_has_connect_url_and_is_a_conflict
    e = pr_error(409, { "error" => "github_not_connected", "message" => "Connect GitHub first.",
                        "connect_url" => "https://app.kosa8.com/app#settings/github" })
    assert_kind_of Kosa8::GitHubNotConnectedError, e
    assert_kind_of Kosa8::ConflictError, e
    assert_equal "https://app.kosa8.com/app#settings/github", e.connect_url
  end

  def test_github_permissions_has_missing_and_settings_url
    e = pr_error(409, { "error" => "github_permissions", "message" => "Approve.", "missing" => ["pull_requests:write"],
                        "settings_url" => "https://github.com/settings/installations/7" })
    assert_kind_of Kosa8::GitHubPermissionsError, e
    assert_equal ["pull_requests:write"], e.missing_permissions
    assert_equal "https://github.com/settings/installations/7", e.settings_url
  end

  def test_no_changes_repo_not_found_and_unavailable
    assert_kind_of Kosa8::NoChangesError, pr_error(409, { "error" => "no_changes", "message" => "Nothing changed." })
    nf = pr_error(404, { "error" => "repo_not_found", "message" => "No such repo." })
    assert_kind_of Kosa8::RepoNotFoundError, nf
    assert_kind_of Kosa8::NotFoundError, nf
    un = pr_error(502, { "error" => "github_unavailable", "message" => "GitHub is busy.", "retry_after_s" => 30 })
    assert_kind_of Kosa8::GitHubUnavailableError, un
    assert_equal 30.0, un.retry_after_s
  end
end
