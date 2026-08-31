#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "open3"
require "pathname"
require "rexml/document"
require "rexml/xpath"

repository_root = Pathname(__dir__).parent
project_path = repository_root / "Clair.xcodeproj/project.pbxproj"
scheme_paths = Dir[repository_root.join("Clair.xcodeproj/xcshareddata/xcschemes/*.xcscheme")].sort

json, diagnostic, status = Open3.capture3(
  "plutil",
  "-convert",
  "json",
  "-o",
  "-",
  project_path.to_s
)
abort("xcode-project-check: plutil failed:\n#{diagnostic}") unless status.success?

project = JSON.parse(json)
objects = project.fetch("objects")
errors = []

reference_fields = {
  "PBXBuildFile" => %w[fileRef],
  "PBXContainerItemProxy" => %w[containerPortal remoteGlobalIDString],
  "PBXGroup" => %w[children],
  "PBXNativeTarget" => %w[buildConfigurationList buildPhases dependencies productReference],
  "PBXProject" => %w[buildConfigurationList mainGroup productRefGroup targets],
  "PBXTargetDependency" => %w[target targetProxy],
  "PBXFrameworksBuildPhase" => %w[files],
  "PBXResourcesBuildPhase" => %w[files],
  "PBXShellScriptBuildPhase" => %w[files],
  "PBXSourcesBuildPhase" => %w[files],
  "XCBuildConfiguration" => %w[baseConfigurationReference],
  "XCConfigurationList" => %w[buildConfigurations],
}.freeze

root_object = project.fetch("rootObject")
errors << "root object #{root_object} is missing" unless objects.key?(root_object)

objects.each do |identifier, object|
  reference_fields.fetch(object.fetch("isa"), []).each do |field|
    Array(object[field]).each do |reference|
      next if reference.nil? || reference.empty?

      errors << "#{identifier}.#{field} references missing object #{reference}" unless objects.key?(reference)
    end
  end
end

expected_targets = {
  "ClairStable" => "Clair.app",
  "ClairDev" => "Clair Dev.app",
  "ClairTests" => "ClairTests.xctest",
}.freeze

targets = objects.select { |_identifier, object| object["isa"] == "PBXNativeTarget" }
expected_targets.each do |target_name, product_name|
  identifier, target = targets.find { |_id, object| object["name"] == target_name }
  if target.nil?
    errors << "missing native target #{target_name}"
    next
  end

  product = objects[target.fetch("productReference")]
  errors << "#{identifier} has unexpected product #{product&.fetch("path", nil)}" unless product&.fetch("path", nil) == product_name
end

def validate_group_files(group_identifier, base_path, objects, errors, visited)
  return if visited.include?(group_identifier)

  visited << group_identifier
  group = objects.fetch(group_identifier)
  group_base = group["path"] ? base_path.join(group["path"]) : base_path

  Array(group["children"]).each do |child_identifier|
    child = objects.fetch(child_identifier)
    case child.fetch("isa")
    when "PBXGroup"
      validate_group_files(child_identifier, group_base, objects, errors, visited)
    when "PBXFileReference"
      next unless child["sourceTree"] == "<group>"

      file_path = group_base.join(child.fetch("path"))
      errors << "missing referenced file #{file_path}" unless file_path.exist?
    end
  end
end

main_group = objects.fetch(root_object).fetch("mainGroup")
validate_group_files(main_group, repository_root, objects, errors, [])

scheme_paths.each do |scheme_path|
  document = REXML::Document.new(File.read(scheme_path))
  REXML::XPath.each(document, "//BuildableReference") do |reference|
    identifier = reference.attributes["BlueprintIdentifier"]
    target = objects[identifier]
    if target.nil? || target["isa"] != "PBXNativeTarget"
      errors << "#{File.basename(scheme_path)} references missing target #{identifier}"
      next
    end

    expected_name = target.fetch("name")
    actual_name = reference.attributes["BlueprintName"]
    errors << "#{File.basename(scheme_path)} names #{identifier} as #{actual_name}, expected #{expected_name}" unless actual_name == expected_name

    product = objects.fetch(target.fetch("productReference")).fetch("path")
    buildable_name = reference.attributes["BuildableName"]
    errors << "#{File.basename(scheme_path)} uses product #{buildable_name}, expected #{product}" unless buildable_name == product
  end
end

unless errors.empty?
  abort("xcode-project-check failed:\n- #{errors.join("\n- ")}")
end

puts(
  "xcode-project-check: #{objects.length} objects, #{targets.length} targets, " \
    "#{scheme_paths.length} shared schemes are internally consistent."
)
