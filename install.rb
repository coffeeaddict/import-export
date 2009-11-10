# notify the user that dependencies are missing

begin
  require 'fastercsv'

rescue LoadError => e
  $stderr.puts "Be sure to install FasterCSV (gem install fastercsv)"
  $stderr.puts "before wielding the import/export axe" if errors

end

