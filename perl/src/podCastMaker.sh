#!/bin/bash
# It's not pretty, but I think it's better than what I've got now!

#echo "This script requires mid3v2. If nothing happens, make sure it is installed. Was already installed on my system so I have no idea how it will react if you don't have it installed."
#echo "As coded, the script requires being in the dir you want the output from"

#This part will rename all your files and dir and take the spaces out and replace them with underscores.
SAVEIFS=$IFS
IFS=$(echo -en "\n\b")
#for f in $1; do
#     file=$(echo $f | tr ' ' _)
#     [ ! -f $file ] && mv "$f" $file
#done
#yo
if [ -f mp3s.txt ]
then
	rm mp3s.txt
fi

if [ -f oggs.txt ]
then
	rm oggs.txt
fi
touch mp3s.txt oggs.txt



for file in `ls "$1"` ; do
	declare -i size=${#file}
	if [ $size -gt 4 ]
	then
		if [ ${file: -4}  ==  ".mp3" ]
		then
			mid3v2 -l "$1/$file" >> mp3s_buf.txt
			echo -e "SONG END" >> mp3s_buf.txt
		fi
		if [ ${file: -4} == ".ogg" ]
		then
			vorbiscomment -l "$1/$file" >> oggs_buf.txt
			echo -e "SONG END" >> oggs_buf.txt
		fi
	fi
done


if [ -f ./mp3s_buf.txt ]
then
	cat mp3s_buf.txt > mp3s.txt
	rm mp3s_buf.txt
fi

if [ -f ./oggs_buf.txt ]
then
	cat oggs_buf.txt > oggs.txt
	rm oggs_buf.txt
fi

#/usr/lib/podCastMaker/parser.pl mp3s.txt > post.html

IFS=$SAVEIFS
