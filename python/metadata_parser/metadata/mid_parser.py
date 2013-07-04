# vim: tabstop=4 shiftwidth=4 softtabstop=4

#!/usr/bin/env python

""" This module contains classes and utilities for parsing the output of the
mid3v2 and vorbiscomment utilities, as well as any websites provided.

The parser stores the information in an array of Song objects.
"""

from metadata.song import Song


class MIDParser(object):
    TITLE_MATCH = "TIT2"
    GENRE_MATCH = "TCON"
    ARTIST_MATCH = "TPE1"
    ALBUM_MATCH = "TALB"
    LICENSE_MATCH = "TCOP"
    SOURCE_MATCH_FMA = "URL:"
    SOURCE_MATCH_JAMENDO = "WOAS"

    def __init__(self, filepath=""):
        self.filepath = filepath
        self.currentsong = Song()
        self.playlist = []
        self.webparser = None

    def parse(self):
        for line in open(self.filepath):
            if self.TITLE_MATCH in line:
                self.parse_title(line)
            if self.GENRE_MATCH in line:
                self.parse_genre(line)
            if self.ARTIST_MATCH in line:
                self.parse_artist(line)
            if self.ALBUM_MATCH in line:
                self.parse_album(line)
            if self.LICENSE_MATCH in line:
                self.parse_license(line)
            if self.SOURCE_MATCH_FMA in line:
                self.parse_url_fma(line)
            if self.SOURCE_MATCH_JAMENDO in line:
                self.parse_url_jamendo(line)
            if "SONG END" in line:
                #TODO: Add functionality for WebParser to extract BandPage
                self.playlist.append(self.currentsong)
                self.currentsong = Song()

    def parse_title(self, line):
        title = line[5:].strip()
        self.currentsong.title = title

    def parse_genre(self, line):
        genre = line[5:].strip()
        self.currentsong.genre = genre

    def parse_artist(self, line):
        artist = line[5:].strip()
        self.currentsong.artist = artist

    def parse_album(self, line):
        album = line[5:].strip()
        self.currentsong.album = album

    def parse_license(self, line):
        line = line[5:].strip()
        song_license = ""
        if "creativecommons.org" in line:
            if "/by/" in line:
                song_license = "CC BY"
            if "/by-sa/" in line:
                song_license = "CC BY-SA"
            if "/by-nc/" in line:
                song_license = "CC BY-NC"
            if "/by-nc-sa/" in line:
                song_license = "CC BY-NC-SA"
        self.currentsong.license = song_license

    def parse_url_fma(self, line):
        url_index = line.find("URL:") + 5
        source = line[url_index:].strip()
        self.currentsong.source = source

    def parse_url_jamendo(self, line):
        source = line[5:].strip()
        self.currentsong.source = source

    def clear_songs(self):
        self.playlist = []


class VorbisParser(MIDParser):
    TITLE_MATCH = "TITLE"
    GENRE_MATCH = "GENRE"
    ARTIST_MATCH = "ALBUMARTIST"
    ALBUM_MATCH = "ALBUM"
    LICENSE_MATCH = "TCOP"

    def parse_title(self, line):
        title = line[6:].strip()
        self.currentsong.title = title

    def parse_genre(self, line):
        genre = line[6:].strip()
        self.currentsong.genre = genre

    def parse_artist(self, line):
        artist = line[12:].strip()
        self.currentsong.artist = artist

    def parse_album(self, line):
        album = line[6:].strip()
        self.currentsong.album = album
