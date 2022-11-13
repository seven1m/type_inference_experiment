require 'bundler/setup'
require 'minitest/spec'
require 'minitest/focus'
require 'minitest/autorun'
$LOAD_PATH << File.expand_path('../lib', __dir__)
require 'type_inference_experiment'
