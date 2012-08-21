require "rubygems"
require "rightmove_wrangler/version"
require "fileutils"
require "rightmove"
require "optparse"
require "faraday"
require "addressable/uri"

module RightmoveWrangler
  class Processor
    attr_accessor :directory_list
    IMAGE_REGEX = /\.(jpg|jpeg|png|gif)/i

    def initialize(args)
      @args = args
      @options = {}
    end

    def run
      @opts = OptionParser.new(&method(:set_opts))
      @opts.parse!(@args)
      $stdout.puts @options.inspect
      if @options.empty? || @options[:path].nil? || !File.directory?(@options[:path])
        $stderr.puts 'Invalid path specified'
        exit 1
      else
        loop do
          begin
            process!
          rescue Exception => ex
            raise ex if @options[:trace] || SystemExit === ex
            $stderr.print "#{ex.class}: " if ex.class != RuntimeError
            $stderr.puts ex.message
          end
          sleep 5
        end
      end
    end

    protected
    def set_opts(opts)
      opts.banner = "rightmove_wrangler is used to monitor a directory, parse RM format zip files, and submit them via post to an API"
      
      opts.on('-p', '--path PATH', 'Path to watch') do |path|
        @options[:path] = path
      end
      
      opts.on('-u', '--url URL', 'URL to post the data to') do |url|
        @options[:url] = url
      end

      opts.on_tail('-h', '--help', 'Show this message') do
        puts opts
        exit
      end

      opts.on_tail('-v', '--version', 'Print version') do
        puts "rightmove_wrangler #{RightmoveWrangler::VERSION}"
        exit
      end
    end
    
    private
    def process!
      files = Dir.entries(@options[:path])
      if directory_list == files
        $stdout.puts 'Nothing changed since last poll'
        return
      else
        self.directory_list = files
      end
      
      begin
        threads = [] 
        Dir.foreach(@options[:path]) do |file|
          $stdout.puts "Checking #{file}"
          if match = /\.(zip|blm)/i.match(file)
            threads << Thread.new do
              $stdout.puts "Working on #{file}"
              send("work_#{match}_file".to_sym)
            end
          end
        end
        threads.each do |t|
          t.join
          $stdout.puts t[:output]
        end
      rescue Exception => ex
        $stderr.puts ex.inspect
        $stderr.puts ex.backtrace
      end
    end

    def work_blm_file(file)
      blm = BLM.new( File.open(file, "r").read )
      rows = blm.data.collect do |row|
        row_hash = {}
        row.attributes.each do |key, value|
          row_hash[key] = if value =~ IMAGE_REGEX
            $stdout.puts "Instantiated file #{value}"
            instantiate_from_dir(value, @options[:path])
          else
            value
          end
        end
      end
    end

    def work_zip_file(file)
      zip_file = Zip::ZipFile.open("#{@options[:path]}/#{file}")
      archive = Rightmove::Archive.new(zip_file) 
      
      rows = archive.document.data.collect do |row|
        row_hash = {}
        # This is a bit odd, but essentially it actually turns media rows into files
        row.attributes.each do |key, value|
          row_hash[key] = if value =~ IMAGE_REGEX
            $stdout.puts "Instantiated file #{value}"
            instantiate_from_zip_file(value, zip_file)
          else
            value
          end
        end
        row_hash
      end

      payload = {
        row_set: {
          tag: archive.branch_id,
          timestamp: archive.timestamp.to_i,
          rows: rows
        }
      }
      post!(payload)
    end

    def instantiate_from_dir(file_name, dir)
      path = File.join(file_name, dir)
      if File.exists?(path)
        $stdout.puts "Found file: #{path}"
        instantiate_file File.open(path)
      else
        $stdout.puts "Couldn't find file: #{path}"
        file_name
      end
    end

    def instantiate_from_zip_file(file_name, zip_file)
      matching_files = zip_file.entries.select {|v| v.to_s =~ /#{file_name}/ }
      if matching_files.empty?
        $stdout.puts "Couldn't find file: #{file_name}"
        file_name
      else
        $stdout.puts "Found file: #{file_name}"
        file = StringIO.new( zip_file.read(matching_files.first) )
        instantiate_file(file, file_name)
      end
    end

    def instantiate_file(file, file_name = nil, content_type = nil)
      if !file.respond_to?(:original_filename)
        file.class.class_eval { attr_accessor :original_filename }
        file.original_filename = file_name
      end

      if !file.respond_to?(:content_type)
        content_type ||= "image/jpg"
        file.class.class_eval { attr_accessor :content_type }
        file.content_type = content_type
      end

      Faraday::UploadIO.new(file, file_name, file.content_type)
    end

    def post!(payload)
      if @options[:url].nil?
        Thread.current[:output] = "Missing a URL to post the data to"
      end
      
      uri = Addressable::URI.parse(@options[:url])    
      conn = Faraday.new(url: uri.origin) do |builder|
        builder.request  :multipart
        builder.request  :url_encoded
        builder.response :logger
        builder.adapter  :net_http
      end

      params = uri.query_values.merge(payload)
      response = conn.post uri.path, params
      
      if response.status == 200
        Thread.current[:output] = "Server returned a successful response"
        return true
      else
        Thread.current[:output] = "Non 200 response returned from API: #{response.inspect}"
        return false
      end
    end
  end
  
end
