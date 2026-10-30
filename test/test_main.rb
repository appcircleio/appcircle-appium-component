# frozen_string_literal: true

# ─── Coverage (must start before loading main.rb) ─────────────────────────────
unless defined?(Coverage) && Coverage.running?
  require 'coverage'
  Coverage.start
end

# ─── Dependencies ─────────────────────────────────────────────────────────────
require 'rspec'
require 'rspec/core/formatters/base_formatter'
require 'open3'
require 'fileutils'
require 'tmpdir'
require 'rbconfig'
require 'stringio'

MAIN_RB      = File.expand_path('../main.rb', __dir__)
PROJECT_ROOT = File.dirname(MAIN_RB)
RUBY_BIN     = RbConfig.ruby

require MAIN_RB

# ─── Custom Formatter ─────────────────────────────────────────────────────────
class ReadableFormatter < RSpec::Core::Formatters::BaseFormatter
  RSpec::Core::Formatters.register(
    self,
    :example_group_started,
    :example_group_finished,
    :example_passed,
    :example_failed,
    :example_pending,
    :dump_summary
  )

  PASS  = "\e[32;1m[ PASS ]\e[0m"
  FAIL  = "\e[31;1m[ FAIL ]\e[0m"
  ERROR = "\e[31;1m[ERROR ]\e[0m"
  SKIP  = "\e[33;1m[ SKIP ]\e[0m"

  DIVIDER     = "\e[90m#{'─' * 72}\e[0m"
  DIVIDER_FAT = "\e[90m#{'═' * 72}\e[0m"

  def initialize(output)
    super
    @depth    = 0
    @failures = []
    @counts   = { passed: 0, failed: 0, pending: 0 }
  end

  # Top-level describe groups cycle through distinct colors
  GROUP_COLORS = [
    "\e[34;1m",  # bold blue
    "\e[35;1m",  # bold magenta
    "\e[36;1m",  # bold cyan
    "\e[33;1m"   # bold yellow
  ].freeze

  def example_group_started(notification)
    group = notification.group
    if group.parent_groups.size <= 1
      output.puts if @depth.zero?
      color = GROUP_COLORS[@depth % GROUP_COLORS.size]
      output.puts "  #{color}#{group.description}\e[0m"
    else
      output.puts "    #{'  ' * (@depth - 1)}\e[90m▸ \e[0m\e[37m#{group.description}\e[0m"
    end
    @depth += 1
  end

  def example_group_finished(_notification)
    @depth -= 1 if @depth > 0
  end

  def example_passed(notification)
    @counts[:passed] += 1
    print_example(PASS, notification.example)
  end

  def example_failed(notification)
    @counts[:failed] += 1
    ex    = notification.example
    exc   = ex.execution_result.exception
    badge = exc.is_a?(RSpec::Expectations::ExpectationNotMetError) ? FAIL : ERROR
    print_example(badge, ex)
    @failures << notification
  end

  def example_pending(notification)
    @counts[:pending] += 1
    ex = notification.example
    output.puts "    #{'  ' * [0, @depth - 1].max}#{SKIP}  #{ex.description}"
  end

  def dump_summary(notification)
    output.puts
    output.puts DIVIDER_FAT

    unless @failures.empty?
      output.puts "\n  \e[1;31mFailures:\e[0m\n"
      @failures.each_with_index do |n, i|
        ex  = n.example
        exc = ex.execution_result.exception
        output.puts "  \e[1m#{i + 1}) #{ex.full_description}\e[0m"
        exc.message.lines.first(6).each do |line|
          output.puts "     \e[31m#{line.rstrip}\e[0m"
        end
        output.puts "     \e[90m# #{ex.location}\e[0m"
        output.puts
      end
      output.puts DIVIDER
    end

    t   = notification.examples.size
    p   = @counts[:passed]
    f   = @counts[:failed]
    s   = @counts[:pending]
    sec = format('%.3fs', notification.duration)

    parts = ["\e[32m#{p} passed\e[0m"]
    parts << "\e[31m#{f} failed\e[0m"  if f > 0
    parts << "\e[33m#{s} pending\e[0m" if s > 0

    overall = f.zero? ? "\e[32;1m✔  All #{t} tests passed\e[0m" : "\e[31;1m✖  #{f} of #{t} tests failed\e[0m"
    output.puts "\n  #{overall}"
    output.puts "  #{parts.join('  |  ')}  \e[90m(#{sec})\e[0m"
    output.puts DIVIDER_FAT
  end

  private

  def print_example(badge, example)
    indent = '  ' * [0, @depth - 1].max
    time   = format('%.3fs', example.execution_result.run_time)
    output.puts "    #{indent}#{badge}  #{example.description}  \e[90m(#{time})\e[0m"
  end
end

# ─── Helpers ──────────────────────────────────────────────────────────────────

# Capture everything written to $stdout while the block runs.
def capture_stdout
  original = $stdout
  buffer   = StringIO.new
  $stdout  = buffer
  yield
  buffer.string
ensure
  $stdout = original
end

# Build a directory of stub executables that shadow the real toolchain on PATH,
# so running main.rb never installs or starts anything.
#
# `sudo` simply execs its arguments, which keeps resolving through this same
# directory; `npm` and `appium` only record their argv and exit with the status
# the caller asked for.
def build_fake_bin(dir, log_path, npm_exit: 0)
  FileUtils.mkdir_p(dir)

  File.write(File.join(dir, 'sudo'), <<~SH)
    #!/bin/sh
    exec "$@"
  SH

  File.write(File.join(dir, 'npm'), <<~SH)
    #!/bin/sh
    echo "npm $*" >> "#{log_path}"
    exit #{npm_exit}
  SH

  File.write(File.join(dir, 'appium'), <<~SH)
    #!/bin/sh
    echo "appium $*" >> "#{log_path}"
    exit 0
  SH

  %w[sudo npm appium].each { |f| FileUtils.chmod(0o755, File.join(dir, f)) }
  dir
end

# Run main.rb in a subprocess against the stub toolchain.
# Keys passed with a nil value are unset in the child.
def run_main(env = {}, fake_bin:)
  clean_env = {
    'AC_OUTPUT_DIR'      => nil,
    'AC_APPIUM_VERSION'  => nil,
    'PATH'               => "#{fake_bin}:#{ENV['PATH']}"
  }.merge(env)

  Open3.capture3(clean_env, RUBY_BIN, MAIN_RB)
end

# Run main.rb in-process, as if it were the program, against the stub
# toolchain. Returns [stdout, stderr, exit_status] where exit_status is nil
# when the script ran to completion.
def load_main(env = {}, fake_bin:)
  vars = {
    'AC_OUTPUT_DIR'     => nil,
    'AC_APPIUM_VERSION' => nil,
    'PATH'              => "#{fake_bin}:#{ENV['PATH']}"
  }.merge(env)

  saved = vars.keys.to_h { |k| [k, ENV[k]] }
  vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }

  old_program = $PROGRAM_NAME
  old_stdout  = $stdout
  old_stderr  = $stderr
  out = StringIO.new
  err = StringIO.new
  $stdout = out
  $stderr = err
  $0 = MAIN_RB

  status = nil
  begin
    load MAIN_RB
  rescue SystemExit => e
    status = e.status
  end

  [out.string, err.string, status]
ensure
  $0 = old_program
  $stdout = old_stdout
  $stderr = old_stderr
  saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
end

# The `@@[command] ...` lines main.rb echoes before shelling out.
def command_lines(stdout)
  stdout.lines.map(&:chomp).select { |l| l.start_with?('@@[command] ') }
               .map { |l| l.sub('@@[command] ', '') }
end

# ─── Tests ────────────────────────────────────────────────────────────────────

RSpec.describe 'main.rb loading' do
  it 'is requireable without executing the installation steps' do
    expect(defined?(get_env_variable)).to eq('method')
    expect(defined?(run_command)).to eq('method')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#get_env_variable' do
  around do |example|
    had_key = ENV.key?('_TEST_VAR')
    old     = ENV['_TEST_VAR']
    example.run
    had_key ? ENV['_TEST_VAR'] = old : ENV.delete('_TEST_VAR')
  end

  it 'returns the value when the key is set' do
    ENV['_TEST_VAR'] = 'hello'
    expect(get_env_variable('_TEST_VAR')).to eq('hello')
  end

  it 'returns the value verbatim, without trimming whitespace' do
    ENV['_TEST_VAR'] = '  spaced  '
    expect(get_env_variable('_TEST_VAR')).to eq('  spaced  ')
  end

  it 'returns nil when the key is missing' do
    ENV.delete('_TEST_VAR')
    expect(get_env_variable('_TEST_VAR')).to be_nil
  end

  it 'returns nil when the value is an empty string' do
    ENV['_TEST_VAR'] = ''
    expect(get_env_variable('_TEST_VAR')).to be_nil
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe '#run_command' do
  it 'returns without raising when the command succeeds' do
    expect { capture_stdout { run_command('exit 0') } }.not_to raise_error
  end

  it 'echoes the command with the @@[command] prefix before running it' do
    out = capture_stdout { run_command('exit 0') }
    expect(out).to include('@@[command] exit 0')
  end

  it 'exits with the command status when the command fails' do
    expect {
      capture_stdout { run_command('exit 7') }
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(7) }
  end

  it 'exits with status 127 when the command cannot be found' do
    expect {
      capture_stdout { run_command('ac-appium-no-such-binary') }
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(127) }
  end

  it 'exits for an empty command string' do
    expect { capture_stdout { run_command('') } }.to raise_error(SystemExit)
  end

  it 'raises TypeError when the command is nil' do
    expect { capture_stdout { run_command(nil) } }.to raise_error(TypeError)
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'main.rb script' do
  let(:tmpdir)    { Dir.mktmpdir('appium_test') }
  let(:output_dir) { FileUtils.mkdir_p(File.join(tmpdir, 'output')).first }
  let(:call_log)  { File.join(tmpdir, 'calls.log') }
  let(:fake_bin)  { build_fake_bin(File.join(tmpdir, 'bin'), call_log) }

  after { FileUtils.rm_rf(tmpdir) }

  context 'when AC_OUTPUT_DIR is missing' do
    it 'aborts with "Missing output path."' do
      _out, err, status = run_main({}, fake_bin: fake_bin)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing output path\./)
    end

    it 'never shells out' do
      out, _err, _status = run_main({}, fake_bin: fake_bin)
      expect(command_lines(out)).to be_empty
      expect(File.exist?(call_log)).to be(false)
    end
  end

  context 'when AC_OUTPUT_DIR is an empty string' do
    it 'aborts with "Missing output path."' do
      _out, err, status = run_main({ 'AC_OUTPUT_DIR' => '' }, fake_bin: fake_bin)
      expect(status.exitstatus).not_to eq(0)
      expect(err).to match(/Missing output path\./)
    end
  end

  context 'when AC_APPIUM_VERSION is not set' do
    it 'installs the unpinned appium package' do
      out, _err, status = run_main({ 'AC_OUTPUT_DIR' => output_dir }, fake_bin: fake_bin)
      expect(status.exitstatus).to eq(0)
      expect(command_lines(out).first)
        .to eq('sudo npm install -g appium --unsafe-perm=true --allow-root')
    end
  end

  context 'when AC_APPIUM_VERSION is an empty string' do
    it 'installs the unpinned appium package' do
      out, _err, status = run_main(
        { 'AC_OUTPUT_DIR' => output_dir, 'AC_APPIUM_VERSION' => '' },
        fake_bin: fake_bin
      )
      expect(status.exitstatus).to eq(0)
      expect(command_lines(out).first)
        .to eq('sudo npm install -g appium --unsafe-perm=true --allow-root')
    end
  end

  context 'when AC_APPIUM_VERSION is set' do
    it 'pins the package to that version' do
      out, _err, status = run_main(
        { 'AC_OUTPUT_DIR' => output_dir, 'AC_APPIUM_VERSION' => 'v1.22.3' },
        fake_bin: fake_bin
      )
      expect(status.exitstatus).to eq(0)
      expect(command_lines(out).first)
        .to eq('sudo npm install -g appium@v1.22.3 --unsafe-perm=true --allow-root')
    end
  end

  context 'the appium start command' do
    it 'logs into appium.log under AC_OUTPUT_DIR and backgrounds the server' do
      out, _err, status = run_main({ 'AC_OUTPUT_DIR' => output_dir }, fake_bin: fake_bin)
      expect(status.exitstatus).to eq(0)
      expect(command_lines(out).last)
        .to eq("appium --log #{File.join(output_dir, 'appium.log')} &>/dev/null &")
    end

    it 'joins a trailing-slash output path without doubling the separator' do
      out, _err, _status = run_main(
        { 'AC_OUTPUT_DIR' => "#{output_dir}/" }, fake_bin: fake_bin
      )
      expect(command_lines(out).last)
        .to eq("appium --log #{File.join(output_dir, 'appium.log')} &>/dev/null &")
    end
  end

  context 'when the install step fails' do
    let(:fake_bin) { build_fake_bin(File.join(tmpdir, 'bin'), call_log, npm_exit: 3) }

    it 'propagates the npm exit status' do
      _out, _err, status = run_main({ 'AC_OUTPUT_DIR' => output_dir }, fake_bin: fake_bin)
      expect(status.exitstatus).to eq(3)
    end

    it 'does not start the appium server' do
      out, _err, _status = run_main({ 'AC_OUTPUT_DIR' => output_dir }, fake_bin: fake_bin)
      expect(command_lines(out).size).to eq(1)
      expect(out).not_to include('appium --log')
    end
  end

  it 'runs install before start, and only those two commands' do
    out, _err, _status = run_main({ 'AC_OUTPUT_DIR' => output_dir }, fake_bin: fake_bin)
    cmds = command_lines(out)
    expect(cmds.size).to eq(2)
    expect(cmds.first).to start_with('sudo npm install -g appium')
    expect(cmds.last).to start_with('appium --log')
  end
end

# ─────────────────────────────────────────────────────────────────────────────

RSpec.describe 'main.rb script (in-process)' do
  # Ruby's Coverage resets a file's counters every time the file is compiled,
  # and `load` recompiles it. The report therefore reflects the final `load`
  # only, so the complete successful run is deliberately the last example in
  # this file.
  let(:tmpdir)     { Dir.mktmpdir('appium_inproc') }
  let(:output_dir) { FileUtils.mkdir_p(File.join(tmpdir, 'output')).first }
  let(:call_log)   { File.join(tmpdir, 'calls.log') }
  let(:fake_bin)   { build_fake_bin(File.join(tmpdir, 'bin'), call_log) }

  after { FileUtils.rm_rf(tmpdir) }

  it 'aborts when AC_OUTPUT_DIR is missing' do
    out, err, status = load_main({}, fake_bin: fake_bin)
    expect(status).not_to eq(0)
    expect(err).to match(/Missing output path\./)
    expect(command_lines(out)).to be_empty
  end

  it 'aborts when AC_OUTPUT_DIR is an empty string' do
    _out, err, status = load_main({ 'AC_OUTPUT_DIR' => '' }, fake_bin: fake_bin)
    expect(status).not_to eq(0)
    expect(err).to match(/Missing output path\./)
  end

  it 'exits with the npm status and never starts the server' do
    failing_bin = build_fake_bin(File.join(tmpdir, 'failing_bin'), call_log, npm_exit: 3)
    out, _err, status = load_main({ 'AC_OUTPUT_DIR' => output_dir }, fake_bin: failing_bin)
    expect(status).to eq(3)
    expect(command_lines(out).size).to eq(1)
    expect(out).not_to include('appium --log')
  end

  it 'pins the package when AC_APPIUM_VERSION is set' do
    out, _err, status = load_main(
      { 'AC_OUTPUT_DIR' => output_dir, 'AC_APPIUM_VERSION' => 'v1.22.3' },
      fake_bin: fake_bin
    )
    expect(status).to be_nil
    expect(command_lines(out).first)
      .to eq('sudo npm install -g appium@v1.22.3 --unsafe-perm=true --allow-root')
  end

  it 'installs the unpinned package and starts the server' do
    out, _err, status = load_main({ 'AC_OUTPUT_DIR' => output_dir }, fake_bin: fake_bin)
    expect(status).to be_nil
    expect(command_lines(out)).to eq([
      'sudo npm install -g appium --unsafe-perm=true --allow-root',
      "appium --log #{File.join(output_dir, 'appium.log')} &>/dev/null &"
    ])
  end
end

# ─────────────────────────────────────────────────────────────────────────────

# Runs last on purpose: it exercises run_command's failure branch against the
# definitions left behind by the final `load` above, so the coverage report
# accounts for every line of main.rb.
RSpec.describe '#run_command (after the final load)' do
  it 'still exits with the command status' do
    expect {
      capture_stdout { run_command('exit 5') }
    }.to raise_error(SystemExit) { |e| expect(e.status).to eq(5) }
  end
end

# ─── Coverage Report ──────────────────────────────────────────────────────────
def print_coverage_report
  return unless defined?(Coverage) && Coverage.running?

  result = begin
    Coverage.result(stop: false, clear: false)
  rescue ArgumentError
    Coverage.result
  end

  main_path = result.keys.find { |p| p&.end_with?('main.rb') }
  return puts("\nCoverage: main.rb not found in results") unless main_path

  data      = result[main_path]
  lines     = data.each_with_index.reject { |c, _| c.nil? }
  total     = lines.size
  covered   = lines.count { |c, _| c.to_i > 0 }
  pct       = total.positive? ? (covered * 100.0 / total).round(1) : 100.0
  uncovered = lines.select { |c, _| c.to_i == 0 }.map { |_, i| i + 1 }

  color = pct == 100 ? "\e[32;1m" : pct >= 80 ? "\e[33m" : "\e[31m"
  bar_filled = (pct / 5).round
  bar = "\e[32m" + '█' * bar_filled + "\e[90m" + '░' * (20 - bar_filled) + "\e[0m"

  puts "\n\e[90m#{'═' * 72}\e[0m"
  puts '  Coverage Report'
  puts "\e[90m#{'─' * 72}\e[0m"
  puts "  main.rb  #{bar}  #{color}#{pct}%\e[0m  (#{covered}/#{total} lines)"
  if uncovered.any? && uncovered.size <= 20
    puts "  Uncovered lines: \e[90m#{uncovered.join(', ')}\e[0m"
  elsif uncovered.any?
    puts "  Uncovered lines: \e[90m#{uncovered.first(15).join(', ')} … (+#{uncovered.size - 15} more)\e[0m"
  end
  puts "\e[90m#{'═' * 72}\e[0m"
end

# ─── Runner ───────────────────────────────────────────────────────────────────
if __FILE__ == $PROGRAM_NAME
  RSpec.configure do |config|
    config.add_formatter ReadableFormatter
    config.color        = true
    config.order        = :defined
  end

  exit_code = RSpec::Core::Runner.run(['--order', 'defined'])
  print_coverage_report
  exit exit_code
end
