ENV['RACK_ENV'] = 'test'

require 'rspec'
require 'capybara/rspec'

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.order = :random
end
