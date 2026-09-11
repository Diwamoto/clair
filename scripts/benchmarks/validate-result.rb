#!/usr/bin/env ruby

require "digest"
require "json"
require "time"

PINNED_COMMIT = "80eef4d30f66c4520445872bed73e95c594e2695"
NORMAL_BUNDLE_IDS = %w[dev.daiki.ccedit dev.daiki.ccedit.dev].freeze
ALLOWED_RUN_STATUSES = %w[measured partial failed].freeze
ALLOWED_LAUNCH_KINDS = %w[fresh-profile warm].freeze
AUTOMATED_RESOURCE_FIELDS = {
  "idle.rss" => ["rss_mib", "MiB"],
  "idle.cpu" => ["cpu_percent", "%"],
  "idle.process_count" => ["process_count", "count"]
}.freeze
AUTOMATED_PHASES = {
  "launch.backend_setup" => "boot.setup_total",
  "launch.frontend_first_paint_after_load" => "fe.first_paint_after_raf"
}.freeze
TOLERANCE = 0.0011
ALLOWED_PROVENANCE_KINDS = %w[manual instruments].freeze
SHA256_PATTERN = /\A[0-9a-f]{64}\z/

def fail!(message)
  warn "invalid benchmark result: #{message}"
  exit 1
end

def object!(value, location)
  fail!("#{location} must be an object") unless value.is_a?(Hash)
  value
end

def array!(value, location)
  fail!("#{location} must be an array") unless value.is_a?(Array)
  value
end

def exact_keys!(value, keys, location)
  actual = value.keys.sort
  expected = keys.sort
  fail!("#{location} keys must be #{expected.join(', ')}") unless actual == expected
end

def nonempty_string!(value, location)
  fail!("#{location} must be a non-empty string") unless value.is_a?(String) && !value.empty?
  value
end

def sha256!(value, location)
  fail!("#{location} must be a lowercase SHA-256") unless value.is_a?(String) && value.match?(SHA256_PATTERN)
  value
end

def rfc3339!(value, location)
  nonempty_string!(value, location)
  unless value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
    fail!("#{location} must be RFC3339 with an explicit timezone")
  end
  Time.iso8601(value)
  value
rescue ArgumentError
  fail!("#{location} must be RFC3339 with an explicit timezone")
end

def positive_integer!(value, location)
  fail!("#{location} must be a positive integer") unless value.is_a?(Integer) && value.positive?
  value
end

def positive_number!(value, location)
  unless value.is_a?(Numeric) && value.finite? && value.positive?
    fail!("#{location} must be a finite positive number")
  end
  value
end

def finite_nonnegative!(value, location)
  unless value.is_a?(Numeric) && value.finite? && value >= 0
    fail!("#{location} must be a finite non-negative number")
  end
  value.to_f
end

def close!(actual, expected, location)
  finite_nonnegative!(actual, location)
  if (actual.to_f - expected.to_f).abs > TOLERANCE
    fail!("#{location} is #{actual.inspect}, expected #{expected.round(3)}")
  end
end

def median(values)
  ordered = values.map(&:to_f).sort
  fail!("cannot calculate a median from no samples") if ordered.empty?
  middle = ordered.length / 2
  ordered.length.odd? ? ordered[middle] : (ordered[middle - 1] + ordered[middle]) / 2.0
end

def nearest_rank_p95(values)
  ordered = values.map(&:to_f).sort
  fail!("cannot calculate p95 from no samples") if ordered.empty?
  ordered[[(0.95 * ordered.length).ceil - 1, 0].max]
end

def validate_metric!(metric, location, expected_unit)
  metric = object!(metric, location)
  case metric["status"]
  when "measured"
    finite_nonnegative!(metric["value"], "#{location}.value")
    fail!("#{location}.unit must equal #{expected_unit.inspect}") unless metric["unit"] == expected_unit
  when "not-measured"
    nonempty_string!(metric["reason"], "#{location}.reason")
    fail!("#{location} must not contain value") if metric.key?("value")
  else
    fail!("#{location}.status must be measured or not-measured")
  end
  metric
end

def validate_distribution!(metric, values, location, p95_allowed:)
  fail!("#{location} has no raw values") if values.empty?
  close!(metric["value"], median(values), "#{location}.value")
  fail!("#{location}.sample_count must equal #{values.length}") unless metric["sample_count"] == values.length

  if p95_allowed && values.length >= 20
    fail!("#{location}.aggregation must be [median, p95]") unless metric["aggregation"] == %w[median p95]
    close!(metric["p95"], nearest_rank_p95(values), "#{location}.p95")
    fail!("#{location} must not report max when p95 is eligible") if metric.key?("max")
  else
    fail!("#{location}.aggregation must be [median, max]") unless metric["aggregation"] == %w[median max]
    close!(metric["max"], values.max, "#{location}.max")
    fail!("#{location} must not report p95 with fewer than 20 samples") if metric.key?("p95")
  end
end

def scan_private_paths(value, location = "result")
  case value
  when Hash
    value.each { |key, child| scan_private_paths(child, "#{location}.#{key}") }
  when Array
    value.each_with_index { |child, index| scan_private_paths(child, "#{location}[#{index}]") }
  when String
    if value.include?("/Users/") || value.include?("/private/tmp/") || value.match?(%r{(?:^|\s)/tmp/})
      fail!("#{location} contains a host-local absolute path")
    end
  end
end

def local_contract(repo_root, relative_path, location)
  raw = File.binread(File.join(repo_root, relative_path))
  [JSON.parse(raw), Digest::SHA256.hexdigest(raw)]
rescue Errno::ENOENT, JSON::ParserError => error
  fail!("cannot load #{location}: #{error.message}")
end

ENGINE_BASELINE_PROFILE = "clair-text-engine-baseline"
ENGINE_CONTRACT_PATH = "docs/benchmarks/text-engine-metric-contract.json"
ENGINE_CAPTURE_KINDS = %w[measured example].freeze
ENGINE_BUILD_CHANNELS = %w[stable dev].freeze
ENGINE_PROVENANCE_KINDS = %w[manual instruments automated].freeze
ENGINE_OBSERVATION_KEYS = %w[
  id
  surface
  fixture_id
  metric
  unit
  samples
  sample_count
  aggregation
  median
  provenance
].freeze

def engine_surface_metrics(contract, surface_id)
  contract.fetch("metrics").select { |_name, metric| Array(metric["surfaces"]).include?(surface_id) }.keys
end

def engine_expected_aggregation(contract, metric_name, sample_count)
  metric = contract.fetch("metrics").fetch(metric_name)
  minimum = contract.dig("percentile_rule", "minimum_sample_count")
  if Array(metric["aggregation"]).include?("p95") && sample_count >= minimum
    %w[median p95]
  else
    %w[median max]
  end
end

def validate_engine_distribution!(entry, values, location, contract, metric_name)
  entry = object!(entry, location)
  close!(entry["median"], median(values), "#{location}.median")
  aggregation = engine_expected_aggregation(contract, metric_name, values.length)
  synthetic = entry.merge("status" => "measured", "value" => entry["median"])
  validate_distribution!(synthetic, values, location, p95_allowed: aggregation == %w[median p95])
end

def validate_engine_identity!(result, contract, contract_sha)
  exact_keys!(
    result,
    %w[schema_version profile capture source environment workload observations summary coverage],
    "result"
  )
  fail!("schema_version must be 1") unless result["schema_version"] == 1

  capture = object!(result["capture"], "capture")
  exact_keys!(capture, %w[kind captured_at_utc note], "capture")
  fail!("capture.kind must be measured or example") unless ENGINE_CAPTURE_KINDS.include?(capture["kind"])
  rfc3339!(capture["captured_at_utc"], "capture.captured_at_utc")
  nonempty_string!(capture["note"], "capture.note")

  source = object!(result["source"], "source")
  exact_keys!(source, %w[repository commit build], "source")
  fail!("source.repository must be Diwamoto/clair") unless source["repository"] == "Diwamoto/clair"
  commit = nonempty_string!(source["commit"], "source.commit")
  fail!("source.commit must be a full Git commit SHA") unless commit.match?(/\A[0-9a-f]{40}\z/)
  build = object!(source["build"], "source.build")
  exact_keys!(build, %w[mode channel bundle_identifier], "source.build")
  fail!("source.build.mode must be release") unless build["mode"] == "release"
  unless ENGINE_BUILD_CHANNELS.include?(build["channel"])
    fail!("source.build.channel must be stable or dev")
  end
  bundle_id = nonempty_string!(build["bundle_identifier"], "source.build.bundle_identifier")
  unless bundle_id.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/) && !bundle_id.include?("..")
    fail!("source.build.bundle_identifier is unsafe")
  end

  environment = object!(result["environment"], "environment")
  exact_keys!(environment, %w[hardware os display session privacy], "environment")
  hardware = object!(environment["hardware"], "environment.hardware")
  exact_keys!(hardware, %w[architecture model memory_gib], "environment.hardware")
  fail!("environment.hardware.architecture must be arm64") unless hardware["architecture"] == "arm64"
  nonempty_string!(hardware["model"], "environment.hardware.model")
  positive_number!(hardware["memory_gib"], "environment.hardware.memory_gib")
  os = object!(environment["os"], "environment.os")
  exact_keys!(os, %w[name version], "environment.os")
  nonempty_string!(os["name"], "environment.os.name")
  nonempty_string!(os["version"], "environment.os.version")
  display = object!(environment["display"], "environment.display")
  exact_keys!(display, %w[identity window_points backing_scale refresh_rate_hz], "environment.display")
  nonempty_string!(display["identity"], "environment.display.identity")
  window = object!(display["window_points"], "environment.display.window_points")
  exact_keys!(window, %w[width height], "environment.display.window_points")
  %w[width height].each do |dimension|
    positive_number!(window[dimension], "environment.display.window_points.#{dimension}")
  end
  positive_number!(display["backing_scale"], "environment.display.backing_scale")
  positive_number!(display["refresh_rate_hz"], "environment.display.refresh_rate_hz")
  session = object!(environment["session"], "environment.session")
  exact_keys!(session, ["screen_locked"], "environment.session")
  fail!("environment.session.screen_locked must be false") unless session["screen_locked"] == false
  privacy = object!(environment["privacy"], "environment.privacy")
  %w[host_name_recorded user_name_recorded process_ids_recorded absolute_paths_recorded].each do |key|
    fail!("environment.privacy.#{key} must be false") unless privacy[key] == false
  end

  workload = object!(result["workload"], "workload")
  exact_keys!(workload, %w[metric_contract fixtures], "workload")
  identity = object!(workload["metric_contract"], "workload.metric_contract")
  exact_keys!(identity, %w[schema_version contract_id sha256], "workload.metric_contract")
  fail!("metric contract schema mismatch") unless identity["schema_version"] == contract["schema_version"]
  fail!("metric contract id mismatch") unless identity["contract_id"] == contract["contract_id"]
  fail!("metric contract SHA-256 mismatch") unless identity["sha256"] == contract_sha

  fixtures = array!(workload["fixtures"], "workload.fixtures")
  fail!("workload.fixtures must not be empty") if fixtures.empty?
  fixture_ids = fixtures.each_with_index.map do |fixture, index|
    location = "workload.fixtures[#{index}]"
    fixture = object!(fixture, location)
    exact_keys!(fixture, %w[id description bytes lines sha256], location)
    nonempty_string!(fixture["description"], "#{location}.description")
    positive_integer!(fixture["bytes"], "#{location}.bytes")
    positive_integer!(fixture["lines"], "#{location}.lines")
    sha256!(fixture["sha256"], "#{location}.sha256")
    nonempty_string!(fixture["id"], "#{location}.id")
  end
  fail!("workload.fixtures contains duplicate ids") unless fixture_ids.uniq.length == fixture_ids.length
  fixture_ids
end

def validate_engine_observations!(result, contract, fixture_ids)
  surfaces = object!(contract["surfaces"], "contract surfaces")
  metrics = object!(contract["metrics"], "contract metrics")
  minimum_max = positive_integer!(
    contract["minimum_sample_count_for_max"],
    "contract minimum_sample_count_for_max"
  )
  minimum_p95 = positive_integer!(
    contract.dig("percentile_rule", "minimum_sample_count"),
    "contract percentile_rule.minimum_sample_count"
  )

  observations = array!(result["observations"], "observations")
  fail!("observations must not be empty") if observations.empty?
  seen_ids = {}
  observations.each_with_index do |observation, index|
    location = "observations[#{index}]"
    observation = object!(observation, location)
    samples = array!(observation["samples"], "#{location}.samples")
    aggregation = array!(observation["aggregation"], "#{location}.aggregation")
    expected_keys = ENGINE_OBSERVATION_KEYS + [aggregation.last.to_s]
    exact_keys!(observation, expected_keys, location)

    observation_id = nonempty_string!(observation["id"], "#{location}.id")
    fail!("duplicate observation id #{observation_id}") if seen_ids[observation_id]
    seen_ids[observation_id] = true

    surface_id = nonempty_string!(observation["surface"], "#{location}.surface")
    fail!("#{location}.surface is unknown: #{surface_id}") unless surfaces.key?(surface_id)
    fixture_id = nonempty_string!(observation["fixture_id"], "#{location}.fixture_id")
    fail!("#{location}.fixture_id is unknown: #{fixture_id}") unless fixture_ids.include?(fixture_id)
    metric_name = nonempty_string!(observation["metric"], "#{location}.metric")
    metric = metrics[metric_name]
    fail!("#{location}.metric is unknown: #{metric_name}") unless metric
    unless Array(metric["surfaces"]).include?(surface_id)
      fail!("#{location}.metric #{metric_name} is not defined for #{surface_id}")
    end
    unless observation["unit"] == metric["unit"]
      fail!("#{location}.unit must equal #{metric['unit'].inspect}")
    end

    minimum = Array(metric["aggregation"]).include?("p95") ? minimum_p95 : minimum_max
    if samples.length < minimum
      fail!("#{location}.samples must contain at least #{minimum} values for #{metric_name}")
    end
    samples.each_with_index do |sample, sample_index|
      finite_nonnegative!(sample, "#{location}.samples[#{sample_index}]")
    end
    validate_engine_distribution!(observation, samples, location, contract, metric_name)

    provenance = object!(observation["provenance"], "#{location}.provenance")
    exact_keys!(provenance, %w[kind tool artifact_sha256], "#{location}.provenance")
    unless ENGINE_PROVENANCE_KINDS.include?(provenance["kind"])
      fail!("#{location}.provenance.kind must be manual, instruments, or automated")
    end
    nonempty_string!(provenance["tool"], "#{location}.provenance.tool")
    sha256!(provenance["artifact_sha256"], "#{location}.provenance.artifact_sha256")
  end
  observations
end

def validate_engine_summary!(result, contract, observations)
  surfaces = object!(contract["surfaces"], "contract surfaces")
  summary = object!(result["summary"], "summary")
  unless summary.keys.sort == surfaces.keys.sort
    fail!("summary must contain every contract surface exactly once")
  end

  expected_coverage = []
  surfaces.keys.each do |surface_id|
    surface_summary = object!(summary[surface_id], "summary.#{surface_id}")
    metric_names = engine_surface_metrics(contract, surface_id)
    unless surface_summary.keys.sort == metric_names.sort
      fail!("summary.#{surface_id} must contain every metric defined for that surface")
    end

    metric_names.each do |metric_name|
      location = "summary.#{surface_id}.#{metric_name}"
      entry = object!(surface_summary[metric_name], location)
      matching = observations.select do |observation|
        observation["surface"] == surface_id && observation["metric"] == metric_name
      end
      values = matching.flat_map { |observation| observation["samples"] }
      if values.empty?
        exact_keys!(entry, %w[status reason], location)
        fail!("#{location} must be not-measured without samples") unless entry["status"] == "not-measured"
        nonempty_string!(entry["reason"], "#{location}.reason")
        expected_coverage << {
          "surface" => surface_id,
          "metric" => metric_name,
          "status" => "not-measured",
          "reason" => entry["reason"]
        }
        next
      end

      aggregation = engine_expected_aggregation(contract, metric_name, values.length)
      expected_keys = %w[status unit median sample_count aggregation observation_ids] + [aggregation.last]
      exact_keys!(entry, expected_keys, location)
      fail!("#{location} must be measured with samples") unless entry["status"] == "measured"
      unless entry["unit"] == contract.dig("metrics", metric_name, "unit")
        fail!("#{location}.unit does not match the contract")
      end
      observation_ids = matching.map { |observation| observation["id"] }
      unless entry["observation_ids"] == observation_ids
        fail!("#{location}.observation_ids must list the matching observations in order")
      end
      validate_engine_distribution!(entry, values, location, contract, metric_name)
      expected_coverage << {
        "surface" => surface_id,
        "metric" => metric_name,
        "status" => "measured",
        "observation_ids" => observation_ids,
        "sample_count" => values.length
      }
    end
  end

  coverage = array!(result["coverage"], "coverage")
  unless coverage == expected_coverage
    fail!("coverage must restate every surface and metric with the same status as the summary")
  end
end

def validate_engine_baseline!(result, repo_root)
  contract, contract_sha = local_contract(repo_root, ENGINE_CONTRACT_PATH, "text engine metric contract")
  fixture_ids = validate_engine_identity!(result, contract, contract_sha)
  observations = validate_engine_observations!(result, contract, fixture_ids)
  validate_engine_summary!(result, contract, observations)
  scan_private_paths(result)
  result.dig("capture", "kind")
end

result_path = ARGV.fetch(0) do
  warn "usage: validate-result.rb RESULT.json"
  exit 2
end
fail!("unexpected arguments") unless ARGV.length == 1

begin
  result = JSON.parse(File.read(result_path))
rescue JSON::ParserError, Errno::ENOENT => error
  fail!(error.message)
end

repo_root = File.expand_path("../..", __dir__)

# Two profiles share this validator. The default profile is the ccedit V1 parity
# capture used by L01. Results that declare the text engine profile are the
# ADR-0014 surface baselines: the same identity, raw-sample, and aggregation
# discipline, against the text engine metric contract instead.
if result.is_a?(Hash) && result["profile"] == ENGINE_BASELINE_PROFILE
  capture_kind = validate_engine_baseline!(result, repo_root)
  puts "valid text engine baseline (#{capture_kind}): #{result_path}"
  exit 0
end

metric_contract, metric_contract_sha = local_contract(repo_root, "docs/benchmarks/metric-contract.json", "metric contract")
operation_script, operation_script_sha = local_contract(repo_root, "docs/benchmarks/workloads/v1-parity-operation-script.json", "operation script")

result = object!(result, "result")
required_top_level = %w[schema_version source environment workload runs summary coverage]
allowed_top_level = required_top_level + ["evidence"]
unless (required_top_level - result.keys).empty? && (result.keys - allowed_top_level).empty?
  fail!("top-level keys must be #{required_top_level.join(', ')} with optional evidence")
end
fail!("schema_version must be 1") unless result["schema_version"] == 1

source = object!(result["source"], "source")
fail!("source.repository must be Diwamoto/ccedit") unless source["repository"] == "Diwamoto/ccedit"
fail!("source.commit must be the pinned V1 commit") unless source["commit"] == PINNED_COMMIT
build = object!(source["build"], "source.build")
fail!("source.build.mode must be release") unless build["mode"] == "release"
bundle_id = nonempty_string!(build["bundle_identifier"], "source.build.bundle_identifier")
fail!("normal ccedit bundle identifiers are forbidden") if NORMAL_BUNDLE_IDS.include?(bundle_id)
unless bundle_id.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\z/) && !bundle_id.include?("..")
  fail!("source.build.bundle_identifier is unsafe")
end
unless build["executable_sha256"].is_a?(String) && build["executable_sha256"].match?(/\A[0-9a-f]{64}\z/)
  fail!("source.build.executable_sha256 must be lowercase SHA-256")
end
identity_override = object!(build["identity_override"], "source.build.identity_override")
fail!("identity_override.from must be dev.daiki.ccedit") unless identity_override["from"] == "dev.daiki.ccedit"
fail!("identity_override.to must equal bundle_identifier") unless identity_override["to"] == bundle_id

environment = object!(result["environment"], "environment")
fail!("environment hardware architecture must be arm64") unless environment.dig("hardware", "architecture") == "arm64"
session_locked = environment.dig("session", "screen_locked")
unless session_locked == true || session_locked == false || (session_locked.is_a?(Hash) && session_locked["status"] == "not-measured")
  fail!("environment.session.screen_locked must be boolean or not-measured")
end
display = object!(environment["display"], "environment.display")
case display["status"]
when "not-measured"
  nonempty_string!(display["reason"], "environment.display.reason")
when "measured"
  nonempty_string!(display["identity"], "environment.display.identity")
  expected_window = object!(
    operation_script.dig("comparison_identity", "window_points"),
    "operation script comparison_identity.window_points"
  )
  measured_window = object!(display["window_points"], "environment.display.window_points")
  %w[width height].each do |dimension|
    expected = positive_number!(
      expected_window[dimension],
      "operation script comparison_identity.window_points.#{dimension}"
    )
    actual = positive_number!(
      measured_window[dimension],
      "environment.display.window_points.#{dimension}"
    )
    fail!("environment.display.window_points.#{dimension} must equal #{expected}") unless actual == expected
  end
  positive_number!(display["backing_scale"], "environment.display.backing_scale")
  positive_number!(display["refresh_rate_hz"], "environment.display.refresh_rate_hz")
else
  fail!("environment.display.status must be measured or not-measured")
end
privacy = object!(environment["privacy"], "environment.privacy")
%w[host_name_recorded user_name_recorded process_ids_recorded absolute_paths_recorded].each do |key|
  fail!("environment.privacy.#{key} must be false") unless privacy[key] == false
end
fail!("benchmark storage must not pre-exist") unless privacy["benchmark_storage_preexisting"] == false
fail!("benchmark storage cleanup must be recorded") unless privacy["benchmark_storage_cleaned_after_capture"] == true

workload = object!(result["workload"], "workload")
corpus = object!(workload["corpus"], "workload.corpus")
fail!("corpus manifest_version must be 1") unless corpus["manifest_version"] == 1
fail!("corpus generator_version must be 1") unless corpus["generator_version"].to_s == "1"
unless corpus["manifest_sha256"].is_a?(String) && corpus["manifest_sha256"].match?(/\A[0-9a-f]{64}\z/)
  fail!("corpus manifest_sha256 must be lowercase SHA-256")
end
fail!("corpus manifest_file_count must be 10011") unless corpus["manifest_file_count"] == 10_011
fail!("corpus file_tree_profile is wrong") unless corpus["file_tree_profile"] == {
  "files" => 10_000,
  "directories" => 200,
  "levels_below_root" => 3
}

operation_identity = object!(workload["operation_script"], "workload.operation_script")
fail!("operation script schema mismatch") unless operation_identity["schema_version"] == operation_script["schema_version"]
fail!("operation workload_id mismatch") unless operation_identity["workload_id"] == operation_script["workload_id"]
fail!("operation script SHA-256 mismatch") unless operation_identity["sha256"] == operation_script_sha

contract_identity = object!(workload["metric_contract"], "workload.metric_contract")
fail!("metric contract schema mismatch") unless contract_identity["schema_version"] == metric_contract["schema_version"]
fail!("metric contract id mismatch") unless contract_identity["contract_id"] == metric_contract["contract_id"]
fail!("metric contract SHA-256 mismatch") unless contract_identity["sha256"] == metric_contract_sha

canonical_metrics = object!(metric_contract["metrics"], "metric contract metrics")
canonical_names = canonical_metrics.keys
fail!("metric contract must define metrics") if canonical_names.empty?
operation_actions = array!(operation_script["actions"], "operation script actions")
action_ids = operation_actions.map.with_index do |action, index|
  nonempty_string!(object!(action, "operation script actions[#{index}]")["id"], "operation script actions[#{index}].id")
end
fail!("operation script contains duplicate action IDs") unless action_ids.uniq.length == action_ids.length

trial_policy = object!(workload["trial_policy"], "workload.trial_policy")
measured_trials = object!(trial_policy["measured_trials"], "workload.trial_policy.measured_trials")
expected_kind_counts = {}
ALLOWED_LAUNCH_KINDS.each do |kind|
  expected_kind_counts[kind] = positive_integer!(measured_trials[kind], "measured_trials.#{kind}")
end
positive_integer!(trial_policy["idle_sample_count_per_run"], "trial_policy.idle_sample_count_per_run")
positive_integer!(trial_policy["idle_sample_interval_seconds"], "trial_policy.idle_sample_interval_seconds")

runs = array!(result["runs"], "runs")
fail!("runs must not be empty") if runs.empty?
fail!("run count does not match trial policy") unless runs.length == expected_kind_counts.values.sum
seen_run_ids = {}

runs.each_with_index do |run, run_index|
  location = "runs[#{run_index}]"
  run = object!(run, location)
  run_id = nonempty_string!(run["id"], "#{location}.id")
  fail!("duplicate run id #{run_id}") if seen_run_ids[run_id]
  seen_run_ids[run_id] = true
  launch_kind = run["launch_kind"]
  fail!("#{location}.launch_kind is invalid") unless ALLOWED_LAUNCH_KINDS.include?(launch_kind)
  fail!("#{location}.id does not match launch_kind") unless run_id.match?(/\A#{Regexp.escape(launch_kind)}-\d{2}\z/)
  fail!("#{location}.status is invalid") unless ALLOWED_RUN_STATUSES.include?(run["status"])

  metrics = object!(run["metrics"], "#{location}.metrics")
  fail!("#{location}.metrics must match the canonical metric set") unless metrics.keys == canonical_names
  canonical_names.each do |metric_name|
    validate_metric!(metrics[metric_name], "#{location}.metrics.#{metric_name}", canonical_metrics.dig(metric_name, "unit"))
  end

  samples = array!(run["process_samples"], "#{location}.process_samples")
  previous_sample = 0
  previous_offset = -1
  samples.each_with_index do |sample, sample_index|
    sample_location = "#{location}.process_samples[#{sample_index}]"
    sample = object!(sample, sample_location)
    fail!("#{sample_location}.sample must increase by one") unless sample["sample"] == previous_sample + 1
    unless sample["offset_seconds"].is_a?(Integer) && sample["offset_seconds"] > previous_offset
      fail!("#{sample_location}.offset_seconds must increase")
    end
    finite_nonnegative!(sample["rss_mib"], "#{sample_location}.rss_mib")
    finite_nonnegative!(sample["cpu_percent"], "#{sample_location}.cpu_percent")
    positive_integer!(sample["process_count"], "#{sample_location}.process_count")
    previous_sample = sample["sample"]
    previous_offset = sample["offset_seconds"]
  end
  if run["status"] == "measured" && samples.length != trial_policy["idle_sample_count_per_run"]
    fail!("#{location} is measured but has incomplete process samples")
  end

  AUTOMATED_RESOURCE_FIELDS.each do |metric_name, (field, _unit)|
    metric = metrics[metric_name]
    values = samples.map { |sample| sample[field] }
    if values.empty?
      fail!("#{location}.metrics.#{metric_name} must be not-measured without samples") unless metric["status"] == "not-measured"
    else
      fail!("#{location}.metrics.#{metric_name} must be measured with samples") unless metric["status"] == "measured"
      p95_allowed = canonical_metrics.dig(metric_name, "aggregation").include?("p95")
      validate_distribution!(metric, values, "#{location}.metrics.#{metric_name}", p95_allowed: p95_allowed)
    end
  end

  phases = array!(run["perf_phases"], "#{location}.perf_phases")
  phases.each_with_index do |phase, phase_index|
    phase_location = "#{location}.perf_phases[#{phase_index}]"
    phase = object!(phase, phase_location)
    nonempty_string!(phase["phase"], "#{phase_location}.phase")
    fail!("#{phase_location}.phase is unsafe") unless phase["phase"].match?(/\A[A-Za-z0-9_.:-]{1,128}\z/)
    finite_nonnegative!(phase["value"], "#{phase_location}.value")
    fail!("#{phase_location}.unit must be ms") unless phase["unit"] == "ms"
  end

  AUTOMATED_PHASES.each do |metric_name, phase_name|
    phase = phases.find { |candidate| candidate["phase"] == phase_name }
    metric = metrics[metric_name]
    if phase
      fail!("#{location}.metrics.#{metric_name} must be measured") unless metric["status"] == "measured"
      expected = phase_name == "fe.first_paint_after_raf" ? phase.fetch("since_load_ms", phase["value"]) : phase["value"]
      close!(metric["value"], expected, "#{location}.metrics.#{metric_name}.value")
    else
      fail!("#{location}.metrics.#{metric_name} must be not-measured without its phase") unless metric["status"] == "not-measured"
    end
  end
end

expected_kind_counts.each do |kind, expected_count|
  actual_count = runs.count { |run| run["launch_kind"] == kind }
  fail!("#{kind} run count is #{actual_count}, expected #{expected_count}") unless actual_count == expected_count
end

evidence_observations = []
evidence_by_metric = {}
if result.key?("evidence")
  fail!("result with evidence must record an explicitly unlocked session") unless session_locked == false
  fail!("result with evidence must record a measured display") unless display["status"] == "measured"

  evidence = object!(result["evidence"], "evidence")
  exact_keys!(evidence, %w[schema_version base_sha256 identity environment observations], "evidence")
  fail!("evidence.schema_version must be 1") unless evidence["schema_version"] == 1
  sha256!(evidence["base_sha256"], "evidence.base_sha256")

  evidence_identity = object!(evidence["identity"], "evidence.identity")
  exact_keys!(
    evidence_identity,
    %w[source corpus_manifest_sha256 operation_script_sha256 metric_contract_sha256],
    "evidence.identity"
  )
  fail!("evidence source identity does not match result.source") unless evidence_identity["source"] == source
  evidence_identity_checks = {
    "corpus_manifest_sha256" => corpus["manifest_sha256"],
    "operation_script_sha256" => operation_identity["sha256"],
    "metric_contract_sha256" => contract_identity["sha256"]
  }
  evidence_identity_checks.each do |key, expected|
    actual = sha256!(evidence_identity[key], "evidence.identity.#{key}")
    fail!("evidence.identity.#{key} does not match the result") unless actual == expected
  end

  evidence_environment = object!(evidence["environment"], "evidence.environment")
  exact_keys!(evidence_environment, %w[hardware os session display], "evidence.environment")
  fail!("evidence hardware identity does not match the result") unless
    evidence_environment["hardware"] == environment["hardware"]
  fail!("evidence OS identity does not match the result") unless evidence_environment["os"] == environment["os"]
  evidence_session = object!(evidence_environment["session"], "evidence.environment.session")
  exact_keys!(evidence_session, ["screen_locked"], "evidence.environment.session")
  fail!("evidence session must be explicitly unlocked") unless evidence_session["screen_locked"] == false
  fail!("evidence display identity does not match the result") unless evidence_environment["display"] == display

  seen_evidence_ids = {}
  evidence_observations = array!(evidence["observations"], "evidence.observations")
  fail!("evidence.observations must not be empty") if evidence_observations.empty?
  evidence_observations.each_with_index do |observation, index|
    location = "evidence.observations[#{index}]"
    observation = object!(observation, location)
    exact_keys!(
      observation,
      %w[id captured_at_utc action_id metric unit samples provenance],
      location
    )
    evidence_id = nonempty_string!(observation["id"], "#{location}.id")
    fail!("duplicate evidence observation ID #{evidence_id}") if seen_evidence_ids[evidence_id]
    seen_evidence_ids[evidence_id] = true
    rfc3339!(observation["captured_at_utc"], "#{location}.captured_at_utc")

    action_id = nonempty_string!(observation["action_id"], "#{location}.action_id")
    fail!("#{location}.action_id is unknown: #{action_id}") unless action_ids.include?(action_id)
    metric_name = nonempty_string!(observation["metric"], "#{location}.metric")
    metric_contract_entry = canonical_metrics[metric_name]
    fail!("#{location}.metric is unknown: #{metric_name}") unless metric_contract_entry
    fail!("#{location}.unit must equal #{metric_contract_entry['unit'].inspect}") unless
      observation["unit"] == metric_contract_entry["unit"]

    samples = array!(observation["samples"], "#{location}.samples")
    minimum_samples = if metric_contract_entry["aggregation"].include?("p95")
      metric_contract.dig("percentile_rule", "minimum_sample_count")
    else
      5
    end
    positive_integer!(minimum_samples, "metric contract minimum sample count")
    fail!("#{location}.samples must contain at least #{minimum_samples} values") if samples.length < minimum_samples
    samples.each_with_index do |sample, sample_index|
      finite_nonnegative!(sample, "#{location}.samples[#{sample_index}]")
    end

    provenance = object!(observation["provenance"], "#{location}.provenance")
    exact_keys!(provenance, %w[kind tool artifact_sha256], "#{location}.provenance")
    unless ALLOWED_PROVENANCE_KINDS.include?(provenance["kind"])
      fail!("#{location}.provenance.kind must be manual or instruments")
    end
    nonempty_string!(provenance["tool"], "#{location}.provenance.tool")
    sha256!(provenance["artifact_sha256"], "#{location}.provenance.artifact_sha256")
  end
  evidence_by_metric = evidence_observations.group_by { |observation| observation["metric"] }
end

summary = object!(result["summary"], "summary")
fail!("summary must match the canonical metric set") unless summary.keys == canonical_names
canonical_names.each do |metric_name|
  validate_metric!(summary[metric_name], "summary.#{metric_name}", canonical_metrics.dig(metric_name, "unit"))
end

canonical_names.each do |metric_name|
  metric = summary[metric_name]
  if AUTOMATED_RESOURCE_FIELDS.key?(metric_name)
    field = AUTOMATED_RESOURCE_FIELDS.fetch(metric_name).first
    run_values = runs.flat_map { |run| run["process_samples"].map { |sample| sample[field] } }
  else
    run_values = runs.each_with_object([]) do |run, measured_values|
      run_metric = run.dig("metrics", metric_name)
      measured_values << run_metric["value"] if run_metric && run_metric["status"] == "measured"
    end
  end
  metric_evidence = evidence_by_metric.fetch(metric_name, [])
  evidence_values = metric_evidence.flat_map { |observation| observation["samples"] }
  if run_values.any? && evidence_values.any?
    fail!("metric #{metric_name} must be sourced by runs or evidence, not both")
  end
  values = evidence_values.any? ? evidence_values : run_values
  if values.empty?
    fail!("summary.#{metric_name} must be not-measured without run or evidence samples") unless
      metric["status"] == "not-measured"
    next
  end
  fail!("summary.#{metric_name} must be measured with run or evidence samples") unless metric["status"] == "measured"

  p95_allowed = canonical_metrics.dig(metric_name, "aggregation").include?("p95")
  validate_distribution!(metric, values, "summary.#{metric_name}", p95_allowed: p95_allowed)

  if evidence_values.any?
    fail!("summary.#{metric_name} must not contain by_launch_kind for evidence samples") if metric.key?("by_launch_kind")
    expected_evidence_ids = metric_evidence.map { |observation| observation["id"] }
    fail!("summary.#{metric_name}.evidence_ids is wrong") unless metric["evidence_ids"] == expected_evidence_ids
    by_action = object!(metric["by_action"], "summary.#{metric_name}.by_action")
    observations_by_action = metric_evidence.group_by { |observation| observation["action_id"] }
    unless by_action.keys.sort == observations_by_action.keys.sort
      fail!("summary.#{metric_name}.by_action keys do not match evidence actions")
    end
    observations_by_action.each do |action_id, action_observations|
      distribution = object!(by_action[action_id], "summary.#{metric_name}.by_action.#{action_id}")
      action_values = action_observations.flat_map { |observation| observation["samples"] }
      validate_distribution!(
        distribution,
        action_values,
        "summary.#{metric_name}.by_action.#{action_id}",
        p95_allowed: p95_allowed
      )
      expected_action_evidence_ids = action_observations.map { |observation| observation["id"] }
      unless distribution["evidence_ids"] == expected_action_evidence_ids
        fail!("summary.#{metric_name}.by_action.#{action_id}.evidence_ids is wrong")
      end
    end
    next
  end

  fail!("summary.#{metric_name} must not contain evidence metadata without evidence samples") if
    metric.key?("evidence_ids") || metric.key?("by_action")
  next unless metric.key?("by_launch_kind")

  by_kind = object!(metric["by_launch_kind"], "summary.#{metric_name}.by_launch_kind")
  by_kind.each do |kind, distribution|
    fail!("summary.#{metric_name} has invalid launch kind") unless ALLOWED_LAUNCH_KINDS.include?(kind)
    kind_values = runs.each_with_object([]) do |run, measured_values|
      next unless run["launch_kind"] == kind
      run_metric = run.dig("metrics", metric_name)
      measured_values << run_metric["value"] if run_metric && run_metric["status"] == "measured"
    end
    distribution = object!(distribution, "summary.#{metric_name}.by_launch_kind.#{kind}")
    synthetic_metric = distribution.merge(
      "status" => "measured",
      "value" => distribution["median"],
      "unit" => metric["unit"]
    )
    validate_distribution!(
      synthetic_metric,
      kind_values,
      "summary.#{metric_name}.by_launch_kind.#{kind}",
      p95_allowed: p95_allowed
    )
  end
end

coverage = array!(result["coverage"], "coverage")
unless coverage.map { |entry| entry["metric"] } == canonical_names
  fail!("coverage must contain each canonical metric exactly once")
end
coverage.each_with_index do |entry, index|
  entry = object!(entry, "coverage[#{index}]")
  metric_name = entry["metric"]
  summary_metric = summary[metric_name]
  fail!("coverage status differs from summary for #{metric_name}") unless entry["status"] == summary_metric["status"]
  if entry["status"] == "measured"
    metric_evidence = evidence_by_metric.fetch(metric_name, [])
    if metric_evidence.any?
      exact_keys!(entry, %w[metric status evidence_ids actions sample_count], "coverage[#{index}]")
      expected_evidence_ids = metric_evidence.map { |observation| observation["id"] }
      fail!("coverage evidence_ids is wrong for #{metric_name}") unless entry["evidence_ids"] == expected_evidence_ids
      expected_actions = metric_evidence.map { |observation| observation["action_id"] }.uniq
      fail!("coverage actions is wrong for #{metric_name}") unless entry["actions"] == expected_actions
      expected_sample_count = metric_evidence.sum { |observation| observation["samples"].length }
      fail!("coverage sample_count is wrong for #{metric_name}") unless entry["sample_count"] == expected_sample_count
    else
      measured_runs_count = runs.count { |run| run.dig("metrics", metric_name, "status") == "measured" }
      fail!("coverage measured_runs is wrong for #{metric_name}") unless entry["measured_runs"] == measured_runs_count
      fail!("coverage total_runs is wrong for #{metric_name}") unless entry["total_runs"] == runs.length
    end
  else
    nonempty_string!(entry["reason"], "coverage[#{index}].reason")
  end
end

scan_private_paths(result)

puts "valid benchmark result: #{result_path}"
