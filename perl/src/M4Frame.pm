=head1 NAME

M4Frame - The main window for My Project.

=cut

#FIX COMBOBOXEVENT

package M4Frame;
use Wx;
use Song;
use Parser;
use Wx::Event qw(EVT_COMBOBOX);
use Wx::Event qw(EVT_BUTTON);
use Wx::Event qw(EVT_FILEPICKER_CHANGED);
use Wx::Event qw(EVT_DIRPICKER_CHANGED);
use base 'Wx::Frame';
use diagnostics;
# Constructor
sub new
{
    my $class = shift;
    my $title = @_?  shift  :  'M4 Parser';
     	
    my $self = $class->SUPER::new ( undef,      # top-level window
                                    -1,         # no window ID
                                    $title,
                                    [300, 300],   # Allow the system to position the window
                                    [400, 500],   # Default window size
                                  );
    # Invoke Wx::Frame's construtor to build the frame object

    # Create a panel to hold the window's controls
    $self->{'panel'} = Wx::Panel->new($self);
    $self->{'songlist'} = [];
    $self->{'parser'} = new Parser();
    $panel = $self->{'panel'};

    Wx::StaticText->new($panel,     # Parent window
                        -1,         # no window ID
                        'Song:',
                        [47, 20],
                       );
    $self->{'songs'} = Wx::ComboBox->new($panel,
			-1,
			"Song 1",
			[100,18],
			[200,25],
			["Song 1"],
			);
    EVT_COMBOBOX($self, $self->{'songs'},(\&comboBoxEvent));
    $self->{'save'} = Wx::Button->new($panel,
			-1,
			"Update Song",
			[15,220],
			[100,25],
			);
    EVT_BUTTON($self, $self->{'save'}, (\&updateSong));
   # $self->{'new'} = Wx::Button->new($panel,
#			-1,
#			"New Song",
#			[130,220],
#			[80,25],
#			);
    Wx::StaticText->new($panel,     # Parent window
                        -1,         # no window ID
                        'Title:',
                        [50, 60],
                       );
    $self->{'titlebox'} = Wx::TextCtrl->new(
			$panel,
			-1,
			"",
			[100,58],
			[200,25],
                      );
    Wx::StaticText->new($panel,     # Parent window
                        -1,         # no window ID
                        'Album:',
                        [36, 100],
                       );
    $self->{'albumbox'} = Wx::TextCtrl->new(
			$panel,
			-1,
			"",
			[100,98],
			[200,25],
                      );
    Wx::StaticText->new($panel,     # Parent window
                        -1,         # no window ID
                        'Artist:',
                        [20, 140],
                       );
    $self->{'artistbox'} = Wx::TextCtrl->new(
			$panel,
			-1,
			"",
			[70,138],
			[100,25],
                      );
    Wx::StaticText->new($panel,     # Parent window
                        -1,         # no window ID
                        'Genre:',
                        [200, 140],
                       );
    $self->{'genrebox'} = Wx::TextCtrl->new(
			$panel,
			-1,
			"",
			[250,138],
			[100,25],
                      );
    Wx::StaticText->new($panel,     # Parent window
                        -1,         # no window ID
                        'Source:',
                        [13, 180],
                       );
    $self->{'sourcebox'} = Wx::TextCtrl->new(
			$panel,
			-1,
			"",
			[70,178],
			[100,25],
                      );
    Wx::StaticText->new($panel,     # Parent window
                        -1,         # no window ID
                        'License:',
                        [190, 180],
                       );
    $self->{'licensebox'} = Wx::TextCtrl->new(
			$panel,
			-1,
			"",
			[250,178],
			[100,25],
                      );
    Wx::StaticText->new($panel,
			-1,
			"Parse Directory:",
			[25,265],
			);
    $self->{'dirbutton'} = Wx::DirPickerCtrl->new(
			$panel,
			-1,
			".",
			"Parse Directory",
			[140, 260],
			[100, 30],
			);
    EVT_DIRPICKER_CHANGED($self,$self->{'dirbutton'}, \&parseDir);
    Wx::StaticText->new($panel,
			-1,
			"Parse mid3v2 File:",
			[15,305],
			);
    $self->{'filebutton'} = Wx::FilePickerCtrl->new($panel,
			-1,
			".",
			"Select File",
			"*.*",
			[140, 300],
			[100, 30],
			);
    EVT_FILEPICKER_CHANGED($self,$self->{'filebutton'}, \&parseFile);
    
    $self->{'post'} = Wx::Button->new($panel,
			-1,
			"Generate Post!",
			[100,380],
			[150,30],
			);
    EVT_BUTTON($self, $self->{'post'}, (\&generatePost));
    return $self;			
}

sub generatePost
{
	my ($self) = @_;
	my $songs = $self->{'songlist'};
	my @songlist = @$songs;
	my $post = "";
	foreach $song(@songlist)
	{
		$string = $song->printSongHTML();
		$post .= $string;
	}
	system "echo \"$post\" > post.html";
	exec "gedit post.html";
}
sub parseDir
{
	my ($self) = @_;
	my $parser = $self->{'parser'};
	$parser->clearSongs();
	my $dirpath = $self->{'dirbutton'}->GetPath();
	$dirpath =~ s/\ /\\\ /g;
	my $command = "perl ./podCastMaker.pl $dirpath";
	system $command;
	my $filepath = "./mp3s.txt";
	$parser->setFilePath($filepath);
	$parser->parseMP3();
	$filepath = "./oggs.txt";
	$parser->setFilePath($filepath);
	$parser->parseOGG();
	my @songs = $parser->getSongs();
	$self->updateSongList(@songs);
}
sub parseFile
{
	my ($self) = @_;
	my $parser = $self->{'parser'};
	$parser->clearSongs();
	my $filepath = $self->{'filebutton'}->GetPath();
	$parser->setFilePath($filepath);
	$parser->parseMP3();
	my @songs = $parser->getSongs();
	$self->updateSongList(@songs);
}
sub comboBoxEvent {
	my ($self) = @_;
	my $index = $self->{'songs'}->GetSelection();
	my $song = $self->{'songlist'}[$index];
	$self->updateFromSong($song);
}
sub updateSong {
	my ($self) = @_;
	my $index = $self->{'songs'}->GetSelection();
	my $song = $self->{'songlist'}[$index];
	$song->setTitle($self->{'titlebox'}->GetValue());
	$song->setAlbum($self->{'albumbox'}->GetValue());
	$song->setArtist($self->{'artistbox'}->GetValue());
	$song->setGenre($self->{'genrebox'}->GetValue());
	$song->setSource($self->{'sourcebox'}->GetValue());
	$song->setLicense($self->{'licensebox'}->GetValue());
	$self->{'songlist'}[$index] = $song;
	$songNames = $self->formSongTitleList();
	$self->updateComboBox(@$songNames);
}
sub updateComboBox {
	my ($self, @songNames) = @_;
	if(!(defined($songNames[0])))
	{
		@songNames = ("No Songs found");
		$self->{'songlist'}[0] = new Song();
	}
	$index = $self->{'songs'}->GetSelection();
	if($index == -1)
	{
		$index = 0;
	}
	$self->{'songs'}->Destroy();
    	$self->{'songs'} = Wx::ComboBox->new($self->{'panel'},
			-1,
			$songNames[$index],
			[100,18],
			[200,25],
			\@songNames,
			);
	$self->updateFromSong($self->{'songlist'}[$index]);
    EVT_COMBOBOX($self, $self->{'songs'},(\&comboBoxEvent));
}

sub formSongTitleList {
	my ($self) = @_;
	my $songs = $self->{'songlist'};
	my @songTitleList;
	@songlist = @$songs;
	foreach $song(@songlist)
	{
		push @songTitleList, $song->{_title};
	}
	return \@songTitleList;
}
sub updateTitleBox {
	my ($self, $value) = @_;
	if(defined($value))
	{
		$self->{'titlebox'}->SetValue($value);
	}
	else
	{
		$self->{'titlebox'}->SetValue("");
	}
}
sub updateArtistBox {
	my ($self, $value) = @_;
	if(defined($value))
	{
		$self->{'artistbox'}->SetValue($value);
	}
	else
	{
		$self->{'artistbox'}->SetValue("");
	}
}
sub updateAlbumBox {
	my ($self, $value) = @_;
	$self->{'albumbox'}->SetValue($value)  if defined($value);
}
sub updateGenreBox {
	my ($self, $value) = @_;
	$self->{'genrebox'}->SetValue($value)  if defined($value);
}
sub updateSourceBox {
	my ($self, $value) = @_;
	$self->{'sourcebox'}->SetValue($value)  if defined($value);
}
sub updateLicenseBox {
	my ($self, $value) = @_;
	$self->{'licensebox'}->SetValue($value)  if defined($value);
}

sub setSongList {
	my ($self, @songlist) = @_;
	$self->{'songlist'} = [];
	my $title = "hello";
	foreach $song(@songlist)
	{
		if($song->{_isNotEmpty})
		{
			push $self->{'songlist'}, $song;
		}
	}
}
sub updateFromSong {
	my ($self, $song) = @_;
	$self->updateTitleBox($song->{_title});
	$self->updateArtistBox($song->{_artist});
	$self->updateAlbumBox($song->{_album});
	$self->updateGenreBox($song->{_genre});
	$self->updateSourceBox($song->{_source});
	$self->updateLicenseBox($song->{_license});
}

sub updateSongList {
	my ($self, @playlist) = @_;
	$self->setSongList(@playlist);
	$songNames = $self->formSongTitleList();
	$self->updateComboBox(@$songNames);
}	

1;  # Perl modules must return a true value
