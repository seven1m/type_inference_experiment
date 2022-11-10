Dir[File.expand_path('**/*_spec.rb', __dir__)].each do |path|
  load(path)
end
