require 'rubygems'
require 'logger'
require 'hpricot'
require 'crypt/blowfish'
require 'base64'
require 'open-uri'

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
    @log.debug "decrypting from #{position} to #{position + 7}"
    decrypted_token += blowfish.decrypt_block(encryptedBytes[position..position + 7]);
    position += 8
  end

  @log.debug "position: #{position} length #{encryptedBytes.length} decrypted length #{decrypted_token.length}"

  npad = decrypted_token.slice(-1)
  if (npad > 0 && npad < 9)
    decrypted_token = decrypted_token.slice(0, decrypted_token.length-npad)
  end

  return decrypted_token
end


#download 4od
def download_4od(prog_id)
  #1. Read the AIS data from C4. This gives the info required to get the flv via rtmpdump
  url = "http://ais.channel4.com/asset/#{prog_id}"
  @log.info "Downloading AIS data from 4od at URL #{@url}"

  begin
    open(url) { |f| @response = f.read }
  rescue OpenURI::HTTPError => the_error
    raise "Cannot download from url #{url}. Error is: #{the_error.message}"
  end


  #Parse it - the inspiration for this comes from http://code.google.com/p/nibor-xbmc-repo/ too.
  doc = Hpricot(@response)
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

  #read program data to generate the filename
  url = "http://www.channel4.com/programmes/asset/#{prog_id}"
  begin
    open(url) { |f| @prog_info_response = f.read }
  rescue OpenURI::HTTPError => the_error
    @log.error "Cannot download from url #{url}. Error is: #{the_error.message}"
    exit 1
  end
  assetInfo = Hpricot(@prog_info_response)
  episodeNumber = (assetInfo/"//episodenumber").text
  seriesNumber = (assetInfo/"//seriesnumber").text
  brandTitle = (assetInfo/"//brandtitle").text
  epId = (assetInfo/"//programmeid").text

  #progGuideUrl is used to pull out metadata from the CH4 website
  progGuideUrl = (assetInfo/"//episodeguideurl").text

  #read program guide to get additional metadata
  seriesInfo = open("http://www.channel4.com#{progGuideUrl}") { |f| Hpricot(f) }

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

  #build rtmpdump command
  command = "rtmpdump --rtmp \"#{rtmpUrl}\" "
  command += "--app \"#{app}\" "
  command += "--playpath \"#{playpath}\" "
  command += "-o \"#{out_file}.flv\" "
  command += '-C O:1 -C O:0 '
  command += '--flashVer "WIN 10,3,183,7" '
  command += '--swfVfy "http://www.channel4.com/static/programmes/asset/flash/swf/4odplayer_am2.swf" '
  @log.info command

  @log.info "Downloading file for #{prog_id}.."
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
  atp_command = "AtomicParsley #{Dir.pwd}/#{out_file}.mp4 --TVNetwork \"Channel4/4od\" --TVShowName \"#{brandTitle}\" --TVSeasonNum #{seriesNumber} --TVEpisodeNum #{episodeNumber} --stik \"TV Show\" --description \"#{desc}\" --TVEpisode \"#{epId}\" --title \"#{fullTitle}\" --overWrite"

  @log.debug "#{atp_command}"
  success = system(atp_command)

  if not success
    raise "Something went wrong running AtomicParsley :(. Your file may not be properly tagged."
  end
end


if ARGV.length == 0 || ARGV[0] == '-h'
  puts "4od-dl.rb [prog_id,prog_id]"
  puts "Downloads a program from 4od"
  puts "prog_id is the 7 digit program ID that you find after the hash in the URL (e.g. 3333316)"
  puts "To specify multiple prog_ids, separate with a comma"
  exit 1
end


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



prog_ids = ARGV[0]
prog_ids = prog_ids.split(",")

prog_ids.each do |prog_id|
  begin #first check it is a valid integer prog_id
    Integer(prog_id)
  rescue
    @log.error "Cannot parse program ID #{prog_id}. Is it a valid program ID?"
  end

  #now download
  begin
    download_4od(prog_id)
  rescue Exception => e
    @log.error "Error downloading program: #{e.message}"
  end
end
