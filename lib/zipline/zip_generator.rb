# this class acts as a streaming body for rails
# initialize it with an array of the files you want to zip
module Zipline
  require 'open-uri'
  class ZipGenerator
    # takes an array of pairs [[uploader, filename], ... ]
    def initialize(files)
      @files = files
      @iterator = 0
      ZIPLINE_LOGGER.info "initialize: #{files.size}"
    end

    #this is supposed to be streamed!
    def to_s
      throw "stop!"
    end

    def each(&block)
      fake_io_writer = ZipTricks::BlockWrite.new(&block)
      ZipTricks::Streamer.open(fake_io_writer) do |streamer|
        @iterator = 0
        @files.each {|file, name|
          ZIPLINE_LOGGER.info "Calling handle_file size = #{@files.size}"
          handle_file(streamer, file, name) }
          @iterator = 0
      end
    end

    def handle_file(streamer, file, name)
      file = normalize(file)
      write_file(streamer, file, name)
    end

    # This extracts either a url or a local file from the provided file.
    # Currently support carrierwave and paperclip local and remote storage.
    # returns a hash of the form {url: aUrl} or {file: anIoObject}
    def normalize(file)
      ZIPLINE_LOGGER.info "inside normalise"
      if defined?(CarrierWave::Uploader::Base) && file.is_a?(CarrierWave::Uploader::Base)
        ZIPLINE_LOGGER.info "CarrierWave::Uploader::Base"
        file = file.file
      end

      if defined?(Paperclip) && file.is_a?(Paperclip::Attachment)
        if file.options[:storage] == :filesystem
          ZIPLINE_LOGGER.info "Paperclip::filesystem"
          {file: File.open(file.path)}
        else
          ZIPLINE_LOGGER.info "Paperclip::expiring_url"
          {url: file.expiring_url}
        end
      elsif defined?(CarrierWave::Storage::Fog::File) && file.is_a?(CarrierWave::Storage::Fog::File)
        ZIPLINE_LOGGER.info "CarrierWave::Storage::Fog::File"
        {url: file.url}
      elsif defined?(CarrierWave::SanitizedFile) && file.is_a?(CarrierWave::SanitizedFile)
        ZIPLINE_LOGGER.info "CarrierWave::SanitizedFile"
        {file: File.open(file.path)}
      elsif is_io?(file)
        ZIPLINE_LOGGER.info "normalize:is_io file = #{file}"
        {file: file}
      elsif defined?(ActiveStorage::Blob) && file.is_a?(ActiveStorage::Blob)
        ZIPLINE_LOGGER.info "ActiveStorage::Blob"
        {url: file.service_url}
      elsif file.respond_to? :url
        ZIPLINE_LOGGER.info "url"
        {url: file.url}
      elsif file.respond_to? :path
        ZIPLINE_LOGGER.info "path"
        {file: File.open(file.path)}
      elsif file.respond_to? :file
        ZIPLINE_LOGGER.info "file"
        {file: File.open(file.file)}
      else
        ZIPLINE_LOGGER.info "normalize: Bad File/Stream"
        raise(ArgumentError, 'Bad File/Stream')
      end
    end

    def write_file(streamer, file, name)
      ZIPLINE_LOGGER.info "write_file #{@iterator}: #{file} #{name}"
      streamer.write_deflated_file(name) do |writer_for_file|
        if file[:url]
          the_remote_url = file[:url]
          ZIPLINE_LOGGER.info "write_file-Remote url: #{the_remote_url}"
          c = Curl::Easy.new(the_remote_url) do |curl|
            curl.on_body do |data|
              writer_for_file << data
              data.bytesize
            end
          end
          c.perform
        elsif file[:file]
          #ZIPLINE_LOGGER.info "write_file-File #{@iterator}: #{file[:file]} path = #{file[:file].absolute_path}"
          #bytes_expected = file[:file].meta['content-length']
          bytes_copied = IO.copy_stream(file[:file], writer_for_file)
          ZIPLINE_LOGGER.info "write_file-File #{@iterator}: #{file[:file]} bytes_copied = #{bytes_copied}"
          @iterator = @iterator + 1
          #if bytes_expected != bytes_copied
        #    raise "Expected #{bytes_expected} bytes but got #{bytes_copied}"
        #  end
          file[:file].close
        else
          ZIPLINE_LOGGER.info "File: #{file[:file]}"
          raise(ArgumentError, 'write_file: Bad File/Stream')
        end
      end
    end

    def is_io?(io_ish)
      io_ish.respond_to? :read
    end
  end
end
