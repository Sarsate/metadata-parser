#!/usr/bin/perl
#Prototype parsing code. Accepts one file as input and prints organized metadata in the form of an html post.
#The file parsed must be a plaintext file produced from mid3v2. 
#-Danny Jones

use Fcntl;
use Song; #see Song.pm
use Getopt::Long;

GetOptions ('ogg' => \$ogg);
GetOptions ('mp3' => \$mp3);
if ($#ARGV +1 != 1)
{
	print "Please specify one file to read. (EX. ./parser.pl filename.txt )\n";
	exit 0;
}
my $filename = "PLAYLIST";
my $filepath = $ARGV[0];
my $currentSong = new Song();
my @playlist = ();

#parsing functions
sub parseTitle 
{
	my $title = substr $_[0], 5;
	chomp $title;
	$currentSong->setTitle( $title );	
}

sub parseGenre
{
	my $genre = substr $_[0], 5;
	chomp $genre;
	$currentSong->setGenre( $genre );	
}

sub parseArtist
{
	my $artist = substr $_[0], 5;
	chomp $artist;
	$currentSong->setArtist( $artist );	
}

sub parseAlbum
{
	my $album = substr $_[0], 5;
	chomp $album;
	$currentSong->setAlbum( $album );	
}
sub parseLicense
{
	my $line = substr $_[0], 5;
	my $license = "";
	#Detects license components in the URL.
	if($line =~ m/creativecommons.org/g)
	{
	
		if($line =~ m/\/by\//g)
		{
			$license = "CC BY";
		}
		if($line =~ m/\/by-sa\//g)
		{
			$license = "CC BY-SA";
		}
		if($line =~ m/\/by-nc\//g)
		{
			$license = "CC BY-NC";
		}
		if($line =~m/\/by-nc-sa\//g)
		{
			$license = "CC BY-NC-SA";
		}
	}
	chomp $license;
	$currentSong->setLicense( $license );	

}
#FMA format
sub parseURL 
{
	my $line = substr ( $_[0], index($_[0], "URL:") + 5);
	chomp $line;
	$currentSong->setSource( $line );
}
#Jamendo Format
sub parseSource
{
	my $source = substr $_[0], 5;
	chomp $source;
	$currentSong->setSource( $source);	
}


open($filename, $filepath) or die "Cannot open file";

#print "Parsing $filepath...\n\n";
sub parseMP3 
{
	while(<$filename>)
	{
		if($_ =~ m/TIT2/g) 
		{
			parseTitle $_;
		}
		if($_ =~ m/TCON/g)
		{
			parseGenre $_;
		}
		if($_ =~ m/TPE1/g)
		{
			parseArtist $_;
		}
		if($_ =~ m/TALB/g)
		{
			parseAlbum $_;
		}
		if($_ =~ m/TCOP/g)
		{
			parseLicense $_;
		}
		if($_ =~ m/URL:/g)
		{
			parseURL $_;
		}
		if($_ =~ m/WOAS/g)
		{
			parseSource $_;
		}
		if($_ =~ m/SONG END/g) 
		{
			push @playlist, $currentSong;
			$currentSong = new Song();
		}
	}
}
sub parseOgg
{
}
if($ogg)
{
	parseOgg;
}
else
{
	parseMP3;
}
	
print "<br />\n<ol>\n";
#foreach our $song(@playlist)
#{
#	$song->printSong();
#}
foreach our $song(@playlist)
{
	$song->printSongHTML();
}
print "</ol><br />\n";
close($filename);


