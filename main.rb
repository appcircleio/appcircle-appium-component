def run_command(command)
  puts "@@[command] #{command}"
  unless system(command)
    exit $?.exitstatus
  end
end

cli_version = ENV['AC_APPIUM_VERSION']
appium_version = ''
appium_version = "@#{cli_version}" if !cli_version.nil? && !cli_version.empty?

install_appium = "npm install -g appium#{appium_version} --unsafe-perm=true --allow-root"
run_appium = "appium --log appium.log &>/dev/null &"
run_command(install_appium)
run_command(run_appium)
