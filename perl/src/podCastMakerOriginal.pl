#!usr/bin/perl -s

use File::Slurp;
use File::Basename;

$filename = "mp3s.txt";

if(-e $filename)
{
	unlink($filename);
	system "touch mp3s.txt";
}
$filename = "oggs.txt";

if(-e $filename)
{
	unlink($filename);
	system "touch oggs.txt";
}
$dir = $ARGV[0];

@files = read_dir $dir;
foreach $file (@files) 
{
	($name,$path,$ext) = fileparse("$file",qr"\..[^.]*$");
	if($ext eq ".mp3")
	{
		system "mid3v2 -l \"$dir/$file\" >> mp3s_buf.txt";
                system "echo \"SONG END\" >> mp3s_buf.txt";
	}
	if($ext eq ".ogg")
	{
		system "vorbiscomment -l \"$dir/$file\" >> oggs_buf.txt";
                system "echo \"SONG END\" >> oggs_buf.txt";
	}	
}

$filename = "./mp3s_buf.txt";

if( -e $filename)
{
	system "cat mp3s_buf.txt > mp3s.txt";
	unlink($filename);
}

$filename = "./oggs_buf.txt";
if( -e $filename)
{
	system "cat oggs_buf.txt > oggs.txt";
	unlink($filename);
}

