ExUnit.start(exclude: [:generate_fixtures])

# Load shared test support modules
Code.require_file("support/test_outlet.ex", __DIR__)
Code.require_file("support/supervised_helpers.ex", __DIR__)
