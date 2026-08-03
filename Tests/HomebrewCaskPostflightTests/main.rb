# frozen_string_literal: true

class ForcedCommandFailure < StandardError; end

class FakeCaskDSL
  attr_reader :command_options, :commands

  def initialize(failure_action)
    @failure_action = failure_action
    @command_options = []
    @commands = []
    @postflight_block = nil
    @uninstall_preflight_block = nil
    @version = nil
  end

  def version(value = :read)
    return @version if value == :read

    @version = value
  end

  def postflight(&block)
    @postflight_block = block
  end

  def run_postflight
    raise "rendered Cask has no postflight block" unless @postflight_block

    instance_eval(&@postflight_block)
  end

  def uninstall_preflight(&block)
    @uninstall_preflight_block = block
  end

  def run_uninstall_preflight
    raise "rendered Cask has no uninstall_preflight block" unless @uninstall_preflight_block

    instance_eval(&@uninstall_preflight_block)
  end

  def system_command(_executable, **options)
    action = options.fetch(:args).first
    @command_options << options
    @commands << action
    return unless action == @failure_action

    raise ForcedCommandFailure, "forced #{action} failure"
  end

  def livecheck(&block)
    instance_eval(&block)
  end

  def method_missing(_name, *_arguments, **_options, &_block); end

  def respond_to_missing?(_name, _include_private = false)
    true
  end
end

$cove_failure_action = nil
$cove_loaded_dsl = nil

def cask(_token, &block)
  $cove_loaded_dsl = FakeCaskDSL.new($cove_failure_action)
  $cove_loaded_dsl.instance_eval(&block)
end

def expect(condition, message)
  raise "Homebrew postflight test failed: #{message}" unless condition
end

def run_scenario(cask_path, failure_action)
  $cove_failure_action = failure_action
  $cove_loaded_dsl = nil
  load cask_path
  dsl = $cove_loaded_dsl
  raise "rendered Cask did not load" unless dsl

  error = nil
  begin
    dsl.run_postflight
  rescue ForcedCommandFailure => caught
    error = caught
  end
  [dsl.commands, dsl.command_options, error]
end

cask_path = ARGV.fetch(0)

commands, command_options, error = run_scenario(cask_path, nil)
expect(error.nil?, "successful postflight raised an error")
expect(
  commands == ["--sync-login-item-and-quit", "install"],
  "successful postflight did not sync before installing integration",
)
expect(
  command_options[1].fetch(:env).fetch("PATH") == ENV.fetch("HOMEBREW_PATH", ENV.fetch("PATH")),
  "helper install did not receive Homebrew's caller PATH",
)

commands, _command_options, error = run_scenario(cask_path, "--sync-login-item-and-quit")
expect(error&.message == "forced --sync-login-item-and-quit failure", "sync error was not re-raised")
expect(
  commands == ["--sync-login-item-and-quit", "--unregister-login-item-and-quit"],
  "sync failure did not compensate by unregistering Launch at Login",
)

commands, _command_options, error = run_scenario(cask_path, "install")
expect(error&.message == "forced install failure", "helper error was not re-raised")
expect(
  commands == [
    "--sync-login-item-and-quit",
    "install",
    "--unregister-login-item-and-quit",
  ],
  "helper failure did not compensate by unregistering Launch at Login",
)

saved_path = ENV.fetch("PATH")
saved_homebrew_path = ENV["HOMEBREW_PATH"]
begin
  filtered_path = "/usr/bin:/bin:/usr/sbin:/sbin"
  caller_path = "/opt/homebrew/bin:/private/tmp/codex-cove-cli-bin:#{filtered_path}"
  ENV["PATH"] = filtered_path
  ENV["HOMEBREW_PATH"] = caller_path
  $cove_failure_action = nil
  $cove_loaded_dsl = nil
  load cask_path
  $cove_loaded_dsl.run_uninstall_preflight
  expect(ENV.fetch("PATH") == caller_path, "uninstall did not restore Homebrew's caller PATH")
ensure
  ENV["PATH"] = saved_path
  if saved_homebrew_path.nil?
    ENV.delete("HOMEBREW_PATH")
  else
    ENV["HOMEBREW_PATH"] = saved_homebrew_path
  end
end

puts "Homebrew Cask postflight rollback tests passed."
