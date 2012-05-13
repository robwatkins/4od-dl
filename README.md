4od-dl
======

Ruby script to download, convert and tag stuff from 4od.

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

ruby 4od-dl.rb ProgID1,ProgID2,ProgID3

progIdsArray is an array of program IDs from 4od. To get these simply visit 4od, find the program you want to play and then note the digits after the hash in the URL. 

For instance the ID for the following programme is 3264880: http://www.channel4.com/programmes/grand-designs/4od#3264880

To Do
======

This is a pretty rough hack so I'd like to add (in no order):

* Ability to download to another directory than the one you're running 4od-dl in
* Basic text-based PVR functionality to find programmes to download
* More control over the filename
* Remove the .flv once downloading is complete

