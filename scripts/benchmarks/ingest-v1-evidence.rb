#!/usr/bin/env ruby

require "digest"
require "json"
require "open3"
require "optparse"
require "rbconfig"
require "time"

ALLOWED_PROVENANCE_KINDS = %w[manual instruments].freeze
SHA256_PATTERN = /\A[0-9a-f]{64}\z/

def fail!(message)
  warn "invalid V1 evidence: #{message}"
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

def positive_number!(value, location)
  unless value.is_a?(Numeric) && value.finite? && value.positive?
    fail!("#{location} must be a finite positive number")
  end
  value
end

def nonnegative_number!(value, location)
  unless value.is_a?(Numeric) && value.finite? && value >= 0
    fail!("#{location} must be a finite non-negative number")
  end
  value.to_f
end

def read_json(path, location)
  raw = File.binread(path)
  [object!(JSON.parse(raw), location), raw]
rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => error
  fail!("cannot read #{location}: #{error.message}")
end

def deep_copy(value)
  JSON.parse(JSON.generate(value))
end

def median(values)
  ordered = values.sort
  middle = ordered.length / 2
  ordered.length.odd? ? ordered[middle] : (ordered[middle - 1] + ordered[middle]) / 2.0
end

def nearest_rank_p95(values)
  ordered = values.sort
  ordered[(0.95 * ordered.length).ceil - 1]
end

def summarize(values, contract)
  summary = {
    "value" => median(values),
    "unit" => contract.fetch("unit"),
    "sample_count" => values.length
  }
  if contract.fetch("aggregation").include?("p95")
    summary["aggregation"] = %w[median p95]
    summary["p95"] = nearest_rank_p95(values)
  else
    summary["aggregation"] = %w[median max]
    summary["max"] = values.max
  end
  summary
end

def scan_private_paths(value, location = "evidence")
  case value
  when Hash
    value.each { |key, child| scan_private_paths(child, "#{location}.#{key}") }
  when Array
    value.each_with_index { |child, index| scan_private_paths(child, "#{location}[#{index}]") }
  when String
    if value.include?("/Users/") || value.include?("/private/tmp/") || value.match?(%r{(?:^|\s)/tmp/})
      fail!("#{location} contains a private host-local path")
    end
  end
end

def validate_display!(display, expected_window, location)
  display = object!(display, location)
  exact_keys!(display, %w[status identity window_points backing_scale refresh_rate_hz], location)
  fail!("#{location}.status must be measured") unless display["status"] == "measured"
  nonempty_string!(display["identity"], "#{location}.identity")

  measured_window = object!(display["window_points"], "#{location}.window_points")
  exact_keys!(measured_window, %w[width height], "#{location}.window_points")
  %w[width height].each do |dimension|
    expected = positive_number!(expected_window[dimension], "operation contract window_points.#{dimension}")
    actual = positive_number!(measured_window[dimension], "#{location}.window_points.#{dimension}")
    fail!("#{location}.window_points.#{dimension} must equal #{expected}") unless actual == expected
  end
  positive_number!(display["backing_scale"], "#{location}.backing_scale")
  positive_number!(display["refresh_rate_hz"], "#{location}.refresh_rate_hz")
  display
end

options = {}
parser = OptionParser.new do |option_parser|
  option_parser.banner = "Usage: ingest-v1-evidence.rb --base automated.json --evidence ui-evidence.json --output baseline.json"
  option_parser.on("--base PATH", "Validated automated baseline JSON") { |path| options[:base] = path }
  option_parser.on("--evidence PATH", "Unlocked manual/Instruments evidence JSON") { |path| options[:evidence] = path }
  option_parser.on("--output PATH", "New combined baseline JSON; must not exist") { |path| options[:output] = path }
end

begin
  parser.parse!
rescue OptionParser::ParseError => error
  warn error.message
  warn parser
  exit 2
end
unless ARGV.empty? && %i[base evidence output].all? { |key| options[key] }
  warn parser
  exit 2
end

output_path = options.fetch(:output)
fail!("refusing to overwrite output #{output_path}") if File.exist?(output_path) || File.symlink?(output_path)
output_parent = File.dirname(File.expand_path(output_path))
fail!("output parent is not a directory: #{output_parent}") unless File.directory?(output_parent)

base, base_raw = read_json(options.fetch(:base), "base result")
evidence, = read_json(options.fetch(:evidence), "evidence")

repo_root = File.expand_path("../..", __dir__)
validator_path = File.join(__dir__, "validate-result.rb")
_validator_stdout, validator_stderr, validator_status = Open3.capture3(
  RbConfig.ruby,
  validator_path,
  options.fetch(:base),
  chdir: repo_root
)
unless validator_status.success?
  detail = validator_stderr.strip
  fail!("base result does not pass validate-result.rb#{detail.empty? ? '' : ": #{detail}"}")
end

metric_contract, metric_contract_raw = read_json(
  File.join(repo_root, "docs/benchmarks/metric-contract.json"),
  "metric contract"
)
operation_contract, operation_contract_raw = read_json(
  File.join(repo_root, "docs/benchmarks/workloads/v1-parity-operation-script.json"),
  "operation contract"
)
metrics = object!(metric_contract["metrics"], "metric contract metrics")
actions = array!(operation_contract["actions"], "operation contract actions")
action_ids = actions.map { |action| nonempty_string!(object!(action, "operation action")["id"], "operation action.id") }
fail!("operation contract contains duplicate action IDs") unless action_ids.uniq.length == action_ids.length
expected_window = object!(operation_contract.dig("comparison_identity", "window_points"), "operation contract window_points")

base_session = object!(base.dig("environment", "session"), "base result environment.session")
unless base_session["screen_locked"] == false
  fail!("base result session must be explicitly unlocked")
end

exact_keys!(evidence, %w[schema_version base_sha256 identity environment observations], "evidence")
fail!("evidence.schema_version must be 1") unless evidence["schema_version"] == 1
scan_private_paths(evidence)

expected_base_sha = Digest::SHA256.hexdigest(base_raw)
actual_base_sha = sha256!(evidence["base_sha256"], "evidence.base_sha256")
fail!("evidence.base_sha256 does not match the base result") unless actual_base_sha == expected_base_sha

identity = object!(evidence["identity"], "evidence.identity")
exact_keys!(
  identity,
  %w[source corpus_manifest_sha256 operation_script_sha256 metric_contract_sha256],
  "evidence.identity"
)
fail!("evidence source identity does not match the base result") unless identity["source"] == base["source"]

identity_checks = {
  "corpus_manifest_sha256" => base.dig("workload", "corpus", "manifest_sha256"),
  "operation_script_sha256" => base.dig("workload", "operation_script", "sha256"),
  "metric_contract_sha256" => base.dig("workload", "metric_contract", "sha256")
}
identity_checks.each do |key, expected|
  actual = sha256!(identity[key], "evidence.identity.#{key}")
  fail!("evidence.identity.#{key} does not match the base result") unless actual == expected
end
fail!("base metric contract SHA-256 does not match the repository contract") unless
  identity["metric_contract_sha256"] == Digest::SHA256.hexdigest(metric_contract_raw)
fail!("base operation script SHA-256 does not match the repository contract") unless
  identity["operation_script_sha256"] == Digest::SHA256.hexdigest(operation_contract_raw)

evidence_environment = object!(evidence["environment"], "evidence.environment")
exact_keys!(evidence_environment, %w[hardware os session display], "evidence.environment")
fail!("evidence hardware identity does not match the base result") unless
  evidence_environment["hardware"] == base.dig("environment", "hardware")
fail!("evidence OS identity does not match the base result") unless
  evidence_environment["os"] == base.dig("environment", "os")
evidence_session = object!(evidence_environment["session"], "evidence.environment.session")
exact_keys!(evidence_session, ["screen_locked"], "evidence.environment.session")
unless evidence_session["screen_locked"] == false
  fail!("evidence session must be explicitly unlocked")
end
evidence_display = validate_display!(evidence_environment["display"], expected_window, "evidence.environment.display")

base_display = object!(base.dig("environment", "display"), "base result environment.display")
if base_display["status"] == "measured"
  validate_display!(base_display, expected_window, "base result environment.display")
  fail!("evidence display identity does not match the base result") unless base_display == evidence_display
elsif base_display["status"] != "not-measured"
  fail!("base result display status must be measured or not-measured")
end

observations = array!(evidence["observations"], "evidence.observations")
fail!("evidence.observations must not be empty") if observations.empty?
seen_ids = {}
normalized_observations = observations.each_with_index.map do |observation, index|
  location = "evidence.observations[#{index}]"
  observation = object!(observation, location)
  allowed_keys = %w[id captured_at_utc action_id metric unit samples provenance]
  fail!("#{location} has unknown keys") unless (observation.keys - allowed_keys).empty?
  %w[id captured_at_utc action_id metric unit samples provenance].each do |key|
    fail!("#{location}.#{key} is required") unless observation.key?(key)
  end

  id = nonempty_string!(observation["id"], "#{location}.id")
  fail!("duplicate evidence observation ID #{id}") if seen_ids[id]
  seen_ids[id] = true
  captured_at_utc = rfc3339!(observation["captured_at_utc"], "#{location}.captured_at_utc")
  action_id = nonempty_string!(observation["action_id"], "#{location}.action_id")
  fail!("#{location}.action_id is unknown: #{action_id}") unless action_ids.include?(action_id)
  metric_name = nonempty_string!(observation["metric"], "#{location}.metric")
  metric = metrics[metric_name]
  fail!("#{location}.metric is unknown: #{metric_name}") unless metric
  unit = nonempty_string!(observation["unit"], "#{location}.unit")
  fail!("#{location}.unit must equal #{metric.fetch('unit').inspect}") unless unit == metric.fetch("unit")

  samples = array!(observation["samples"], "#{location}.samples")
  minimum_samples = metric.fetch("aggregation").include?("p95") ?
    metric_contract.dig("percentile_rule", "minimum_sample_count") : 5
  unless minimum_samples.is_a?(Integer) && minimum_samples.positive?
    fail!("metric contract minimum sample count is invalid")
  end
  fail!("#{location}.samples must contain at least #{minimum_samples} values") if samples.length < minimum_samples
  samples = samples.each_with_index.map do |sample, sample_index|
    nonnegative_number!(sample, "#{location}.samples[#{sample_index}]")
  end

  normalized = {
    "id" => id,
    "captured_at_utc" => captured_at_utc,
    "action_id" => action_id,
    "metric" => metric_name,
    "unit" => unit,
    "samples" => samples
  }
  provenance = object!(observation["provenance"], "#{location}.provenance")
  exact_keys!(provenance, %w[kind tool artifact_sha256], "#{location}.provenance")
  fail!("#{location}.provenance.kind must be manual or instruments") unless
    ALLOWED_PROVENANCE_KINDS.include?(provenance["kind"])
  nonempty_string!(provenance["tool"], "#{location}.provenance.tool")
  sha256!(provenance["artifact_sha256"], "#{location}.provenance.artifact_sha256")
  normalized["provenance"] = deep_copy(provenance)
  normalized
end

output = deep_copy(base)
output["environment"]["session"]["screen_locked"] = false
output["environment"]["display"] = deep_copy(evidence_display)
output["evidence"] = {
  "schema_version" => 1,
  "base_sha256" => expected_base_sha,
  "identity" => deep_copy(identity),
  "environment" => deep_copy(evidence_environment),
  "observations" => normalized_observations
}

normalized_observations.group_by { |observation| observation["metric"] }.each do |metric_name, metric_observations|
  if base.dig("summary", metric_name, "status") == "measured"
    fail!("evidence metric #{metric_name} is already measured by the base result")
  end

  contract = metrics.fetch(metric_name)
  values = metric_observations.flat_map { |observation| observation["samples"] }
  metric_summary = summarize(values, contract).merge(
    "status" => "measured",
    "evidence_ids" => metric_observations.map { |observation| observation["id"] }
  )
  metric_summary["by_action"] = metric_observations.group_by { |observation| observation["action_id"] }.transform_values do |action_observations|
    action_values = action_observations.flat_map { |observation| observation["samples"] }
    summarize(action_values, contract).merge(
      "evidence_ids" => action_observations.map { |observation| observation["id"] }
    )
  end
  output["summary"][metric_name] = metric_summary

  coverage_index = output["coverage"].index { |entry| entry["metric"] == metric_name }
  fail!("base coverage is missing #{metric_name}") unless coverage_index
  output["coverage"][coverage_index] = {
    "metric" => metric_name,
    "status" => "measured",
    "evidence_ids" => metric_observations.map { |observation| observation["id"] },
    "actions" => metric_observations.map { |observation| observation["action_id"] }.uniq,
    "sample_count" => values.length
  }
end

fail!("base runs changed during evidence ingestion") unless output["runs"] == base["runs"]
scan_private_paths(output["evidence"], "output.evidence")

payload = JSON.pretty_generate(output) + "\n"
begin
  File.open(output_path, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |file| file.write(payload) }
rescue Errno::EEXIST
  fail!("refusing to overwrite output #{output_path}")
rescue Errno::EACCES, Errno::ENOENT => error
  fail!("cannot write output: #{error.message}")
end

puts "ingested #{normalized_observations.length} V1 evidence observations into #{output_path}"
