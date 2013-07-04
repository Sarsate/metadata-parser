#!/usr/bin/perl
#Prototype parsing code. Accepts one file as input and prints organized metadata in the form of an html post.
#The file parsed must be a plaintext file produced from mid3v2. 
#-Danny Jones

package Parser;
use Fcntl;
use Song; #see Song.pm
use WebParser; #see WebParser.pm
use Getopt::Long;
use diagnostics;
GetOptions ('ogg' => \$ogg);
GetOptions ('mp3' => \$mp3);
sub new
{

	my $class = shift;
	$self->{'filepath'} = "";
	$self->{'currentsong'} = new Song();
	$self->{'playlist'} = [];
	$self->{'webparser'} = new WebParser();
	bless $self, $class;
	return $self;
}

sub parseTitle 
{
	my $self = $_[0];
	my $title = substr $_[1], 5;
	chomp $title;
	$self->{'currentsong'}->setTitle( $title );	
}

sub parseGenre
{
	my $self = $_[0];
	my $genre = substr $_[1], 5;
	chomp $genre;
	$self->{'currentsong'}->setGenre( $genre );	
}

sub parseArtist
{
	my $self = $_[0];
	my $artist = substr $_[1], 5;
	chomp $artist;
	$self->{'currentsong'}->setArtist( $artist );	
}

sub parseAlbum
{
	my $self = $_[0];
	my $album = substr $_[1], 5;
	chomp $album;
	$self->{'currentsong'}->setAlbum( $album );	
}
sub parseLicense
{
	my $self = $_[0];
	my $line = substr $_[1], 5;
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
	$self->{'currentsong'}->setLicense( $license );	

}
#FMA format
sub parseURL 
{
	my $self = $_[0];
	my $line = substr ( $_[1], index($_[1], "URL:") + 5);
	chomp $line;
	$self->{'currentsong'}->setSource( $line );
}
#Jamendo Format
sub parseSource
{
	my $self = $_[0];
	my $source = substr $_[1], 5;
	chomp $source;
	$self->{'currentsong'}->setSource( $source);	
}

sub parseMP3 
{
	my ($self) = @_;
	$filepath = $self->{'filepath'};
	my $filename = "";
	open($filename, $filepath) or die "Cannot open file";
	while(<$filename>)
	{
		if($_ =~ m/TIT2/g) 
		{
			$self->parseTitle($_);
		}
		if($_ =~ m/TCON/g)
		{
			$self->parseGenre($_);
		}
		if($_ =~ m/TPE1/g)
		{
			$self->parseArtist($_);
		}
		if($_ =~ m/TALB/g)
		{
			$self->parseAlbum($_);
		}
		if($_ =~ m/TCOP/g)
		{
			$self->parseLicense($_);
		}
		if($_ =~ m/URL:/g)
		{
			$self->parseURL($_);
		}
		if($_ =~ m/WOAS/g)
		{
			$self->parseSource($_);
		}
		if($_ =~ m/SONG END/g) 
		{
			$song = $self->{'currentsong'};
			if(defined($song->{_source}))
			{
				$parser = $self->{'webparser'};
				$parser->parseURL($song->{_source});
				#@genrelist = keys $parser->{'genres'};
				#$genre = join( " ", @genrelist);
				#$song->setGenre($genre);
				$song->setBandPage($parser->{'bandpage'});
			}	
			push $self->{'playlist'}, $self->{'currentsong'};
			$self->{'currentsong'} = new Song();
		}
	}
}
sub parseTitleOGG 
{
	my $self = $_[0];
	my $title = substr $_[1], 6;
	chomp $title;
	$self->{'currentsong'}->setTitle( $title );	
}

sub parseGenreOGG
{
	my $self = $_[0];
	my $genre = substr $_[1], 6;
	chomp $genre;
	$self->{'currentsong'}->setGenre( $genre );	
}

sub parseArtistOGG
{
	my $self = $_[0];
	my $artist = substr $_[1], 12;
	chomp $artist;
	$self->{'currentsong'}->setArtist( $artist );	
}

sub parseAlbumOGG
{
	my $self = $_[0];
	my $album = substr $_[1], 6;
	chomp $album;
	$self->{'currentsong'}->setAlbum( $album );	
}
sub parseOGG 
{
	my ($self) = @_;
	$filepath = $self->{'filepath'};
	my $filename = "";
	open($filename, $filepath) or die "Cannot open file";
	while(<$filename>)
	{
		if($_ =~ m/TITLE/g) 
		{
			$self->parseTitleOGG($_);
		}
		if($_ =~ m/GENRE/g)
		{
			$self->parseGenreOGG($_);
		}
		if($_ =~ m/ALBUMARTIST/g)
		{
			$self->parseArtistOGG($_);
		}
		if($_ =~ m/ALBUM/g)
		{
			$self->parseAlbumOGG($_);
		}
		#if($_ =~ m/TCOP/g)
		#{
		#	$self->parseLicense($_);
		#}
		#if($_ =~ m/URL:/g)
		#{
		#	$self->parseURL($_);
		#}
		#if($_ =~ m/WOAS/g)
		#{
		#	$self->parseSource($_);
		#}
		if($_ =~ m/SONG END/g) 
		{
			$song = $self->{'currentsong'};
			if(defined($song->{_source}))
			{
				$parser = $self->{'webparser'};
				$parser->parseURL($song->{_source});
				#@genrelist = keys $parser->{'genres'};
				#$genre = join( " ", @genrelist);
				#$song->setGenre($genre);
				$song->setBandPage($parser->{'bandpage'});
			}	
			push $self->{'playlist'}, $self->{'currentsong'};
			$self->{'currentsong'} = new Song();
		}
	}
}
sub setFilePath
{
	my ($self, $filepath) = @_;
	$self->{'filepath'} = $filepath if defined($filepath);
	#print "set filepath to $self->{'filepath'} at $filepath\n";
}

sub getSongs
{
	my ($self) = @_;
	$array = $self->{'playlist'};
	return @$array;
}
sub clearSongs
{
	my ($self) = @_;
	$self->{'playlist'} = [];
}
1;
