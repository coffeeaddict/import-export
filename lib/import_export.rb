module ImportExport
  
  require 'fastercsv'
  require 'ftools'

  # a very simple and subtle callback mechanism that could potentially
  # blow up

  def before_export(what)
    @@before ||= []
    @@before << what
  end

  alias :before_import :before_export

  def after_export(what)
    @@after ||= []
    @@after << what
  end

  alias :after_import :after_export

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

      # some defaults
      @col_sep  ||= ";"
      @row_sep  ||= "\r\n"
    end

    
    # keep a log next to the import / export file
    def log(message)
      unless @log_file
        @log_file = File.open("#{@file}.log", "wb")
        @log_file.sync = true
      end

      message += "\n" if message[-1] != 10
      @log_file.write message
    end

    # keep a file with errors containing csv lines from the import / export
    def log_error(row)
      unless @error_file
        @error_file = File.open("#{@file}.errors", "wb")
        @error_file.sync = true

	if row.respond_to?(:headers)
          @error_file.write row.headers.to_csv(
            :col_sep => @col_sep,
            :row_sep => @row_sep
          )
        end
     
      end

      @error_file.write row.to_csv(
        :col_sep => @col_sep,
        :row_sep => @row_sep
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
  class Import < ImportExport
    attr_accessor :use_headers

    def initialize(*args)
      super(args)
     
      @use_headers = true
    end

    # perform the import
    def perform
      throw "No file to import" unless @file
      counter = 0

      @@before ||= nil; @@after ||= nil;

      log "Started import on " + Time.now.asctime + "\r\n"

      # run callback
      @@before.each { |method| self.send(method) } if @@before

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

      @@after.each { |method| self.send(method) } if @@after

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

      @@before ||= nil; @@after ||= nil;

      log "Started export on " + Time.now.asctime
 
      @@before.each { |method| self.send(method) } if @@before

      options = {
        :col_sep => @col_sep,
        :row_sep => @row_sep
      }

      FasterCSV.open( @file, "w+", options ) { |csv|
        if self.respond_to?("header")
          csv << self.header
        end

        @objects.each { |object|
          values = self.export(object)
          # make sure the nil values are ""
          values.collect! { |i| i.nil? ? "" : i }

          csv << values
        } #/ customers
      } #/ csv

      @@after.each { |method| self.send(method) } if @@after

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
