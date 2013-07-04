#!/usr/bin/perl
package WebParser;
use base qw(HTML::TagParser);
use LWP::Simple ();
use Mojo::DOM;

sub new 
{
	my $class = shift;
	my $self = {
		'genres' => {},
		'bandpage' => "",
	};
	bless $self,$class;
	return $self;
}

sub parseURL {
	my ($self, $url) = @_;
	if($url =~ m/www.jamendo.com/g)
	{
		$self->parse( LWP::Simple::get($url));
		$bandtag = $self->getElementsByAttribute("property","music:musician");
		$self->{'bandpage'} = $bandtag->getAttribute("content");
		#@genretags = $self->getElementsByClassName("search_tag");
		#$genrehash = $self->{'genres'};
		#for my $tag(@genretags)
		#{
		#	 $genrehash{$tag->innerText()} = 1;
		#}
		#print $self->{'genres'};
	}
	elsif($url =~ m/freemusicarchive.org/g) 
	{
		my @genrelist;
		my $dom = Mojo::DOM->new;
		$self->parse(LWP::Simple::get($url));
		$bandtag = $self->getElementsByAttribute("rel","cc:attributionURL");
		$bandpage = $bandtag->getAttribute("href");
	
		#$dom->parse(LWP::Simple::get($url));
		#@genrelist = $dom->find("ul li b a")->pluck('text')->each;
		#for my $genre(@genrelist)
		#{
		#	$genres{$genre} = 1;
		#}
		
	}
	else
	{
#	print "Invalid URL: Use only Jamendo or FMA links.\n";
	return;
	}
}
1;
#package main;
#$link = "http://www.jamendo.com/en/album/13720";
#$parser = webparser->new;
#$parser->parseURL($link);
#print "Band Page: $bandpage \n";
#@genrelist = keys %genres;
#print "Genres: @genrelist \n";
