require "rubygems"
require "rightmove_wrangler/version"
require "fileutils"
require "rightmove"
require "optparse"
require "faraday"
require "addressable/uri"
require "pry"

module RightmoveWrangler
  class Processor
    attr_accessor :directory_list

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
            $stderr.puts '  Use --trace for backtrace.'
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
      if self.directory_list == files
        $stdout.puts 'Nothing changed since last poll'
        return
      else
        self.directory_list = files
      end
      
      begin
        threads = [] 
        Dir.foreach(@options[:path]) do |file|
          $stdout.puts "Checking #{file}"
          if file =~ /\.zip/i
            $stdout.puts "Working on #{file}"
            threads << Thread.new do
              zip_file = Zip::ZipFile.open("#{@options[:path]}/#{file}")
              archive = Rightmove::Archive.new(zip_file) 
              
              rows = archive.document.data.collect do |row|
                row_hash = {}
                # This is a bit odd, but essentially it actually turns media rows into files
                row.attributes.each do |key, value|
                  row_hash[key] = if value =~ /\.(jpg|jpeg|png|gif)/i
                    $stdout.puts "Instantiated file #{value}"
                    instantiate(value, zip_file)
                  else
                    value
                  end
                end
                row_hash
              end
        
              payload = {
                row_set: {
                  rows: rows
                }
              }
              post!(payload)
            end
          else
            $stdout.puts "Not a zip file: #{file}"
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

    def instantiate(file_name, zip_file)
      matching_files = zip_file.entries.select {|v| v.to_s =~ /#{file_name}/ }
      if matching_files.empty?
        $stdout.puts "Couldn't find file: #{file_name}"
        file_name
      else
        $stdout.puts "Found file: #{file_name}"
        file = StringIO.new( zip_file.read(matching_files.first) )
        file.class.class_eval { attr_accessor :original_filename, :content_type }
        file.original_filename = matching_files.first.to_s
        file.content_type = "image/jpg"
        Faraday::UploadIO.new(file, file_name, file.content_type)
      end
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
