# 4od-dl version 0.4. https://github.com/robwatkins/4od-dl

require 'rubygems'
require 'logger'
require 'hpricot'
require 'crypt/blowfish'
require 'base64'
require 'open-uri'
require 'optparse'

@log = Logger.new(STDOUT)
@log.sev_threshold = Logger::INFO

@default_search_range = 10 #how far before/after the program ID to search for a MP4 file when the original program ID resolves to a f4m.


class FourODProgramDownloader
  def initialize(program_id, logger, out_path, remux, search_range)
    @search_range = search_range
    @out_dir = out_path
    @program_id = program_id
    @mp4_program_id = nil
    @out_file = nil
    @log = logger
    @metadata = Hash.new
    @remux = remux
  end

  def download_image(url, out_file_name)
    @log.debug "Downloading image from #{url} to #{out_file_name}"
    open(url) {|f|
      File.open(out_file_name,"wb") do |file|
        file.puts f.read
      end
    }
  end


  def download_data(url)
    begin
      doc = open(url) { |f| Hpricot(f) }
      return doc
    rescue OpenURI::HTTPError => the_error
      raise "Cannot download from url #{url}. Error is: #{the_error.message}"
    end
  end

  #AIS data - used to get stream data
  def download_ais(prog_id)
    return download_data("http://ais.channel4.com/asset/#{prog_id}")
  end

  #asset info used for episode related information
  def download_asset(prog_id)
    return download_data("http://www.channel4.com/programmes/asset/#{prog_id}")
  end

  #Program guide used for synopsis
  def download_progguide(prog_guide_url)
    return download_data("http://www.channel4.com#{prog_guide_url}")
  end

  #read all the program metadata in one go - used for tagging and file name generation
  def get_metadata
    doc = download_ais(@program_id)
    streamUri =  (doc/"//streamuri").text
    @metadata[:fileType] = streamUri[-3..-1]
    @metadata[:programName] =  (doc/"//brandtitle").text
    @metadata[:episodeId] =  (doc/"//programmenumber").text

    assetInfo = download_asset(@program_id)
    @metadata[:episodeNumber] = (assetInfo/"//episodenumber").text
    @metadata[:seriesNumber] = (assetInfo/"//seriesnumber").text
    @metadata[:episodeInfo] = (assetInfo/"//episodeinfo").text
    @metadata[:episodeTitle] = (assetInfo/"//episodetitle").text
    @metadata[:brandTitle] = (assetInfo/"//brandtitle").text
    @metadata[:epId] = (assetInfo/"//programmeid").text
    @metadata[:imagePath] = (assetInfo/"//imagepath").text

    @metadata[:title1] = (assetInfo/"//title1").text
    @metadata[:title2] = (assetInfo/"//title2").text

    #progGuideUrl is used to pull out metadata from the CH4 website
    progGuideUrl = (assetInfo/"//episodeguideurl").text

    begin
      #read program guide to get additional metadata
      seriesInfo = download_progguide(progGuideUrl)

      synopsisElem = seriesInfo.at("//meta[@name='synopsis']")
      @metadata[:description] = synopsisElem.nil? ? "" : synopsisElem['content']
    rescue
      @log.error "Unable to read program guide data - the video file will not be fully tagged"
      @log.debug "Program Guide URL: #{progGuideUrl}"
    end
  end


  #check that the AIS data for the program ID points to a MP4 file. If not, search nearby program IDs for a MP4 version of this program.
  #set @mp4_program_id to the MP4 data. This will be used for downloading with rtmpdump
  def check_prog_id
    if (@metadata[:fileType] == "mp4")
      @log.info "AIS data for Program ID #{@program_id} resolves to a MP4"
      @mp4_program_id = @program_id
      return
    elsif (@metadata[:fileType] == "f4m")
      @log.info "AIS data for program ID #{@program_id} returns F4M file. Searching for a MP4 version... (search range: #{@search_range})"
      for i in ((@program_id.to_i - @search_range)..(@program_id.to_i + @search_range))
        if i != @program_id.to_i and (search_prog_id(i, @metadata[:programName], @metadata[:episodeId]))
          @log.info "Found MP4 match: program ID #{i}"
          @mp4_program_id = i
          return
        end
      end
    end

    #Either can't find a mp4 to download or wrong asset ID given
    raise "Unable to find a MP4 version of the program to download :(. Try increasing the search range (--search-range N)."
  end


  #Search for an alternative program ID. Will return true if it finds a matching program (on episode ID and Program Name)
  def search_prog_id(prog_id, programName, episodeId)
    begin
      @log.debug "Trying Program ID #{prog_id}"
      doc = download_ais(prog_id)
      streamUri =  (doc/"//streamuri").text
      fileType = streamUri[-3..-1]
      match_programName =  (doc/"//brandtitle").text
      match_episodeId =  (doc/"//programmenumber").text
      @log.debug "found program #{match_programName} and #{match_episodeId}, type #{streamUri[-3..-1]}"

      return (fileType == "mp4" and programName == match_programName and episodeId == match_episodeId)
    rescue
      return false
    end

  end

  #build filename based on metadata, using title1/title2 tag in AIS data and the episode title (if there is one)
  def generate_filename
    #if episodeTitle != brandTitle (brandTitle looks to be the name of the program) then use this in the filename
    if @metadata[:episodeTitle] != @metadata[:brandTitle]
      out_file = "#{@metadata[:title1]}__#{@metadata[:title2]}__#{@metadata[:episodeTitle]}"
    else #otherwise just use title1/2
      out_file = "#{@metadata[:title1]}__#{@metadata[:title2]}"
    end
    out_file.gsub!(/[^0-9A-Za-z.\-]/, '_') #replace non alphanumerics with underscores

    @out_file = File.join(@out_dir, out_file)
  end


  #Download the program to a given directory
  def download
    get_metadata
    check_prog_id
    generate_filename
    download_stream
    ffmpeg
    tag
    cleanup
  end


  #download the stream using RTMPDump
  def download_stream

    #Read the AIS data from C4. This gives the info required to get the flv via rtmpdump
    doc = download_ais(@mp4_program_id)

    #Parse it - the inspiration for this comes from http://code.google.com/p/nibor-xbmc-repo/ too.
    token =  (doc/"//token").text
    epid =  (doc/"//e").text
    cdn =  (doc/"//cdn").text
    streamUri =  (doc/"//streamuri").text
    decoded_token = decode_token(token)

    if cdn == 'll'
      file = streamUri.split("/e1/")[1]
      out_file = file.split("/")[1].gsub(".mp4",".flv")
      auth = "e=#{epid}&h=#{decoded_token}"

      rtmpUrl = "rtmpe://ll.securestream.channel4.com/a4174/e1"
      app = "a4174/e1"
      playpath = "/#{file}?#{auth}"

    else
      file = streamUri.split("/4oD/")[1]
      fingerprint = (doc/"//fingerprint").text
      slist = (doc/"//slist").text
      auth = "auth=#{decoded_token}&aifp=#{fingerprint}&slist=#{slist}"

      rtmpUrl = streamUri.match('(.*?)mp4:')[1].gsub(".com/",".com:1935/")
      rtmpUrl += "?ovpfv=1.1&" + auth

      app = streamUri.match('.com/(.*?)mp4:')[1]
      app += "?ovpfv=1.1&" + auth

      playpath = streamUri.match('.*?(mp4:.*)')[1]
      playpath += "?" + auth

    end

    @log.debug "rtmpUrl: #{rtmpUrl} app: #{app} playpath: #{playpath}"

    #build rtmpdump command
    command = "rtmpdump --rtmp \"#{rtmpUrl}\" "
    command += "--app \"#{app}\" "
    command += "--playpath \"#{playpath}\" "
    command += "-o \"#{@out_file}.flv\" "
    command += '-C O:1 -C O:0 '
    command += '--flashVer "WIN 10,3,183,7" '
    command += '--swfVfy "http://www.channel4.com/static/programmes/asset/flash/swf/4odplayer-11.34.1.swf" '
    @log.debug command

    @log.info "Downloading file for Program ID #{@mp4_program_id} - saving to #{@out_file}.flv"
    success = system(command)

    if not success
      raise "Something went wrong running rtmpdump :(. Your file may not have downloaded."
    end

    @log.info "Download complete."

  end


  #Run ffmpeg to convert to MP4 - There is an annoying bug in later versions of ffmpeg related to
  #playing MP4s on a PS3 - during playback the video skips and has no sound so is completely unwatchable.
  #Remapping the audio codec to AAC fixes it. I tested this with ffmpeg 0.10.3
  def ffmpeg
    @log.info "Running ffmpeg to convert to MP4"
    ffmpegOutOptions = "-strict experimental -vcodec copy -acodec aac"
    if @remux
      ffmpegOutOptions = "-vcodec copy -acodec copy"
    end      
    ffmpeg_command ="ffmpeg -y -i \"#{@out_file}.flv\"  #{ffmpegOutOptions} \"#{@out_file}.mp4\""
    success = system(ffmpeg_command)

    if not success
      raise "Something went wrong running ffmpeg :(. Your file may not have converted properly."
    end

    @log.info "File converted"
  end

  #Tag with AtomicParsley using the metadata retrieved earlier
  def tag
    @log.info "Tagging file...."
    if @metadata[:episodeNumber] != ""
      fullTitle = "#{@metadata[:episodeNumber]}. #{@metadata[:episodeTitle]}"
    else
      fullTitle = "#{@metadata[:episodeTitle]} - #{@metadata[:episodeInfo]}"
    end
    atp_command = "AtomicParsley \"#{@out_file}.mp4\" --TVNetwork \"Channel4/4od\" --TVShowName \"#{@metadata[:brandTitle]}\" --stik \"TV Show\" --description \"#{@metadata[:description]}\" --TVEpisode \"#{@metadata[:epId]}\" --title \"#{fullTitle}\" --overWrite"

    if @metadata[:seriesNumber] != ""
      atp_command += " --TVSeasonNum #{@metadata[:seriesNumber]}"
    end
    if @metadata[:episodeNumber] != ""
      atp_command += " --TVEpisodeNum #{@metadata[:episodeNumber]}"
    end

    #If it exists, download the image and store in metadata
    if @metadata[:imagePath] != ""
      begin
        image_path = File.join(@out_dir,File.basename(@metadata[:imagePath]))
        download_image("http://www.channel4.com#{@metadata[:imagePath]}", image_path)
        atp_command += " --artwork \"#{image_path}\""
      rescue
        @log.warn "Error downloading thumbnail - video will be tagged without thumbnail"
      end
    end

    @log.debug "#{atp_command}"
    success = system(atp_command)

    if @metadata[:imagePath] != "" && File.exists?(image_path)
      File.delete(image_path)

    end

    if not success
      raise "Something went wrong running AtomicParsley :(. Your file may not be properly tagged."
    end
  end

  #Remove the FLV file
  def cleanup
    @log.debug "Deleting #{@out_file}.flv"
    if File.exists?("#{@out_file}.flv")
      File.delete("#{@out_file}.flv")
    end
  end

  #Method to decode an auth token for use with rtmpdump
  #Idea mostly taken from http://code.google.com/p/nibor-xbmc-repo/source/browse/trunk/plugin.video.4od/fourOD_token_decoder.py
  #Thanks to nibor for writing this in the first place!
  def decode_token(token)
    encryptedBytes = Base64.decode64(token)
    key = "STINGMIMI"
    blowfish = Crypt::Blowfish.new(key)

    position = 0
    decrypted_token = ''

    while position < encryptedBytes.length
      decrypted_token += blowfish.decrypt_block(encryptedBytes[position..position + 7]);
      position += 8
    end

    npad = decrypted_token.slice(-1)
    if (npad > 0 && npad < 9)
      decrypted_token = decrypted_token.slice(0, decrypted_token.length-npad)
    end

    return decrypted_token
  end

end


#Parse parameters (only -p is required)
hash_options = {}
optparse = OptionParser.new do |opts|
  opts.banner = "Usage: 4od-dl [options]"
  opts.on('-p', '--programids ID1,ID2,ID3', "Program IDs to download - this is the 7 digit program ID that you find after the hash in the URL (e.g. 3333316)") do |v|
    hash_options[:pids] = v
  end
  hash_options[:outdir] = Dir.pwd
  opts.on('-o', '--outdir PATH', "Directory to save files to (default = pwd)") do |v|
    hash_options[:outdir] = v
  end
  opts.on('-r', '--remux', "Copy video/audio streams from FLV to MP4 - do not transcode audio") do |v|
    hash_options[:remux] = v
  end
  hash_options[:searchrange] = @default_search_range
  opts.on('-s', '--search-range N', Integer, "Search range to find MP4 versions of a program (default = #{@default_search_range})") do |v|
    hash_options[:searchrange] = v
    raise OptionParser::InvalidArgument, "#{v} invalid (must be >= 0)" if v < 0
  end
  opts.on('-v', '--version', 'Display version information') do
    puts "4od-dl version 0.4 (23-Jan-2013)"
    exit
  end
  opts.on('-d', '--debug', 'Show advanced debugging information') do
    @log.sev_threshold = Logger::DEBUG
  end
  opts.on('-h', '--help', 'Display this help') do
    puts opts
    exit
  end
end

begin
  optparse.parse!
rescue OptionParser::InvalidArgument => e
  puts "ERROR: #{e.message}"
  exit 1
end

if hash_options[:pids].nil?
  puts "Mandatory parameter -p not specified."
  puts optparse
  exit 1
end

if !File.directory?(hash_options[:outdir])
  @log.error "Cannot find given output directory #{hash_options[:outdir]}. Exiting."
  exit 1
end

#Given valid arguments. Check for pre-reqs
@log.debug "looking for rtmpdump"
`which rtmpdump`
if not $?.success?
  @log.error "Cannot find rtmpdump on your path. Please install and try again (I downloaded mine from http://trick77.com/2011/07/30/rtmpdump-2-4-binaries-for-os-x-10-7-lion/)"
  exit 1
end

@log.debug "looking for ffmpeg"
`which ffmpeg`
if not $?.success?
  @log.error "Cannot find ffmpeg on your path. Please install and try again (http://ffmpegmac.net). After extracting copy it to somewhere in your path"
  exit 1
end

@log.debug "looking for AtomicParsley"
`which AtomicParsley`
if not $?.success?
  @log.error "Cannot find AtomicParsley on your path. Please install and try again (http://atomicparsley.sourceforge.net/). After extracting copy it to somewhere in your path"
  exit 1
end

#Download!
hash_options[:pids].split(",").each do |prog_id|
  begin #first check it is a valid integer prog_id
    Integer(prog_id)
  rescue
    @log.error "Cannot parse program ID #{prog_id}. Is it a valid program ID?"
  end

  #now download
  begin
    #Attempt to get a program ID which resolves to a MP4 file for this program, then download the file
    @log.info "Downloading program #{prog_id}..."
    fourOD = FourODProgramDownloader.new(prog_id, @log,hash_options[:outdir],hash_options[:remux],hash_options[:searchrange])
    fourOD.download
  rescue Exception => e
    @log.error "Error downloading program: #{e.message}"
    @log.debug "#{e.backtrace.join("\n")}"
  end
end
