task :spec do
  require_relative './spec/all'
end

task :watch do
  files = Dir['{lib,spec}/**/*.rb'].to_a
  sh "ls #{files.join(' ')} | entr -c -s 'rake spec'"
end
