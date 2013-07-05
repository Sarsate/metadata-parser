#vim: tabstop=4 shiftwidth=4 softtabstop=4

#!/usr/bin/env python

import os

from glob import glob
from os.path import join
from subprocess import call
from metadata.parser import MIDParser
from metadata.parser import VorbisParser


def parse_directory(path):
    parse_mp3s(path)
    parse_oggs(path)
    mp3_parser = MIDParser(filepath="mp3s.txt")
    ogg_parser = VorbisParser(filepath="oggs.txt")

    mp3_parser.parse()
    ogg_parser.parse()
    total_playlist = mp3_parser.playlist + ogg_parser.playlist
    return total_playlist


def parse_mp3s(path):
    mp3s = glob(join(path, "*.mp3"))
    for file in mp3s:
        call(["mid3v2", "-l", "\"" + file + "\"", ">>", "mp3s_buf.txt"])
        call(["echo", "\"SONG END\"", ">>", "mp3s_buf.txt"])
    call(["cat", "mp3s_buf.txt", ">", "mp3s.txt"])
    os.remove("mp3s_buf.txt")


def parse_oggs(path):
    mp3s = glob(join(path, "*.mp3"))
    for file in mp3s:
        call(["vorbiscomment", "-l", "\"" + file + "\"", ">>", "oggs_buf.txt"])
        call(["echo", "\"SONG END\"", ">>", "oggs_buf.txt"])
    call(["cat", "ogss_buff.txt", ">", "oggs.txt"])
    os.remove("oggs_buf.txt")
