#!/usr/bin/env ruby
# frozen_string_literal: true

# Adds the "Embed vzhukhd" build phase to the macOS Runner target, which puts
# the helper into Contents/Resources (see scripts/embed_daemon.sh).
#
# Kept as a script for the same reason as setup_ios_extension.rb: the Xcode
# project is generated, and running this again restores the phase after
# `flutter create` has thrown it away.
#
# Usage:
#   ruby scripts/setup_macos_daemon.rb

require 'xcodeproj'

ROOT = File.expand_path('..', __dir__)
PROJECT_PATH = File.join(ROOT, 'macos', 'Runner.xcodeproj')
PHASE_NAME = 'Embed vzhukhd'

project = Xcodeproj::Project.open(PROJECT_PATH)
target = project.targets.find { |t| t.name == 'Runner' } or abort 'no Runner target'

target.shell_script_build_phases.select { |p| p.name == PHASE_NAME }.each do |phase|
  target.build_phases.delete(phase)
  phase.remove_from_project
end

phase = target.new_shell_script_build_phase(PHASE_NAME)
phase.shell_path = '/bin/sh'
phase.shell_script = '"$SRCROOT/../scripts/embed_daemon.sh"'
phase.input_paths = ['$(SRCROOT)/../build/daemon/vzhukhd']
phase.output_paths = ['$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/vzhukhd']

# Before signing, which Xcode does after every phase: the helper must be in
# place when the bundle's signature is computed.
target.build_phases.delete(phase)
resources = target.build_phases.index { |p| p.is_a?(Xcodeproj::Project::Object::PBXResourcesBuildPhase) }
target.build_phases.insert((resources || target.build_phases.size - 1) + 1, phase)

project.save
puts "#{PHASE_NAME}: added to #{target.name}"
