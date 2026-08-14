#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

module ReleaseWorkflowContract
  module_function

  SMOKE_STEP = "Install and verify from immutable release"
  STAGE_STEP = "Stage draft GitHub Release"
  PUBLISH_STEP = "Finalize and publish verified draft"

  def assert(condition, message)
    raise message unless condition
  end

  def exact_hash(actual, expected, label)
    assert(actual == expected, "#{label} must equal #{expected.inspect}, got #{actual.inspect}")
  end

  def reachable(node, label)
    assert(!node.key?("if"), "#{label} must not define if")
    assert(!node["continue-on-error"], "#{label} must propagate failure")
  end

  def one_step(job, name)
    matches = job.fetch("steps").select { |step| step["name"] == name }
    assert(matches.length == 1, "expected exactly one #{name.inspect} step")
    matches.fetch(0)
  end

  def require_fragments(script, fragments, label)
    fragments.each do |fragment|
      assert(script.include?(fragment), "#{label} is missing #{fragment.inspect}")
    end
  end

  def require_order(script, fragments, label)
    positions = fragments.map do |fragment|
      position = script.index(fragment)
      assert(position, "#{label} is missing #{fragment.inspect}")
      position
    end
    assert(positions.each_cons(2).all? { |left, right| left < right },
           "#{label} operations are out of order: #{fragments.inspect}")
  end

  def load_jobs(workflow_path)
    YAML.load_file(workflow_path).fetch("jobs")
  end

  def validate(workflow_path, ci_path)
    validate_jobs(load_jobs(workflow_path), load_jobs(ci_path))
  end

  def validate_jobs(jobs, ci_jobs)
    stage = jobs.fetch("stage-release")
    smoke = jobs.fetch("no-clone-smoke")
    publish = jobs.fetch("publish-release")

    validate_stage(stage)
    validate_smoke(smoke)
    validate_publish(publish)
    validate_ci_jobs(ci_jobs)
  end

  def validate_stage(job)
    reachable(job, "stage-release job")
    assert(job.fetch("needs") == "build-runtime", "stage-release must depend on build-runtime")
    exact_hash(job.fetch("permissions"), {
      "contents" => "write", "id-token" => "write", "attestations" => "write"
    }, "stage-release permissions")
    exact_hash(job.fetch("outputs"), {
      "release_id" => "${{ steps.stage-release.outputs.release_id }}"
    }, "stage-release outputs")

    step = one_step(job, STAGE_STEP)
    reachable(step, STAGE_STEP)
    assert(step.fetch("id") == "stage-release", "stage step id must be stage-release")
    exact_hash(step.fetch("env"), {
      "EVENT_SHA" => "${{ github.sha }}",
      "GH_TOKEN" => "${{ github.token }}",
      "GH_REPO" => "${{ github.repository }}",
      "TAG_NAME" => "${{ github.ref_name }}"
    }, "stage step env")
    script = step.fetch("run")
    require_fragments(script, [
      "trap cleanup_failed_draft EXIT",
      "gh release delete",
      "--draft",
      "gh release upload",
      "release_id=%s",
      'staged_tag_commit="$(gh api'
    ], STAGE_STEP)
    assert(!script.include?("draft=false"), "stage step must never publish a release")
  end

  def validate_smoke(job)
    reachable(job, "no-clone-smoke job")
    assert(job.fetch("needs") == "stage-release", "smoke must depend on stage-release")
    exact_hash(job.fetch("permissions"), {
      "contents" => "write", "attestations" => "read"
    }, "no-clone-smoke permissions")
    oses = job.dig("strategy", "matrix", "include").map { |entry| entry.fetch("os") }
    assert(oses.sort == ["macos-14", "ubuntu-latest"], "smoke matrix must cover macOS and Ubuntu")
    assert(job.fetch("steps").none? { |step| step["uses"].to_s.start_with?("actions/checkout@") },
           "smoke must not checkout source")

    step = one_step(job, SMOKE_STEP)
    reachable(step, SMOKE_STEP)
    exact_hash(step.fetch("env"), {
      "EVENT_SHA" => "${{ github.sha }}",
      "GH_TOKEN" => "${{ github.token }}",
      "GH_REPO" => "${{ github.repository }}",
      "TAG_NAME" => "${{ github.ref_name }}",
      "WORKFLOW_SHA" => "${{ github.workflow_sha }}",
      "RELEASE_ID" => "${{ needs.stage-release.outputs.release_id }}"
    }, "smoke step env")
    script = step.fetch("run")
    require_fragments(script, [
      ".draft == true",
      'VIBEGUARD_RELEASE_REPO="${GH_REPO}"',
      'secondary_sha="$(sha256_file',
      'secondary_marker_commit="$(' ,
      'final_tag_commit="$(gh api'
    ], SMOKE_STEP)
    require_order(script, [
      'tag_commit="$(gh api',
      'gh release download "${TAG_NAME}"',
      'secondary_sha="$(sha256_file',
      'secondary_marker_commit="$(' ,
      'final_tag_commit="$(gh api'
    ], SMOKE_STEP)
  end

  def validate_publish(job)
    reachable(job, "publish-release job")
    assert(job.fetch("needs") == ["stage-release", "no-clone-smoke"],
           "publish-release must depend on staging and both smoke matrix results")
    exact_hash(job.fetch("permissions"), {
      "contents" => "write", "attestations" => "read"
    }, "publish-release permissions")

    step = one_step(job, PUBLISH_STEP)
    reachable(step, PUBLISH_STEP)
    exact_hash(step.fetch("env"), {
      "EVENT_SHA" => "${{ github.sha }}",
      "GH_TOKEN" => "${{ github.token }}",
      "GH_REPO" => "${{ github.repository }}",
      "TAG_NAME" => "${{ github.ref_name }}",
      "WORKFLOW_SHA" => "${{ github.workflow_sha }}",
      "RELEASE_ID" => "${{ needs.stage-release.outputs.release_id }}"
    }, "publish step env")
    script = step.fetch("run")
    require_fragments(script, [
      ".draft == true",
      "expected_assets=(",
      "sha256sum --check --strict SHA256SUMS",
      "gh attestation verify",
      'marker_commit="$(' ,
      'final_tag_commit="$(gh api',
      "gh api --method PATCH",
      "-F draft=false"
    ], PUBLISH_STEP)
    require_order(script, [
      'release_json="$(gh api',
      'gh release download "${TAG_NAME}"',
      "sha256sum --check --strict SHA256SUMS",
      "gh attestation verify",
      'marker_commit="$(' ,
      'final_tag_commit="$(gh api',
      "gh api --method PATCH"
    ], PUBLISH_STEP)
  end

  def validate_ci_jobs(jobs)
    job = jobs.fetch("validate-and-test")
    reachable(job, "validate-and-test job")
    step = one_step(job, "Validate no-clone release smoke contract")
    assert(!step["continue-on-error"], "CI no-clone contract step must propagate failure")
    assert(step.fetch("run") == "bash tests/test_no_clone_release_smoke.sh",
           "CI must execute the no-clone contract test")
    assert(step.fetch("if") == "runner.os != 'Windows'", "CI contract must run on both Unix matrices")
  end

  def self_test(workflow_path, ci_path)
    jobs = load_jobs(workflow_path)
    ci_jobs = load_jobs(ci_path)
    mutations = {
      "disabled smoke job" => lambda { |copy, _ci| copy.fetch("no-clone-smoke")["if"] = "${{ false }}" },
      "extra smoke permission" => lambda do |copy, _ci|
        copy.fetch("no-clone-smoke").fetch("permissions")["id-token"] = "write"
      end,
      "insufficient draft-release permission" => lambda do |copy, _ci|
        copy.fetch("no-clone-smoke").fetch("permissions")["contents"] = "read"
      end,
      "wrong event expression" => lambda do |copy, _ci|
        one_step(copy.fetch("no-clone-smoke"), SMOKE_STEP).fetch("env")["EVENT_SHA"] =
          "${{ github.ref_name }}"
      end,
      "wrong workflow expression" => lambda do |copy, _ci|
        one_step(copy.fetch("no-clone-smoke"), SMOKE_STEP).fetch("env")["WORKFLOW_SHA"] =
          "${{ github.sha }}"
      end,
      "wrong repository expression" => lambda do |copy, _ci|
        one_step(copy.fetch("no-clone-smoke"), SMOKE_STEP).fetch("env")["GH_REPO"] =
          "${{ github.event.repository.full_name }}"
      end,
      "wrong tag expression" => lambda do |copy, _ci|
        one_step(copy.fetch("no-clone-smoke"), SMOKE_STEP).fetch("env")["TAG_NAME"] =
          "${{ github.ref }}"
      end,
      "disabled CI job" => lambda { |_copy, ci| ci.fetch("validate-and-test")["if"] = "${{ false }}" },
      "removed secondary digest check" => lambda do |copy, _ci|
        one_step(copy.fetch("no-clone-smoke"), SMOKE_STEP)["run"]
          .sub!('secondary_sha="$(sha256_file', 'digest_check_removed="$(sha256_file')
      end,
      "removed secondary marker check" => lambda do |copy, _ci|
        one_step(copy.fetch("no-clone-smoke"), SMOKE_STEP)["run"]
          .sub!('secondary_marker_commit="$(' , 'marker_check_removed="$(')
      end,
      "removed final smoke tag check" => lambda do |copy, _ci|
        one_step(copy.fetch("no-clone-smoke"), SMOKE_STEP)["run"]
          .sub!('final_tag_commit="$(gh api', 'tag_check_removed="$(gh api')
      end,
      "publish missing smoke dependency" => lambda do |copy, _ci|
        copy.fetch("publish-release")["needs"] = ["stage-release"]
      end,
      "removed final publish tag check" => lambda do |copy, _ci|
        one_step(copy.fetch("publish-release"), PUBLISH_STEP)["run"]
          .sub!('final_tag_commit="$(gh api', 'tag_check_removed="$(gh api')
      end,
      "publish before final tag check" => lambda do |copy, _ci|
        script = one_step(copy.fetch("publish-release"), PUBLISH_STEP).fetch("run")
        patch = script.index("gh api --method PATCH")
        final = script.index('final_tag_commit="$(gh api')
        script[patch, 2], script[final, 2] = script[final, 2], script[patch, 2]
      end
    }

    mutations.each do |name, mutation|
      jobs_copy = Marshal.load(Marshal.dump(jobs))
      ci_copy = Marshal.load(Marshal.dump(ci_jobs))
      mutation.call(jobs_copy, ci_copy)
      begin
        validate_jobs(jobs_copy, ci_copy)
      rescue StandardError
        next
      end
      raise "contract false-greened mutation: #{name}"
    end
  end

  def extract(workflow_path, step_name, output_path)
    jobs = load_jobs(workflow_path)
    step = jobs.values.flat_map { |job| job.fetch("steps", []) }
      .select { |candidate| candidate["name"] == step_name }
    assert(step.length == 1, "expected one #{step_name.inspect} step")
    File.binwrite(output_path, step.fetch(0).fetch("run"))
  end
end

command = ARGV.shift
case command
when "validate"
  ReleaseWorkflowContract.validate(ARGV.fetch(0), ARGV.fetch(1))
when "extract-smoke"
  ReleaseWorkflowContract.extract(ARGV.fetch(0), ReleaseWorkflowContract::SMOKE_STEP, ARGV.fetch(1))
when "extract-stage"
  ReleaseWorkflowContract.extract(ARGV.fetch(0), ReleaseWorkflowContract::STAGE_STEP, ARGV.fetch(1))
when "extract-publish"
  ReleaseWorkflowContract.extract(ARGV.fetch(0), ReleaseWorkflowContract::PUBLISH_STEP, ARGV.fetch(1))
when "self-test"
  ReleaseWorkflowContract.self_test(ARGV.fetch(0), ARGV.fetch(1))
else
  warn "usage: #{$PROGRAM_NAME} {validate,self-test} WORKFLOW CI | extract-{smoke,stage,publish} WORKFLOW OUTPUT"
  exit 64
end
