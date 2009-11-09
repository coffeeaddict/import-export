module ImportExport
  
  require 'fastercsv'
  require 'ftools'
  
  # a base class for both imports and exports.
  class ImportExport
    attr_accessor :col_sep, :row_sep, :file

    # nifty rails style initializer
    def initialize(*args)
      
      # find the original arguments
      args = args[0]
      options = {}
      if args.last.is_a?(::Hash)
        options = args.pop
      end

      options.each_key { |key|
        self.send(key.to_s + "=", options[key]) if self.respond_to? key
      }
    end

    
    # keep a log next to the import / export file
    def log(message)
      @log_file = File.open("#{@file}.log", "wb") unless @log_file

      @log_file.write message
    end

    # keep a file with errors containing csv lines from the import / export
    def log_error(row)
      unless @error_file
        @error_file = File.open("#{@file}.errors", "wb") 
        @error_file.write row.headers.to_csv(
          :col_sep => @col_sep,
          :row_sep => @row_sep
        )
      end

      @error_file.write row.to_csv(
        :col_sep => @col_sep,
        :row_sep => @row_sep
      )
    end

    # close error and info files
    def close_logs
      @log_file.close
      @error_file.close
    end

  end

  # Generic import class
  # 
  # subclasses are expected to implement the 'import' method
  #
  class Import < ImportExport
    attr_accessor :use_headers
    
    def initialize(*args)
      super(args)
      
      @col_sep  ||= ";"
      @row_sep  ||= "\r\n"
    end

    # perform the import
    def perform
      return unless @file
      counter = 0

      log "Started import on " + Time.now.asctime + "\r\n"

      # form an options hash
      options = {
        :col_sep        => @col_sep,
      }
      if @use_headers == true
        options[:headers] = :first_row
        options[:return_headers] = false
      end

      # make sure the import fails if things go bad
      ActiveRecord::Base.transaction {
        FasterCSV.foreach(@file, options) { |row|
          self.import(row)

          # quickly write the count to the count file every 10th iteration
          File.open(count_file, File::TRUNC|File::CREAT|File::WRONLY) {|f|
            f.write( (counter += 1).to_s + "\n" )
          } unless counter % 10

          
        } #/ fasterCSV
      } #/ transaction

      log "Completed import on " + Time.now.asctime + "\r\n"

      # close the door after you
      close_logs
      count_file.close
      
      # write a done file
      File.open("#{@file}.done", "wb") { |f|
        f.write Time.now.asctime
      }
    end

    
  end

  # Generic export class.
  #
  # Subclasses are expected to implement the 'export' method which must return
  # an array for CSV creation
  #
  # If the subclass has a headers method that will be added first
  #
  class Export < ImportExport
    attr_accessor :objects, :tmp_file


    def initialize(*args)
      super(args)

      if @file == :tmp
        # make a temp file
        tmp = Tempfile.new("export", RAILS_ROOT + "/tmp")
        @file = tmp.path.dup
        tmp.close()
        @tmp_file = true
      elsif @file
        # when the filename is not a path, make sure it is in RAILS_ROOT/tmp
        @file = RAILS_ROOT + "/tmp/" + @file if @file[0] != "/"[0]

        # make sure the file ends in an extension
        @file += ".csv" if  @file !~ /\.\w+$/

      else
        throw "Need a filename to make an export"
      end

      @col_sep ||= ";"
      @row_sep ||= "\r\n"
    end

    def perform()
      if !@objects
        throw "No objects to export"
      end

      if !@objects.kind_of?(Array)
        throw "Objects is not an array"
      end

      options = {
        :col_sep => @col_sep,
        :row_sep => @row_sep
      }

      FasterCSV.open( @file, "w+", options ) { |csv|
        if self.respond_to?("header")
          csv << self.header
        end

        @objects.each { |customer|
          values = self.export(object)
          # make sure the nil values are ""
          values.collect! { |i| i.nil? ? "" : i }

          csv << values
        } #/ customers
      } #/ csv

      # when we used a temp file, copy it to make sure it survives
      if @tmp_file == true
        File.copy(@file, @file + ".csv")
        @file += ".csv"
      end
    end

    # collect a list of objects
    # 
    #   export.collect {
    #     Foo.find(:all)
    #   }
    #
    def collect
      if block_given?
        @objects = yield
      end
    end

    alias :run :perform
  end

  

end
