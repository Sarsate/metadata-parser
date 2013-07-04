# vim: tabstop=4 shiftwidth=4 softtabstop=4

#!/usr/bin/env python

""" Song pacakge for handling and formatting metadata about individual songs
"""


class Song(object):
    """ Object representation of song metadata. """
    def __init__(self, title=""):
        self.title = title
        self.artist = ""
        self.album = ""
        self.genre = ""
        self.source = ""
        self.license = ""
        self.bandpage = "**INSERT LINK HERE**"

    def print_song(self):
        """ Prints the song information to stdout """
        for name, value in self.__dict__.iteritems():
            if(name != 'empty'):
                print name + " : " + value

    def format_song_html(self):
        """ Returns song information in an HTML format based on
        MusicManumit's posts """

        html_string = "<br />\n <ol>\n"
        html_string += "<li><a = href=\"%s \">%s </a>" \
                        % (self.source, self.title)
        html_string += "by <b>%s </b>" % self.artist
        html_string += "%s - %s - " % (self.genre, self.license)
        html_string += "<a href=\"%s \">Website&nbsp;</a></li>" \
                        % self.bandpage
        html_string += "\n</ol><br />\n"

        return html_string
