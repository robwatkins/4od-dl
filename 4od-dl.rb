require 'rubygems'
require 'logger'
require 'hpricot'
require 'crypt/blowfish'
require 'base64'
require 'open-uri'
require 'optparse'

@log = Logger.new(STDOUT)
@log.sev_threshold = Logger::INFO

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


#download 4od
def download_4od(prog_id, out_dir)
  #1. Read the AIS data from C4. This gives the info required to get the flv via rtmpdump
  url = "http://ais.channel4.com/asset/#{prog_id}"
  begin
      doc = open(url) { |f| Hpricot(f) }
  rescue OpenURI::HTTPError => the_error
    @log.error "Cannot download from url #{url}. Error is: #{the_error.message}"
    return
  end
  
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
    
  #read program data to generate the filename
  url = "http://www.channel4.com/programmes/asset/#{prog_id}"
  begin
      assetInfo = open(url) { |f| Hpricot(f) }
  rescue OpenURI::HTTPError => the_error
    @log.error "Cannot download from url #{url}. Error is: #{the_error.message}"
    return
  end
  
  episodeNumber = (assetInfo/"//episodenumber").text
  seriesNumber = (assetInfo/"//seriesnumber").text
  brandTitle = (assetInfo/"//brandtitle").text
  epId = (assetInfo/"//programmeid").text

  #progGuideUrl is used to pull out metadata from the CH4 website
  progGuideUrl = (assetInfo/"//episodeguideurl").text

  #read program guide to get additional metadata
  url = "http://www.channel4.com#{progGuideUrl}"
  begin
      seriesInfo = open(url) { |f| Hpricot(f) }
  rescue OpenURI::HTTPError => the_error
    @log.error "Cannot download from url #{url}. Error is: #{the_error.message}"
    return
  end
  
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

  ffmpeg_command ="ffmpeg -i #{out_file}.flv -vcodec copy -acodec copy #{out_file}.mp4"
  success = system(ffmpeg_command)

  if not success
    raise "Something went wrong running ffmpeg :(. Your file may not have converted properly."
  end

  @log.info "Mp4 created. Tagging."

  fullTitle = "#{episodeNumber}. #{episodeTitle}"
  atp_command = "AtomicParsley #{out_file}.mp4 --TVNetwork \"Channel4/4od\" --TVShowName \"#{brandTitle}\" --TVSeasonNum #{seriesNumber} --TVEpisodeNum #{episodeNumber} --stik \"TV Show\" --description \"#{desc}\" --TVEpisode \"#{epId}\" --title \"#{fullTitle}\" --overWrite"

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
hash_options[:pids].each do |prog_id|
  begin #first check it is a valid integer prog_id
    Integer(prog_id)
  rescue
    @log.error "Cannot parse program ID #{prog_id}. Is it a valid program ID?"
  end

  #now download
  begin
    download_4od(prog_id,hash_options[:outdir])
  rescue Exception => e
    @log.error "Error downloading program: #{e.message}"
    @log.error "#{e.backtrace.join("\n")}"
  end
end
