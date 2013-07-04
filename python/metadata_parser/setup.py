# vim: tabstop=4 shiftwidth=4 softtabstop=4
#!/usr/bin/env python


import os
from setuptools import setup

def read(fname):
    return open(os.path.join(os.path.dirname(__file__), fname)).read()

setup(
    name = "music_metadata_parser",
    version = "1.0",
    author = "Daniel Jones",
    author_email = "dajones716@gmail.com",
    description = ("Utility for parsing music metadata"),
    packages=['metadata', 'parser'],
)
