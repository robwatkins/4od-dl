# 4od-dl version 0.2. https://github.com/robwatkins/4od-dl

require 'rubygems'
require 'logger'
require 'hpricot'
require 'crypt/blowfish'
require 'base64'
require 'open-uri'
require 'optparse'

@log = Logger.new(STDOUT)
@log.sev_threshold = Logger::DEBUG

#Search range determines how far before/after the program ID to search for a MP4 file when the original program ID resolves to a f4m.
@search_range = 5 

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


#AIS data - used to get stream data
def download_ais(prog_id)
  return download_data("http://ais.channel4.com/asset/#{prog_id}")
end

#asset info used for episode related information
def download_asset(prog_id)
  return download_data("http://www.channel4.com/programmes/asset/#{prog_id}")
end

#Program guide used for synopsis
def download_progguide(progGuideUrl)
  return download_data("http://www.channel4.com#{progGuideUrl}")
end

def download_data(url)
  begin
    doc = open(url) { |f| Hpricot(f) }
    return doc
  rescue OpenURI::HTTPError => the_error
    raise "Cannot download from url #{url}. Error is: #{the_error.message}"
  end
end

#download 4od
def get_prog_id(prog_id)

  doc = download_ais(prog_id)
  streamUri =  (doc/"//streamuri").text
  fileType = streamUri[-3..-1]
  programName =  (doc/"//brandtitle").text
  episodeId =  (doc/"//programmenumber").text

  if (fileType == "mp4")
    @log.info "AIS data for Program ID given resolves to a MP4"
    return prog_id
  elsif (fileType == "f4m")
    @log.info "#{prog_id} AIS data returns F4M file. Searching for mp4..."
    for i in ((prog_id.to_i - @search_range)..(prog_id.to_i + @search_range))
      if i != prog_id.to_i and (search_prog_id(i,programName, episodeId))
        @log.info "Found MP4 match: program ID #{i}"
        return i
      end
    end
  end

  #Either can't find a mp4 to download or wrong asset ID given
  raise "Unable to find a program to download :-("
end


#Search for an alternative program ID. Will return true if it finds a matching program (on episode ID and Program Name with a )
def search_prog_id(prog_id, programName, episodeId)
  begin
    
    @log.debug "trying id #{prog_id}"
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

#download 4od
def download_4od(prog_id, out_dir)
  
  #1. Read the AIS data from C4. This gives the info required to get the flv via rtmpdump
  doc = download_ais(prog_id)

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

  assetInfo = download_asset(prog_id)

  episodeNumber = (assetInfo/"//episodenumber").text
  seriesNumber = (assetInfo/"//seriesnumber").text
  brandTitle = (assetInfo/"//brandtitle").text
  epId = (assetInfo/"//programmeid").text

  #progGuideUrl is used to pull out metadata from the CH4 website
  progGuideUrl = (assetInfo/"//episodeguideurl").text
  
  #read program guide to get additional metadata
  seriesInfo = download_progguide(progGuideUrl)

  synopsisElem = seriesInfo.at("//meta[@name='synopsis']")
  desc = synopsisElem.nil? ? "" : synopsisElem['content']

  episodeElem = seriesInfo.at("//meta[@name='episodeTitle']")
  episodeTitle = episodeElem.nil? ? "" : episodeElem['content']

  #build filename based on metadata. should be "showname_epid_title" but shorten if part of data does not exist
  if episodeNumber.empty? && brandTitle == episodeTitle
    out_file = "#{brandTitle}"
  elsif episodeNumber.empty?
    out_file = "#{brandTitle}__#{episodeTitle}"
  elsif brandTitle == episodeTitle
    out_file = "#{brandTitle}__episode_#{episodeNumber}"
  else
    out_file = "#{brandTitle}__episode_#{episodeNumber}__#{episodeTitle}"
  end

  out_file.gsub!(/[^0-9A-Za-z.\-]/, '_') #replace non alphanumerics with underscores

  out_file = File.join(out_dir, out_file)
  
  #build rtmpdump command
  command = "rtmpdump --rtmp \"#{rtmpUrl}\" "
  command += "--app \"#{app}\" "
  command += "--playpath \"#{playpath}\" "
  command += "-o \"#{out_file}.flv\" "
  command += '-C O:1 -C O:0 '
  command += '--flashVer "WIN 10,3,183,7" '
  command += '--swfVfy "http://www.channel4.com/static/programmes/asset/flash/swf/4odplayer_am2.swf" '
  @log.debug command

  @log.info "Downloading file for #{prog_id} - saving to #{out_file}.flv"
  success = system(command)

  if not success
    raise "Something went wrong running rtmpdump :(. Your file may not have downloaded."
  end

  @log.info "Download done. Converting to mp4."

  #There is an annoying bug in later versions of ffmpeg related to playing MP4s on a PS3 - during playback the video skips and has no sound so is completely unwatchable.
  #Remapping the audio codec to AAC fixes it. I tested this with ffmpeg 0.10.3
  ffmpeg_command ="ffmpeg -i \"#{out_file}.flv\" -strict experimental -vcodec copy -acodec aac \"#{out_file}.mp4\""
  success = system(ffmpeg_command)

  if not success
    raise "Something went wrong running ffmpeg :(. Your file may not have converted properly."
  end

  @log.info "Mp4 created. Tagging."

  fullTitle = "#{episodeNumber}. #{episodeTitle}"
  atp_command = "AtomicParsley \"#{out_file}.mp4\" --TVNetwork \"Channel4/4od\" --TVShowName \"#{brandTitle}\" --TVSeasonNum #{seriesNumber} --TVEpisodeNum #{episodeNumber} --stik \"TV Show\" --description \"#{desc}\" --TVEpisode \"#{epId}\" --title \"#{fullTitle}\" --overWrite"

  @log.debug "#{atp_command}"
  success = system(atp_command)

  if not success
    raise "Something went wrong running AtomicParsley :(. Your file may not be properly tagged."
  end

  @log.debug "Deleting #{out_file}.flv"
  File.delete("#{out_file}.flv")

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
  opts.on('-v', '--version', 'Display version information') do
    puts "4od-dl version 0.2 (11-Dec-2012)"
    exit
  end
  opts.on('-h', '--help', 'Display this help') do
    puts opts
    exit
  end
end

optparse.parse!

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
  @log.error "Cannot find ffmpeg on your path. Please install and try again (http://atomicparsley.sourceforge.net/). After extracting copy it to somewhere in your path"
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
    new_prog_id = get_prog_id(prog_id)
    download_4od(new_prog_id,hash_options[:outdir])
  rescue Exception => e
    @log.error "Error downloading program: #{e.message}"
    @log.error "#{e.backtrace.join("\n")}"
  end
end
