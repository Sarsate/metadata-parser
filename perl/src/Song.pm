#!/usr/bin/perl
package Song;

sub new 
{
	my $class = shift;
	my $self = {
		_title => shift,
		_artist => "",
		_album => "",
		_genre => "",
		_source => "",
		_license => "",
		_bandpage => "**INSERT LINK HERE**",
		_isNotEmpty => "", #boolean to prevent processing a Song with no information.
	};
	bless $self,$class;
	return $self;
}

sub printSong 
{
	my ($self) = @_;
	if($self->{_isNotEmpty})
	{
		print "Title: $self->{_title}\n"; 
		print "Artist: $self->{_artist}\n"; 
		print "Album: $self->{_album}\n"; 
		print "Genre: $self->{_genre}\n"; 
		print "Source/URL: $self->{_source}\n"; 
		print "License: $self->{_license}\n\n";
		print "Band Page: $self->{_bandpage}\n\n"; 
	}
}

sub printSongHTML
{
	my ($self) = @_;
	my $string = " ";
	if($self->{_isNotEmpty})
	{
		$string .= "<br />\n<ol>\n";
		$string .= "<li><a href=\"$self->{_source}\">$self->{_title}</a>";
		$string .=" by <b>$self->{_artist}</b>";
		$string .= "($self->{_genre}) - $self->{_license} - ";
		$string .= "<a href=\"$self->{_bandpage}\">Website&nbsp;</a></li>\n";
		$string .= "</ol><br />\n";
	}
	return $string;
}

sub setTitle 
{
	my ($self, $title) = @_;
	$self->{_title} = $title if defined($title);
	$self->setIsNotEmpty(1);
}

sub getTitle
{
	my ($self) = @_;
	return $self->{title};
}
sub printTitle
{
	my ($self) = @_;
	print "$self->{_title}";
}
sub setArtist 
{
	my ($self, $artist) = @_;
	$self->{_artist} = $artist if defined($artist);
	$self->setIsNotEmpty(1);
}

sub setAlbum 
{
	my ($self, $album) = @_;
	$self->{_album} = $album if defined($album);
	$self->setIsNotEmpty(1);
}

sub setGenre
{
	my ($self, $genre) = @_;
	$self->{_genre} = $genre if defined($genre);
	#$self->setIsNotEmpty(1);
}

sub setSource
{
	my ($self, $source) = @_;
	$self->{_source} = $source if defined($source);
	$self->setIsNotEmpty(1);
}

sub setLicense 
{
	my ($self, $license) = @_;
	$self->{_license} = $license if defined($license);
	$self->setIsNotEmpty(1);
}
sub setBandPage
{
	my ($self, $bandpage) = @_;
	$self->{_bandpage} = $bandpage if defined($bandpage);
	#$self->setIsNotEmpty(1);
}
sub setIsNotEmpty
{
	my ($self, $boolean) = @_;
	$self->{_isNotEmpty} = $boolean if defined($boolean);
}
1;



