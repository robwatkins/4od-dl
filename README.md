4od-dl
======

Ruby script to download, convert and tag stuff from 4od.


Supported Platforms
===================

This script has been tested on OS X 10.7 (Lion). I imagine it will work on older versions of OS X and perhaps on Linux too, but I've not tested it. 

It definitely won't run on Windows but other than the hardcoded 'which' calls to find rtmpdump/ffmpeg/AtomicParsley it should probably work. Feel free to have a go and send a pull request :).  

Pre-Requisites
=========

To run, the following 3 binaries must be resolvable via your PATH:

1. rtmpdump: Either [download and compile yourself](http://rtmpdump.mplayerhq.hu/) or grab the OS X package from [trick77.com](http://trick77.com/2011/07/30/rtmpdump-2-4-binaries-for-os-x-10-7-lion)
2. ffmpeg: Either [download and compile](http://ffmpeg.org/) or grab the OS X binary from [ffmpegmac.net](http://ffmpegmac.net)
3. AtomicParsley: Either download and compile or grab the binary from [atomicparsley.sourceforge.net](http://atomicparsley.sourceforge.net/)

It also uses the following gems that you must install (I will sort out a Gemfile eventually):

* logger
* hpricot
* crypt

Usage
=====

	Usage: 4od-dl [options]
    	-p, --programids ID1,ID2,ID3     Program IDs/URLs to download (see below)
    	-o, --outdir PATH                Directory to save files to (default = pwd)
	    -r, --remux                      Copy video/audio streams from FLV to MP4 - do not transcode audio
    	-s, --search-range N             Search range to find MP4 versions of a program (default = 10)
	    -v, --version                    Display version information
	    -d, --debug                      Show advanced debugging information
	    -h, --help                       Display help


Program IDs/URLs
============

Starting with 4od-dl v0.5 you can now pass in either a specific program ID or URL to download. In the case of a URL, 4od-dl will scrape the web page to try and determine the correct program ID. You can enter URLs with or without the program ID appended onto the end - both the examples below are acceptable input:

ruby 4od-dl.rb -p http://www.channel4.com/programmes/richard-iii-the-king-in-the-car-park/4od 

ruby 4od-dl.rb -p http://www.channel4.com/programmes/richard-iii-the-king-in-the-car-park/4od#3478419 

It may not always be possible to convert the URL to a program ID so in case of failure use the program ID directly.

A program ID is a 7 digit number which is appended onto the end of the URL when you try to watch the video in your browser. For instance the ID for the following programme is 3264880: http://www.channel4.com/programmes/grand-designs/4od#3264880. 


F4M files
=========

4od-dl does not support downloading F4M files as these are an encrypted form of Adobe HTTP Dynamic Streaming (HDS) and I don't know how to download or decrypt them.

A workaround to this was suggested on the issues tracker by richthespoof. It turns out that there are unencrypted MP4 versions of the episode available but under a different episode ID - I think there are for streaming to a PS3 as 4od supports streaming to a number of different devices. If 4od-dl comes across a f4m file it will automatically search surrounding episode IDs to find a MP4 version to download. The search range is currently 10 either side, but feel free to change the value of @search_range if you have problems.

Copying to your iPad
============

I have had trouble copying some downloaded programmes to my iPad - iTunes just refuses to transfer them. I think it is because the AVC level of the downloaded file is too high (some of the downloads are High@4.1). I have tried changing the AVC level using [subler](http://code.google.com/p/subler/) however it still does not work, most likely because the video stream uses features that the iPad does not support.

The only workaround I have so far is to re-encode the file using [handbrake](http://handbrake.fr/) (or similar). See [issue 4](https://github.com/robwatkins/4od-dl/issues/4) for more information.

Changelog
=========

v0.5 (10-February-2012)

* Added ability to download using URLs as well as program IDs
* Auto retry of failed downloads

v0.4 (22 December 2012):

* Added --search-range / -s parameter to control the search range used to find a MP4 version when the prog ID points to a F4M. Default is 10.

v0.3 (15 December 2012):

* Improved error handling - now ignores some non-fatal errors when downloading a program
* Improved algorithm for generating file name
* AtomicParsley now embeds a program thumbnail into the AVI
* Improved handling of programs with incomplete metadata (such as no Episode/Series number)

v0.2 (11 December 2012): 

* Better support of new-style 4od programs by searching for a MP4 version of the program ID given
* Uses new 4odplayer SWF file (v 11.34.1) with rtmpdump

v0.1 (May 2012):

* First version of 4od-dl

To Do
======

This is a pretty rough hack so I'd like to add (in no order):

* Basic text-based PVR functionality to find programmes to download
* More control over the filename
* Use a Gemfile to manage Gem dependencies
* ~~Support downloads of .f4m files~~ **Workaround added December 2012**
* ~~Ability to download to another directory than the one you're running 4od-dl in~~ **Done 14th May**
* ~~Remove the .flv once downloading is complete~~ **Done 14th May**
