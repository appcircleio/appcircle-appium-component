require 'pathname'

def get_env_variable(key)
	return (ENV[key] == nil || ENV[key] == "") ? nil : ENV[key]
end

def run_command(command)
  puts "@@[command] #{command}"
  unless system(command)
    exit $?.exitstatus
  end
end

cli_version = ENV['AC_APPIUM_VERSION']
ac_output_path = get_env_variable("AC_OUTPUT_DIR") || abort('Missing output path.')
appium_log_file = (Pathname.new ac_output_path).join("appium.log")
appium_version = ''
appium_version = "@#{cli_version}" if !cli_version.nil? && !cli_version.empty?

install_appium = "npm install -g appium#{appium_version} --unsafe-perm=true --allow-root"
run_appium = "appium --log #{appium_log_file} &>/dev/null &"
run_command(install_appium)
run_command(run_appium)
