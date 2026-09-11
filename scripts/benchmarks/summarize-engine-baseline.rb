#!/usr/bin/env ruby
# frozen_string_literal: true

# Aggregates raw text-surface samples into a baseline result for the ADR-0014
# engine program. The operator records identity, fixtures, and raw samples; this
# script derives every median, p95, max, summary, and coverage entry, so the
# aggregation can never disagree with the samples it came from.
#
#   scripts/benchmarks/summarize-engine-baseline.rb SAMPLES.json [RESULT.json]
#
# Validate the output with scripts/benchmarks/validate-result.rb.

require "digest"
require "json"

CONTRACT_PATH = "docs/benchmarks/text-engine-metric-contract.json"
PROFILE = "clair-text-engine-baseline"

def fail!(message)
  warn "cannot summarize engine baseline: #{message}"
  exit 1
end

def fetch!(hash, key, location)
  fail!("#{location} must be an object") unless hash.is_a?(Hash)
  fail!("#{location}.#{key} is required") unless hash.key?(key)
  hash.fetch(key)
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

def rounded(value)
  (value.to_f * 1000).round / 1000.0
end

def distribution(contract, metric_name, values)
  metric = contract.fetch("metrics").fetch(metric_name)
  minimum = contract.dig("percentile_rule", "minimum_sample_count")
  entry = { "median" => rounded(median(values)), "sample_count" => values.length }
  if Array(metric["aggregation"]).include?("p95") && values.length >= minimum
    entry["aggregation"] = %w[median p95]
    entry["p95"] = rounded(nearest_rank_p95(values))
  else
    entry["aggregation"] = %w[median max]
    entry["max"] = rounded(values.map(&:to_f).max)
  end
  entry
end

input_path = ARGV.fetch(0) do
  warn "usage: summarize-engine-baseline.rb SAMPLES.json [RESULT.json]"
  exit 2
end
output_path = ARGV[1]
fail!("unexpected arguments") if ARGV.length > 2

begin
  raw = JSON.parse(File.read(input_path))
rescue JSON::ParserError, Errno::ENOENT => error
  fail!(error.message)
end
fail!("samples must be an object") unless raw.is_a?(Hash)
fail!("samples profile must be #{PROFILE}") unless raw["profile"] == PROFILE

repo_root = File.expand_path("../..", __dir__)
begin
  contract_bytes = File.binread(File.join(repo_root, CONTRACT_PATH))
  contract = JSON.parse(contract_bytes)
rescue Errno::ENOENT, JSON::ParserError => error
  fail!("cannot load the text engine metric contract: #{error.message}")
end
contract_sha = Digest::SHA256.hexdigest(contract_bytes)
contract_metrics = contract.fetch("metrics")
contract_surfaces = contract.fetch("surfaces")

workload = fetch!(raw, "workload", "samples")
fixtures = fetch!(workload, "fixtures", "samples.workload")
fail!("samples.workload.fixtures must not be empty") unless fixtures.is_a?(Array) && !fixtures.empty?

observations = fetch!(raw, "observations", "samples")
fail!("samples.observations must be a non-empty array") unless observations.is_a?(Array) && !observations.empty?

summarized = observations.each_with_index.map do |observation, index|
  location = "samples.observations[#{index}]"
  fail!("#{location} must be an object") unless observation.is_a?(Hash)
  metric_name = fetch!(observation, "metric", location)
  metric = contract_metrics[metric_name]
  fail!("#{location}.metric is unknown: #{metric_name}") unless metric
  surface_id = fetch!(observation, "surface", location)
  fail!("#{location}.surface is unknown: #{surface_id}") unless contract_surfaces.key?(surface_id)
  samples = fetch!(observation, "samples", location)
  fail!("#{location}.samples must be a non-empty array") unless samples.is_a?(Array) && !samples.empty?

  {
    "id" => fetch!(observation, "id", location),
    "surface" => surface_id,
    "fixture_id" => fetch!(observation, "fixture_id", location),
    "metric" => metric_name,
    "unit" => metric.fetch("unit"),
    "samples" => samples,
    "provenance" => fetch!(observation, "provenance", location)
  }.merge(distribution(contract, metric_name, samples))
end

summary = {}
coverage = []
contract_surfaces.each_key do |surface_id|
  metric_names = contract_metrics.select { |_name, metric|
    Array(metric["surfaces"]).include?(surface_id)
  }.keys
  surface_summary = {}
  metric_names.each do |metric_name|
    matching = summarized.select do |observation|
      observation["surface"] == surface_id && observation["metric"] == metric_name
    end
    values = matching.flat_map { |observation| observation["samples"] }
    if values.empty?
      reason = raw.dig("not_measured", surface_id, metric_name) || raw["not_measured_reason"]
      unless reason.is_a?(String) && !reason.empty?
        fail!("#{surface_id}.#{metric_name} has no samples and no not-measured reason")
      end
      surface_summary[metric_name] = { "status" => "not-measured", "reason" => reason }
      coverage << {
        "surface" => surface_id,
        "metric" => metric_name,
        "status" => "not-measured",
        "reason" => reason
      }
      next
    end

    observation_ids = matching.map { |observation| observation["id"] }
    surface_summary[metric_name] = {
      "status" => "measured",
      "unit" => contract_metrics.fetch(metric_name).fetch("unit"),
      "observation_ids" => observation_ids
    }.merge(distribution(contract, metric_name, values))
    coverage << {
      "surface" => surface_id,
      "metric" => metric_name,
      "status" => "measured",
      "observation_ids" => observation_ids,
      "sample_count" => values.length
    }
  end
  summary[surface_id] = surface_summary
end

result = {
  "schema_version" => 1,
  "profile" => PROFILE,
  "capture" => fetch!(raw, "capture", "samples"),
  "source" => fetch!(raw, "source", "samples"),
  "environment" => fetch!(raw, "environment", "samples"),
  "workload" => {
    "metric_contract" => {
      "schema_version" => contract.fetch("schema_version"),
      "contract_id" => contract.fetch("contract_id"),
      "sha256" => contract_sha
    },
    "fixtures" => fixtures
  },
  "observations" => summarized,
  "summary" => summary,
  "coverage" => coverage
}

json = JSON.pretty_generate(result)
if output_path
  File.write(output_path, "#{json}\n")
  puts "wrote #{output_path}"
else
  puts json
end
