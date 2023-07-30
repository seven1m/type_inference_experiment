task :spec do
  require_relative './spec/all'
end

task :docker_spec do
  sh 'docker build . -t tie && docker run tie bundle exec rake spec'
end

task :watch do
  files = Dir['{lib,spec}/**/*.rb'].to_a
  sh "ls #{files.join(' ')} | entr -c -s 'rake spec'"
end
