#!/usr/bin/env ruby
# frozen_string_literal: true

# ClairTextKit is the shared text surface used by the editor and the terminal.
# ADR-0014 and the p0028 design fix its dependency direction: app -> ClairTextKit,
# never the reverse. The module is compiled into the same app target as the rest of
# Clair, so nothing but this check stops a Project, workspace, or theme type from
# leaking into the engine.

require "pathname"
require "set"

repository_root = Pathname(__dir__).parent
engine_root = repository_root / "apple/ClairTextKit"
app_root = repository_root / "apple/ClairApp"

ALLOWED_IMPORTS = %w[
  AppKit
  CoreGraphics
  CoreText
  Foundation
  QuartzCore
  SwiftUI
  os
].freeze

# Top-level declarations only: a nested type cannot collide across modules, and the
# rule this check enforces is that ClairTextKit never names an app type.
DECLARATION = /^(?:(?:public|internal|fileprivate|private|final|open|indirect|@[A-Za-z]+(?:\([^)]*\))?)\s+)*(?:class|struct|enum|protocol|actor|typealias)\s+([A-Z][A-Za-z0-9_]*)/

abort("textkit-boundary: #{engine_root} does not exist") unless engine_root.directory?

app_types = Set.new
app_root.glob("*.swift").sort.each do |path|
  path.read(encoding: "UTF-8").each_line do |line|
    match = DECLARATION.match(line)
    app_types << match[1] if match
  end
end
abort("textkit-boundary: no app types were found in #{app_root}") if app_types.empty?

engine_types = Set.new
engine_root.glob("*.swift").sort.each do |path|
  path.read(encoding: "UTF-8").each_line do |line|
    match = DECLARATION.match(line)
    engine_types << match[1] if match
  end
end
app_types -= engine_types

errors = []
engine_files = engine_root.glob("*.swift").sort
abort("textkit-boundary: no engine sources were found") if engine_files.empty?

engine_files.each do |path|
  relative = path.relative_path_from(repository_root)
  path.read(encoding: "UTF-8").each_line.with_index(1) do |line, number|
    if (import = line[/^import\s+([A-Za-z_][A-Za-z0-9_.]*)/, 1])
      root_module = import.split(".").first
      unless ALLOWED_IMPORTS.include?(root_module)
        errors << "#{relative}:#{number} imports #{import}, which is outside the engine's allowed frameworks"
      end
      next
    end

    code = line.sub(%r{//.*}, "")
    app_types.each do |type|
      next unless code.match?(/(?<![A-Za-z0-9_])#{Regexp.escape(type)}(?![A-Za-z0-9_])/)

      errors << "#{relative}:#{number} references the app type #{type}; ClairTextKit must not depend on Clair"
    end
  end
end

unless errors.empty?
  abort("textkit-boundary failed:\n- #{errors.join("\n- ")}")
end

puts(
  "textkit-boundary: #{engine_files.length} ClairTextKit sources depend only on " \
    "#{ALLOWED_IMPORTS.join(', ')} and reference none of the #{app_types.length} app types."
)
