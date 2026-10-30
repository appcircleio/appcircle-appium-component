# Appcircle Appium

Install [Appium Server](http://appium.io) and starts it.

Optional Input Variables
- `$AC_APPIUM_VERSION`: Specifies the version of Appium Server to use, for example v1.22.3. If no version is specified, the latest version will be installed."

## Running tests

Requires [RSpec](https://rspec.info) gem and Ruby standard library (Coverage). No Gemfile or Bundler needed.

```bash
ruby test/test_main.rb
```

The tests never install or start Appium: `sudo`, `npm` and `appium` are shadowed by stub executables on `PATH`. A coverage report is printed at the end of each run.
