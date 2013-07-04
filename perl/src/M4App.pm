#!/usr/bin/perl
=head1 NAME

M4App - The controlling application object for My Project.

=cut

package M4App;
use Wx;
use base 'Wx::App';  # This inherits from Wx::App
use M4Frame;
use Song;
# Here, we'll store object instance data in a class hash
my %frame;

# We must provide an OnInit method which sets up the Application object

sub OnInit
{
    my $self = shift;
#    my @songs = ();
#    my $song1 = new Song();
#    my $song2 = new Song();
#    $song1->setTitle("Hello");
#    $song2->setTitle("World");
#    push @songs, $song1;
#    push @songs, $song2;
#    my @playlist = ();
#    foreach my $song(@songs)
#    {
#	push @playlist, $song->{_title};
#    }

    # Create, store, and display the main window:
    $frame{$self} = M4Frame->new;
    $frame{$self}->Show;
    return 1;    # true value indicates success
}

# Clean up object data
sub DESTROY
{
    my $self = shift;
    delete $frame{$self};
}

1;  # Perl modules must return a true value.
