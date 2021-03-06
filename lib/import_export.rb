module ImportExport
  
  require 'fastercsv'
  require 'ftools'

  # a base class for both imports and exports.
  class ImportExport
    attr_accessor :col_sep, :row_sep, :file

    # nifty rails style initializer
    def initialize(*args)

      # find the original arguments (super(*args) adds extra
      # dimensions to the array
      args.flatten!

      options = {}
      if args.last.is_a?(::Hash)
        options = args.pop
      end

      options.each_key { |key|
        self.send(key.to_s + "=", options[key]) if self.respond_to? key
      }

      # some defaults for FasterCSV
      @col_sep      ||= ";"
      @row_sep      ||= "\r\n"
      @force_quotes ||= false
    end

    
    # keep a log next to the import / export file
    def log(message)
      unless @log_file
        @log_file = File.open("#{@file}.log", "wb")
        @log_file.sync = true
      end

      message += @row_sep if message.last != "\n"
      @log_file.write message
    end

    # keep a file with errors containing csv lines from the import / export
    def log_error(row)
      unless @error_file
        @error_file = File.open("#{@file}.errors", "wb")
        @error_file.sync = true

	      if row.respond_to?(:headers)
          @error_file.write row.headers.to_csv(
            :col_sep      => @col_sep,
            :row_sep      => @row_sep,
            :force_quotes => @force_quotes
          )
        end
     
      end

      @error_file.write row.to_csv(
        :force_quotes => @force_quotes,
        :col_sep      => @col_sep,
        :row_sep      => @row_sep
      )
    end

    # close error and info files
    def close_logs
      @log_file.close if @log_file
      @error_file.close if @error_file
    end

  end

  # Generic import class
  # 
  # subclasses are expected to implement the 'import' method
  #
  class Importer < ImportExport
    attr_accessor :use_headers

    def initialize(*args)
      super(args)
     
      @use_headers = true
    end

    # perform the import
    def perform
      throw "No file to import" unless @file

      counter    = 0
      count_file = "#{@file}.count"

      log "Started import on " + Time.now.asctime + "\r\n"

      # run callback
      self.before_import if self.respond_to?(:before_import)

      # form an options hash
      options = {
        :col_sep      => @col_sep,
        :force_quotes => @force_quotes
      }
      if @use_headers == true
        options[:headers] = :first_row
        options[:return_headers] = false
      end

      begin
        # make sure the import fails if things go bad
        ActiveRecord::Base.transaction {
          FasterCSV.foreach(@file, options) { |row|
            self.import(row)

            # quickly write the count to the count file every 5th iteration
            File.open(count_file, File::TRUNC|File::CREAT|File::WRONLY) {|f|
              f.write( counter.to_s + "\n" )
            } if ( ( counter += 1 ) % 5 == 0 )


          } #/ fasterCSV
        } #/ transaction
      rescue Exception => ex
        log "Import aborted: " + ex.message
        log ex.backtrace.join("\n")
        log_error ["The entire import failed. please see log for more info."]
      end
      
      # write the final count
      File.open(count_file, File::TRUNC|File::CREAT|File::WRONLY) {|f|
	      f.write( counter.to_s + "\n" )
      }

      self.after_import if self.respond_to?(:after_import)

      log "Completed import on " + Time.now.asctime + "\r\n"

      # close the door after you
      close_logs
    end

    alias :run :perform
  end

  # Generic export class.
  #
  # Subclasses are expected to implement the 'export' method which must return
  # an array for CSV creation
  #
  # If the subclass has a headers method that will be added first
  #
  class Exporter < ImportExport
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

      @objects = yield if block_given?

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

      log "Started export on " + Time.now.asctime

      self.before_export if self.respond_to?(:before_export)

      options = {
        :col_sep      => @col_sep,
        :row_sep      => @row_sep,
        :force_quotes => @force_quotes
      }

      counter = 0
      begin
        ActiveRecord::Base.transaction {
          FasterCSV.open( @file, "w+", options ) { |csv|
            if self.respond_to?("header")
              csv << self.header
              counter += 1
            end

            @objects.each { |object|
              if values = self.export(object)
                # make sure the nil values are ""
                values.collect! { |i| i.nil? ? "" : i }

                csv << values
                counter += 1
              end
            } #/ customers
          } #/ csv
        } #/ transaction
      rescue Exception => ex
        log "Export aborted: " + ex.message
        log ex.backtrace.join("\n")
        log_error ["the entire export failed. please see log for more info."]
      end

      # write the final count
      File.open("#{@file}.count", File::TRUNC|File::CREAT|File::WRONLY) {|f|
	      f.write( counter.to_s + "\n" )
      }

      self.after_export if self.respond_to?(:after_export)

      log "Completed export on " + Time.now.asctime

      close_logs

      # when we used a temp file, copy it to make sure it survives
      if @tmp_file == true
        File.copy(@file, @file + ".csv")
        @file += ".csv"
      end
    end

    # collect a list of objects
    # 
    #   export.collect {
    #     Item.find( :all, :conditions => ... )
    #   }
    #
    def collect
      @objects = yield if block_given?
    end

    alias :run :perform
  end

  

end
