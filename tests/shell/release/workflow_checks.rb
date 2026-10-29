# Structural checks of the GitHub workflow files. Parsed with Ruby's YAML
# (stdlib); no network access. Usage: ruby workflow_checks.rb REPO_ROOT
require "yaml"

root = ARGV.fetch(0)
$pass = 0
$fail = 0

def check(name, ok, detail = nil)
  if ok
    $pass += 1
    puts "  ok   #{name}"
  else
    $fail += 1
    puts "  FAIL #{name}#{detail ? " (#{detail})" : ""}"
  end
end

def load_yaml(path)
  YAML.safe_load(File.read(path), aliases: false)
rescue StandardError => e
  check("YAML parses: #{File.basename(path)}", false, e.message)
  nil
end

def steps_of(wf)
  (wf["jobs"] || {}).flat_map { |jn, j| (j["steps"] || []).map { |s| [jn, s] } }
end

wf_dir = File.join(root, ".github", "workflows")
files = Dir.glob(File.join(wf_dir, "*.{yml,yaml}")).sort
check("workflow files found", !files.empty?)
docs = {}
files.each do |f|
  d = load_yaml(f)
  next unless d
  docs[File.basename(f)] = d
  check("YAML parses: #{File.basename(f)}", d.is_a?(Hash))
end
dep_path = File.join(root, ".github", "dependabot.yml")
dep = load_yaml(dep_path)
check("YAML parses: dependabot.yml", dep.is_a?(Hash))

# --- every workflow ---------------------------------------------------------
docs.each do |name, wf|
  steps_of(wf).each do |jn, s|
    if s["uses"]
      u = s["uses"]
      next if u.start_with?("./")
      check("#{name}/#{jn}: '#{u[0, 40]}' pinned to a 40-hex commit SHA", u =~ /\A[^@]+@[0-9a-f]{40}\z/)
    end
    if s["run"]
      check("#{name}/#{jn}: run block has no ${{ }} interpolation", !s["run"].include?("${{"),
            s["run"].lines.grep(/\$\{\{/).first.to_s.strip)
    end
    if s["uses"].to_s.start_with?("actions/checkout@")
      pc = (s["with"] || {})["persist-credentials"]
      check("#{name}/#{jn}: checkout sets persist-credentials: false", pc == false)
    end
  end
  perms = wf["permissions"]
  check("#{name}: top-level permissions present and read-only",
        perms.is_a?(Hash) && perms["contents"] == "read" && perms.values.none? { |v| v == "write" })
  (wf["jobs"] || {}).each do |jn, j|
    jp = j["permissions"]
    if jp.is_a?(Hash) && jp.values.include?("write")
      check("#{name}/#{jn}: write permission only on release job", name == "release.yml" && jn == "release")
    end
  end
end
all_text = files.map { |f| File.read(f) }.join("\n")
check("no tag-pinned @v/@stable/@main uses remain",
      all_text.lines.grep(/^\s*-?\s*uses:\s*\S+@(v\d|stable|main|master)/).empty?)
check("no github.event/head_ref data in run blocks",
      docs.values.flat_map { |w| steps_of(w).map { |_, s| s["run"].to_s } }.none? { |r| r =~ /github\.(event|head_ref|ref_name)/ })

# --- release.yml ------------------------------------------------------------
rel = docs["release.yml"]
if rel
  on = rel["on"] || rel[true]
  tags = on["push"]["tags"]
  check("release trigger is a single strict-ish v-semver glob", tags == ["v[0-9]+.[0-9]+.[0-9]+*"], tags.inspect)
  check("release trigger no longer matches bare numbers or v*", !tags.include?("v*") && !tags.include?("[0-9]+.*"))
  check("release.yml top-level permissions is exactly contents: read", rel["permissions"] == { "contents" => "read" })
  jobs = rel["jobs"]
  check("verify job exists", jobs.key?("verify"))
  %w[build release update-homebrew].each do |j|
    n = Array(jobs[j]["needs"])
    check("#{j} needs verify", n.include?("verify"), n.inspect)
  end
  check("release job has contents: write", jobs["release"]["permissions"] == { "contents" => "write" })
  others = jobs.reject { |k, _| k == "release" }
  check("no other job requests write", others.values.none? { |j| j["permissions"].to_s.include?("write") })
  v = jobs["verify"]["steps"]
  check("verify checkout uses fetch-depth: 0",
        v.any? { |s| s["uses"].to_s.start_with?("actions/checkout@") && (s["with"] || {})["fetch-depth"] == 0 })
  vs = v.find { |s| s["run"].to_s.include?("validate-release-tag.sh") }
  check("verify runs validate-release-tag.sh", !vs.nil?)
  check("verify passes tag via env var RELEASE_TAG", vs && vs["env"] && vs["env"]["RELEASE_TAG"] == "${{ github.ref_name }}")
  check("verify runs cargo test --locked", v.any? { |s| s["run"].to_s.include?("cargo test --locked") })
  tap = jobs["update-homebrew"]["steps"].find { |s| (s["with"] || {})["repository"].to_s.include?("homebrew-mobhook") }
  check("tap checkout found", !tap.nil?)
  check("tap checkout has persist-credentials: false", tap && tap["with"]["persist-credentials"] == false)
  hb = jobs["update-homebrew"]["steps"].map { |s| s["run"].to_s }.join("\n")
  check("homebrew job uses render-formula.sh", hb.include?("render-formula.sh"))
  check("homebrew job verifies SHA256SUMS", hb.include?("-c SHA256SUMS"))
  check("homebrew push uses GIT_ASKPASS", hb.include?("GIT_ASKPASS"))
  check("homebrew job does not set -x / echo token", !hb.include?("set -x") && hb !~ /echo[^\n]*TAP_TOKEN/)
  check("no formula heredoc left in workflow", !hb.include?("<<EOF") && !hb.include?("class Mobhook"))
  rs = jobs["release"]["steps"].map { |s| s["run"].to_s }.join("\n")
  check("release job writes SHA256SUMS before upload", rs.include?("> SHA256SUMS"))
  gh = jobs["release"]["steps"].find { |s| s["uses"].to_s.start_with?("softprops/action-gh-release@") }
  check("SHA256SUMS is uploaded as a release asset", gh && gh["with"]["files"].include?("SHA256SUMS"))
  # --- prerelease guard ---
  check("verify job exposes prerelease output",
        jobs["verify"]["outputs"] == { "prerelease" => "${{ steps.channel.outputs.prerelease }}" }, jobs["verify"]["outputs"].inspect)
  ch = jobs["verify"]["steps"].find { |s| s["id"] == "channel" }
  check("channel step exists after the tag validation step",
        ch && jobs["verify"]["steps"].index(ch) > jobs["verify"]["steps"].index(vs))
  check("channel step reads tag from env RELEASE_TAG only",
        ch && ch["env"] == { "RELEASE_TAG" => "${{ github.ref_name }}" } && !ch["run"].include?("${{"))
  check("channel step writes prerelease=true/false to GITHUB_OUTPUT",
        ch && ch["run"].include?("prerelease=true") && ch["run"].include?("prerelease=false") && ch["run"].include?("$GITHUB_OUTPUT"))
  check("release job passes prerelease from verify output to action-gh-release",
        gh && gh["with"]["prerelease"] == "${{ needs.verify.outputs.prerelease }}", gh && gh["with"]["prerelease"].inspect)
  check("release job still needs verify (for the output)", Array(jobs["release"]["needs"]).include?("verify"))
  check("update-homebrew is skipped unless verify says prerelease == 'false' (fail-closed)",
        jobs["update-homebrew"]["if"].to_s.strip == "needs.verify.outputs.prerelease == 'false'", jobs["update-homebrew"]["if"].inspect)
  check("update-homebrew still needs verify and release",
        (%w[verify release] - Array(jobs["update-homebrew"]["needs"])).empty?)
  check("only update-homebrew carries a job-level if", jobs.reject { |k, _| k == "update-homebrew" }.values.none? { |j| j.key?("if") })
  # Behavioural: run the channel step's bash against sample tags.
  if ch
    require "tmpdir"
    require "open3"
    {
      "v0.4.0-rc.1" => "true", "v1.2.3-beta" => "true", "v1.2.3-0" => "true",
      "v0.4.0" => "false", "v10.20.30" => "false", "v1.2.3-" => "false"
    }.each do |tag, want|
      Dir.mktmpdir do |d|
        out = File.join(d, "out")
        File.write(out, "")
        _o, _e, st = Open3.capture3({ "RELEASE_TAG" => tag, "GITHUB_OUTPUT" => out }, "bash", "-c", ch["run"])
        got = File.read(out).strip
        check("channel step: #{tag} => prerelease=#{want}", st.success? && got == "prerelease=#{want}", got)
      end
    end
  end
  inst = jobs["build"]["steps"].find { |s| s["name"] == "Install cross" }
  check("cross installed with --locked and a --tag/--rev",
        inst && inst["run"].include?("--locked") && inst["run"] =~ /--(tag|rev) \S+/)
  b = jobs["build"]["steps"].map { |s| s["run"].to_s }.join("\n")
  check("release build uses --locked", b.scan("build --release --locked").length == 2)
  tc = steps_of(rel).select { |_, s| s["uses"].to_s.start_with?("dtolnay/rust-toolchain@") }
  check("rust-toolchain passes toolchain: stable explicitly", !tc.empty? && tc.all? { |_, s| (s["with"] || {})["toolchain"] == "stable" })
end

# --- ci.yml -----------------------------------------------------------------
ci = docs["ci.yml"]
if ci
  runs = steps_of(ci).map { |_, s| s["run"].to_s }
  check("ci.yml permissions: contents: read", ci["permissions"] == { "contents" => "read" })
  check("ci cargo test uses --locked", runs.any? { |r| r.start_with?("cargo test --locked") })
  check("ci cargo clippy uses --locked", runs.any? { |r| r.start_with?("cargo clippy --locked") })
  check("ci release build uses --locked", runs.any? { |r| r.start_with?("cargo build --release --locked") })
end

# --- dependabot -------------------------------------------------------------
if dep.is_a?(Hash)
  ups = dep["updates"] || []
  %w[github-actions cargo].each do |eco|
    u = ups.find { |x| x["package-ecosystem"] == eco }
    check("dependabot covers #{eco} weekly", u && u["schedule"]["interval"] == "weekly")
  end
  check("dependabot version 2", dep["version"] == 2)
end

puts "workflow-checks: #{$pass} passed, #{$fail} failed"
exit($fail.zero? ? 0 : 1)
