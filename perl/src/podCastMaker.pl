#!/usr/bin/perl
#line 2 "/usr/bin/par-archive"

eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell
eval 'exec /usr/bin/perl  -S $0 ${1+"$@"}'
    if 0; # not running under some shell

package __par_pl;

# --- This script must not use any modules at compile time ---
# use strict;

#line 161

my ($par_temp, $progname, @tmpfile);
END { if ($ENV{PAR_CLEAN}) {
    require File::Temp;
    require File::Basename;
    require File::Spec;
    my $topdir = File::Basename::dirname($par_temp);
    outs(qq{Removing files in "$par_temp"});
    File::Find::finddepth(sub { ( -d ) ? rmdir : unlink }, $par_temp);
    rmdir $par_temp;
    # Don't remove topdir because this causes a race with other apps
    # that are trying to start.

    if (-d $par_temp && $^O ne 'MSWin32') {
        # Something went wrong unlinking the temporary directory.  This
        # typically happens on platforms that disallow unlinking shared
        # libraries and executables that are in use. Unlink with a background
        # shell command so the files are no longer in use by this process.
        # Don't do anything on Windows because our parent process will
        # take care of cleaning things up.

        my $tmp = new File::Temp(
            TEMPLATE => 'tmpXXXXX',
            DIR => File::Basename::dirname($topdir),
            SUFFIX => '.cmd',
            UNLINK => 0,
        );

        print $tmp "#!/bin/sh
x=1; while [ \$x -lt 10 ]; do
   rm -rf '$par_temp'
   if [ \! -d '$par_temp' ]; then
       break
   fi
   sleep 1
   x=`expr \$x + 1`
done
rm '" . $tmp->filename . "'
";
            chmod 0700,$tmp->filename;
        my $cmd = $tmp->filename . ' >/dev/null 2>&1 &';
        close $tmp;
        system($cmd);
        outs(qq(Spawned background process to perform cleanup: )
             . $tmp->filename);
    }
} }

BEGIN {
    Internals::PAR::BOOT() if defined &Internals::PAR::BOOT;

    eval {

_par_init_env();

if (exists $ENV{PAR_ARGV_0} and $ENV{PAR_ARGV_0} ) {
    @ARGV = map $ENV{"PAR_ARGV_$_"}, (1 .. $ENV{PAR_ARGC} - 1);
    $0 = $ENV{PAR_ARGV_0};
}
else {
    for (keys %ENV) {
        delete $ENV{$_} if /^PAR_ARGV_/;
    }
}

my $quiet = !$ENV{PAR_DEBUG};

# fix $progname if invoked from PATH
my %Config = (
    path_sep    => ($^O =~ /^MSWin/ ? ';' : ':'),
    _exe        => ($^O =~ /^(?:MSWin|OS2|cygwin)/ ? '.exe' : ''),
    _delim      => ($^O =~ /^MSWin|OS2/ ? '\\' : '/'),
);

_set_progname();
_set_par_temp();

# Magic string checking and extracting bundled modules {{{
my ($start_pos, $data_pos);
{
    local $SIG{__WARN__} = sub {};

    # Check file type, get start of data section {{{
    open _FH, '<', $progname or last;
    binmode(_FH);

    my $buf;
    seek _FH, -8, 2;
    read _FH, $buf, 8;
    last unless $buf eq "\nPAR.pm\n";

    seek _FH, -12, 2;
    read _FH, $buf, 4;
    seek _FH, -12 - unpack("N", $buf), 2;
    read _FH, $buf, 4;

    $data_pos = (tell _FH) - 4;
    # }}}

    # Extracting each file into memory {{{
    my %require_list;
    while ($buf eq "FILE") {
        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        my $fullname = $buf;
        outs(qq(Unpacking file "$fullname"...));
        my $crc = ( $fullname =~ s|^([a-f\d]{8})/|| ) ? $1 : undef;
        my ($basename, $ext) = ($buf =~ m|(?:.*/)?(.*)(\..*)|);

        read _FH, $buf, 4;
        read _FH, $buf, unpack("N", $buf);

        if (defined($ext) and $ext !~ /\.(?:pm|pl|ix|al)$/i) {
            my ($out, $filename) = _tempfile($ext, $crc);
            if ($out) {
                binmode($out);
                print $out $buf;
                close $out;
                chmod 0755, $filename;
            }
            $PAR::Heavy::FullCache{$fullname} = $filename;
            $PAR::Heavy::FullCache{$filename} = $fullname;
        }
        elsif ( $fullname =~ m|^/?shlib/| and defined $ENV{PAR_TEMP} ) {
            # should be moved to _tempfile()
            my $filename = "$ENV{PAR_TEMP}/$basename$ext";
            outs("SHLIB: $filename\n");
            open my $out, '>', $filename or die $!;
            binmode($out);
            print $out $buf;
            close $out;
        }
        else {
            $require_list{$fullname} =
            $PAR::Heavy::ModuleCache{$fullname} = {
                buf => $buf,
                crc => $crc,
                name => $fullname,
            };
        }
        read _FH, $buf, 4;
    }
    # }}}

    local @INC = (sub {
        my ($self, $module) = @_;

        return if ref $module or !$module;

        my $filename = delete $require_list{$module} || do {
            my $key;
            foreach (keys %require_list) {
                next unless /\Q$module\E$/;
                $key = $_; last;
            }
            delete $require_list{$key} if defined($key);
        } or return;

        $INC{$module} = "/loader/$filename/$module";

        if ($ENV{PAR_CLEAN} and defined(&IO::File::new)) {
            my $fh = IO::File->new_tmpfile or die $!;
            binmode($fh);
            print $fh $filename->{buf};
            seek($fh, 0, 0);
            return $fh;
        }
        else {
            my ($out, $name) = _tempfile('.pm', $filename->{crc});
            if ($out) {
                binmode($out);
                print $out $filename->{buf};
                close $out;
            }
            open my $fh, '<', $name or die $!;
            binmode($fh);
            return $fh;
        }

        die "Bootstrapping failed: cannot find $module!\n";
    }, @INC);

    # Now load all bundled files {{{

    # initialize shared object processing
    require XSLoader;
    require PAR::Heavy;
    require Carp::Heavy;
    require Exporter::Heavy;
    PAR::Heavy::_init_dynaloader();

    # now let's try getting helper modules from within
    require IO::File;

    # load rest of the group in
    while (my $filename = (sort keys %require_list)[0]) {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        unless ($INC{$filename} or $filename =~ /BSDPAN/) {
            # require modules, do other executable files
            if ($filename =~ /\.pmc?$/i) {
                require $filename;
            }
            else {
                # Skip ActiveState's sitecustomize.pl file:
                do $filename unless $filename =~ /sitecustomize\.pl$/;
            }
        }
        delete $require_list{$filename};
    }

    # }}}

    last unless $buf eq "PK\003\004";
    $start_pos = (tell _FH) - 4;
}
# }}}

# Argument processing {{{
my @par_args;
my ($out, $bundle, $logfh, $cache_name);

delete $ENV{PAR_APP_REUSE}; # sanitize (REUSE may be a security problem)

$quiet = 0 unless $ENV{PAR_DEBUG};
# Don't swallow arguments for compiled executables without --par-options
if (!$start_pos or ($ARGV[0] eq '--par-options' && shift)) {
    my %dist_cmd = qw(
        p   blib_to_par
        i   install_par
        u   uninstall_par
        s   sign_par
        v   verify_par
    );

    # if the app is invoked as "appname --par-options --reuse PROGRAM @PROG_ARGV",
    # use the app to run the given perl code instead of anything from the
    # app itself (but still set up the normal app environment and @INC)
    if (@ARGV and $ARGV[0] eq '--reuse') {
        shift @ARGV;
        $ENV{PAR_APP_REUSE} = shift @ARGV;
    }
    else { # normal parl behaviour

        my @add_to_inc;
        while (@ARGV) {
            $ARGV[0] =~ /^-([AIMOBLbqpiusTv])(.*)/ or last;

            if ($1 eq 'I') {
                push @add_to_inc, $2;
            }
            elsif ($1 eq 'M') {
                eval "use $2";
            }
            elsif ($1 eq 'A') {
                unshift @par_args, $2;
            }
            elsif ($1 eq 'O') {
                $out = $2;
            }
            elsif ($1 eq 'b') {
                $bundle = 'site';
            }
            elsif ($1 eq 'B') {
                $bundle = 'all';
            }
            elsif ($1 eq 'q') {
                $quiet = 1;
            }
            elsif ($1 eq 'L') {
                open $logfh, ">>", $2 or die "XXX: Cannot open log: $!";
            }
            elsif ($1 eq 'T') {
                $cache_name = $2;
            }

            shift(@ARGV);

            if (my $cmd = $dist_cmd{$1}) {
                delete $ENV{'PAR_TEMP'};
                init_inc();
                require PAR::Dist;
                &{"PAR::Dist::$cmd"}() unless @ARGV;
                &{"PAR::Dist::$cmd"}($_) for @ARGV;
                exit;
            }
        }

        unshift @INC, @add_to_inc;
    }
}

# XXX -- add --par-debug support!

# }}}

# Output mode (-O) handling {{{
if ($out) {
    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require IO::File;
        require Archive::Zip;
    }

    my $par = shift(@ARGV);
    my $zip;


    if (defined $par) {
        open my $fh, '<', $par or die "Cannot find '$par': $!";
        binmode($fh);
        bless($fh, 'IO::File');

        $zip = Archive::Zip->new;
        ( $zip->readFromFileHandle($fh, $par) == Archive::Zip::AZ_OK() )
            or die "Read '$par' error: $!";
    }


    my %env = do {
        if ($zip and my $meta = $zip->contents('META.yml')) {
            $meta =~ s/.*^par:$//ms;
            $meta =~ s/^\S.*//ms;
            $meta =~ /^  ([^:]+): (.+)$/mg;
        }
    };

    # Open input and output files {{{
    local $/ = \4;

    if (defined $par) {
        open PAR, '<', $par or die "$!: $par";
        binmode(PAR);
        die "$par is not a PAR file" unless <PAR> eq "PK\003\004";
    }

    CreatePath($out) ;
    
    my $fh = IO::File->new(
        $out,
        IO::File::O_CREAT() | IO::File::O_WRONLY() | IO::File::O_TRUNC(),
        0777,
    ) or die $!;
    binmode($fh);

    $/ = (defined $data_pos) ? \$data_pos : undef;
    seek _FH, 0, 0;
    my $loader = scalar <_FH>;
    if (!$ENV{PAR_VERBATIM} and $loader =~ /^(?:#!|\@rem)/) {
        require PAR::Filter::PodStrip;
        PAR::Filter::PodStrip->new->apply(\$loader, $0)
    }
    foreach my $key (sort keys %env) {
        my $val = $env{$key} or next;
        $val = eval $val if $val =~ /^['"]/;
        my $magic = "__ENV_PAR_" . uc($key) . "__";
        my $set = "PAR_" . uc($key) . "=$val";
        $loader =~ s{$magic( +)}{
            $magic . $set . (' ' x (length($1) - length($set)))
        }eg;
    }
    $fh->print($loader);
    $/ = undef;
    # }}}

    # Write bundled modules {{{
    if ($bundle) {
        require PAR::Heavy;
        PAR::Heavy::_init_dynaloader();
        init_inc();

        require_modules();

        my @inc = sort {
            length($b) <=> length($a)
        } grep {
            !/BSDPAN/
        } grep {
            ($bundle ne 'site') or
            ($_ ne $Config::Config{archlibexp} and
             $_ ne $Config::Config{privlibexp});
        } @INC;

        # File exists test added to fix RT #41790:
        # Funny, non-existing entry in _<....auto/Compress/Raw/Zlib/autosplit.ix.
        # This is a band-aid fix with no deeper grasp of the issue.
        # Somebody please go through the pain of understanding what's happening,
        # I failed. -- Steffen
        my %files;
        /^_<(.+)$/ and -e $1 and $files{$1}++ for keys %::;
        $files{$_}++ for values %INC;

        my $lib_ext = $Config::Config{lib_ext};
        my %written;

        foreach (sort keys %files) {
            my ($name, $file);

            foreach my $dir (@inc) {
                if ($name = $PAR::Heavy::FullCache{$_}) {
                    $file = $_;
                    last;
                }
                elsif (/^(\Q$dir\E\/(.*[^Cc]))\Z/i) {
                    ($file, $name) = ($1, $2);
                    last;
                }
                elsif (m!^/loader/[^/]+/(.*[^Cc])\Z!) {
                    if (my $ref = $PAR::Heavy::ModuleCache{$1}) {
                        ($file, $name) = ($ref, $1);
                        last;
                    }
                    elsif (-f "$dir/$1") {
                        ($file, $name) = ("$dir/$1", $1);
                        last;
                    }
                }
            }

            next unless defined $name and not $written{$name}++;
            next if !ref($file) and $file =~ /\.\Q$lib_ext\E$/;
            outs( join "",
                qq(Packing "), ref $file ? $file->{name} : $file,
                qq("...)
            );

            my $content;
            if (ref($file)) {
                $content = $file->{buf};
            }
            else {
                open FILE, '<', $file or die "Can't open $file: $!";
                binmode(FILE);
                $content = <FILE>;
                close FILE;

                PAR::Filter::PodStrip->new->apply(\$content, $file)
                    if !$ENV{PAR_VERBATIM} and $name =~ /\.(?:pm|ix|al)$/i;

                PAR::Filter::PatchContent->new->apply(\$content, $file, $name);
            }

            outs(qq(Written as "$name"));
            $fh->print("FILE");
            $fh->print(pack('N', length($name) + 9));
            $fh->print(sprintf(
                "%08x/%s", Archive::Zip::computeCRC32($content), $name
            ));
            $fh->print(pack('N', length($content)));
            $fh->print($content);
        }
    }
    # }}}

    # Now write out the PAR and magic strings {{{
    $zip->writeToFileHandle($fh) if $zip;

    $cache_name = substr $cache_name, 0, 40;
    if (!$cache_name and my $mtime = (stat($out))[9]) {
        my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
            || eval { require Digest::SHA1; Digest::SHA1->new }
            || eval { require Digest::MD5; Digest::MD5->new };

        # Workaround for bug in Digest::SHA 5.38 and 5.39
        my $sha_version = eval { $Digest::SHA::VERSION } || 0;
        if ($sha_version eq '5.38' or $sha_version eq '5.39') {
            $ctx->addfile($out, "b") if ($ctx);
        }
        else {
            if ($ctx and open(my $fh, "<$out")) {
                binmode($fh);
                $ctx->addfile($fh);
                close($fh);
            }
        }

        $cache_name = $ctx ? $ctx->hexdigest : $mtime;
    }
    $cache_name .= "\0" x (41 - length $cache_name);
    $cache_name .= "CACHE";
    $fh->print($cache_name);
    $fh->print(pack('N', $fh->tell - length($loader)));
    $fh->print("\nPAR.pm\n");
    $fh->close;
    chmod 0755, $out;
    # }}}

    exit;
}
# }}}

# Prepare $progname into PAR file cache {{{
{
    last unless defined $start_pos;

    _fix_progname();

    # Now load the PAR file and put it into PAR::LibCache {{{
    require PAR;
    PAR::Heavy::_init_dynaloader();


    {
        #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';
        require File::Find;
        require Archive::Zip;
    }
    my $zip = Archive::Zip->new;
    my $fh = IO::File->new;
    $fh->fdopen(fileno(_FH), 'r') or die "$!: $@";
    $zip->readFromFileHandle($fh, $progname) == Archive::Zip::AZ_OK() or die "$!: $@";

    push @PAR::LibCache, $zip;
    $PAR::LibCache{$progname} = $zip;

    $quiet = !$ENV{PAR_DEBUG};
    outs(qq(\$ENV{PAR_TEMP} = "$ENV{PAR_TEMP}"));

    if (defined $ENV{PAR_TEMP}) { # should be set at this point!
        foreach my $member ( $zip->members ) {
            next if $member->isDirectory;
            my $member_name = $member->fileName;
            next unless $member_name =~ m{
                ^
                /?shlib/
                (?:$Config::Config{version}/)?
                (?:$Config::Config{archname}/)?
                ([^/]+)
                $
            }x;
            my $extract_name = $1;
            my $dest_name = File::Spec->catfile($ENV{PAR_TEMP}, $extract_name);
            if (-f $dest_name && -s _ == $member->uncompressedSize()) {
                outs(qq(Skipping "$member_name" since it already exists at "$dest_name"));
            } else {
                outs(qq(Extracting "$member_name" to "$dest_name"));
                $member->extractToFileNamed($dest_name);
                chmod(0555, $dest_name) if $^O eq "hpux";
            }
        }
    }
    # }}}
}
# }}}

# If there's no main.pl to run, show usage {{{
unless ($PAR::LibCache{$progname}) {
    die << "." unless @ARGV;
Usage: $0 [ -Alib.par ] [ -Idir ] [ -Mmodule ] [ src.par ] [ program.pl ]
       $0 [ -B|-b ] [-Ooutfile] src.par
.
    $ENV{PAR_PROGNAME} = $progname = $0 = shift(@ARGV);
}
# }}}

sub CreatePath {
    my ($name) = @_;
    
    require File::Basename;
    my ($basename, $path, $ext) = File::Basename::fileparse($name, ('\..*'));
    
    require File::Path;
    
    File::Path::mkpath($path) unless(-e $path); # mkpath dies with error
}

sub require_modules {
    #local $INC{'Cwd.pm'} = __FILE__ if $^O ne 'MSWin32';

    require lib;
    require DynaLoader;
    require integer;
    require strict;
    require warnings;
    require vars;
    require Carp;
    require Carp::Heavy;
    require Errno;
    require Exporter::Heavy;
    require Exporter;
    require Fcntl;
    require File::Temp;
    require File::Spec;
    require XSLoader;
    require Config;
    require IO::Handle;
    require IO::File;
    require Compress::Zlib;
    require Archive::Zip;
    require PAR;
    require PAR::Heavy;
    require PAR::Dist;
    require PAR::Filter::PodStrip;
    require PAR::Filter::PatchContent;
    require attributes;
    eval { require Cwd };
    eval { require Win32 };
    eval { require Scalar::Util };
    eval { require Archive::Unzip::Burst };
    eval { require Tie::Hash::NamedCapture };
    eval { require PerlIO; require PerlIO::scalar };
}

# The C version of this code appears in myldr/mktmpdir.c
# This code also lives in PAR::SetupTemp as set_par_temp_env!
sub _set_par_temp {
    if (defined $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/) {
        $par_temp = $1;
        return;
    }

    foreach my $path (
        (map $ENV{$_}, qw( PAR_TMPDIR TMPDIR TEMPDIR TEMP TMP )),
        qw( C:\\TEMP /tmp . )
    ) {
        next unless defined $path and -d $path and -w $path;
        my $username;
        my $pwuid;
        # does not work everywhere:
        eval {($pwuid) = getpwuid($>) if defined $>;};

        if ( defined(&Win32::LoginName) ) {
            $username = &Win32::LoginName;
        }
        elsif (defined $pwuid) {
            $username = $pwuid;
        }
        else {
            $username = $ENV{USERNAME} || $ENV{USER} || 'SYSTEM';
        }
        $username =~ s/\W/_/g;

        my $stmpdir = "$path$Config{_delim}par-$username";
        mkdir $stmpdir, 0755;
        if (!$ENV{PAR_CLEAN} and my $mtime = (stat($progname))[9]) {
            open (my $fh, "<". $progname);
            seek $fh, -18, 2;
            sysread $fh, my $buf, 6;
            if ($buf eq "\0CACHE") {
                seek $fh, -58, 2;
                sysread $fh, $buf, 41;
                $buf =~ s/\0//g;
                $stmpdir .= "$Config{_delim}cache-" . $buf;
            }
            else {
                my $ctx = eval { require Digest::SHA; Digest::SHA->new(1) }
                    || eval { require Digest::SHA1; Digest::SHA1->new }
                    || eval { require Digest::MD5; Digest::MD5->new };

                # Workaround for bug in Digest::SHA 5.38 and 5.39
                my $sha_version = eval { $Digest::SHA::VERSION } || 0;
                if ($sha_version eq '5.38' or $sha_version eq '5.39') {
                    $ctx->addfile($progname, "b") if ($ctx);
                }
                else {
                    if ($ctx and open(my $fh, "<$progname")) {
                        binmode($fh);
                        $ctx->addfile($fh);
                        close($fh);
                    }
                }

                $stmpdir .= "$Config{_delim}cache-" . ( $ctx ? $ctx->hexdigest : $mtime );
            }
            close($fh);
        }
        else {
            $ENV{PAR_CLEAN} = 1;
            $stmpdir .= "$Config{_delim}temp-$$";
        }

        $ENV{PAR_TEMP} = $stmpdir;
        mkdir $stmpdir, 0755;
        last;
    }

    $par_temp = $1 if $ENV{PAR_TEMP} and $ENV{PAR_TEMP} =~ /(.+)/;
}

sub _tempfile {
    my ($ext, $crc) = @_;
    my ($fh, $filename);

    $filename = "$par_temp/$crc$ext";

    if ($ENV{PAR_CLEAN}) {
        unlink $filename if -e $filename;
        push @tmpfile, $filename;
    }
    else {
        return (undef, $filename) if (-r $filename);
    }

    open $fh, '>', $filename or die $!;
    binmode($fh);
    return($fh, $filename);
}

# same code lives in PAR::SetupProgname::set_progname
sub _set_progname {
    if (defined $ENV{PAR_PROGNAME} and $ENV{PAR_PROGNAME} =~ /(.+)/) {
        $progname = $1;
    }

    $progname ||= $0;

    if ($ENV{PAR_TEMP} and index($progname, $ENV{PAR_TEMP}) >= 0) {
        $progname = substr($progname, rindex($progname, $Config{_delim}) + 1);
    }

    if (!$ENV{PAR_PROGNAME} or index($progname, $Config{_delim}) >= 0) {
        if (open my $fh, '<', $progname) {
            return if -s $fh;
        }
        if (-s "$progname$Config{_exe}") {
            $progname .= $Config{_exe};
            return;
        }
    }

    foreach my $dir (split /\Q$Config{path_sep}\E/, $ENV{PATH}) {
        next if exists $ENV{PAR_TEMP} and $dir eq $ENV{PAR_TEMP};
        $dir =~ s/\Q$Config{_delim}\E$//;
        (($progname = "$dir$Config{_delim}$progname$Config{_exe}"), last)
            if -s "$dir$Config{_delim}$progname$Config{_exe}";
        (($progname = "$dir$Config{_delim}$progname"), last)
            if -s "$dir$Config{_delim}$progname";
    }
}

sub _fix_progname {
    $0 = $progname ||= $ENV{PAR_PROGNAME};
    if (index($progname, $Config{_delim}) < 0) {
        $progname = ".$Config{_delim}$progname";
    }

    # XXX - hack to make PWD work
    my $pwd = (defined &Cwd::getcwd) ? Cwd::getcwd()
                : ((defined &Win32::GetCwd) ? Win32::GetCwd() : `pwd`);
    chomp($pwd);
    $progname =~ s/^(?=\.\.?\Q$Config{_delim}\E)/$pwd$Config{_delim}/;

    $ENV{PAR_PROGNAME} = $progname;
}

sub _par_init_env {
    if ( $ENV{PAR_INITIALIZED}++ == 1 ) {
        return;
    } else {
        $ENV{PAR_INITIALIZED} = 2;
    }

    for (qw( SPAWNED TEMP CLEAN DEBUG CACHE PROGNAME ARGC ARGV_0 ) ) {
        delete $ENV{'PAR_'.$_};
    }
    for (qw/ TMPDIR TEMP CLEAN DEBUG /) {
        $ENV{'PAR_'.$_} = $ENV{'PAR_GLOBAL_'.$_} if exists $ENV{'PAR_GLOBAL_'.$_};
    }

    my $par_clean = "__ENV_PAR_CLEAN__               ";

    if ($ENV{PAR_TEMP}) {
        delete $ENV{PAR_CLEAN};
    }
    elsif (!exists $ENV{PAR_GLOBAL_CLEAN}) {
        my $value = substr($par_clean, 12 + length("CLEAN"));
        $ENV{PAR_CLEAN} = $1 if $value =~ /^PAR_CLEAN=(\S+)/;
    }
}

sub outs {
    return if $quiet;
    if ($logfh) {
        print $logfh "@_\n";
    }
    else {
        print "@_\n";
    }
}

sub init_inc {
    require Config;
    push @INC, grep defined, map $Config::Config{$_}, qw(
        archlibexp privlibexp sitearchexp sitelibexp
        vendorarchexp vendorlibexp
    );
}

########################################################################
# The main package for script execution

package main;

require PAR;
unshift @INC, \&PAR::find_par;
PAR->import(@par_args);

die qq(par.pl: Can't open perl script "$progname": No such file or directory\n)
    unless -e $progname;

do $progname;
CORE::exit($1) if ($@ =~/^_TK_EXIT_\((\d+)\)/);
die $@ if $@;

};

$::__ERROR = $@ if $@;
}

CORE::exit($1) if ($::__ERROR =~/^_TK_EXIT_\((\d+)\)/);
die $::__ERROR if $::__ERROR;

1;

#line 1014

__END__
FILE   962c2f1d/Archive/Zip.pm  C)#line 1 "/home/danny/perl5/lib/perl5/Archive/Zip.pm"
package Archive::Zip;

use strict;
BEGIN {
    require 5.003_96;
}
use UNIVERSAL           ();
use Carp                ();
use Cwd                 ();
use IO::File            ();
use IO::Seekable        ();
use Compress::Raw::Zlib ();
use File::Spec          ();
use File::Temp          ();
use FileHandle          ();

use vars qw( $VERSION @ISA );
BEGIN {
    $VERSION = '1.30';

    require Exporter;
    @ISA = qw( Exporter );
}

use vars qw( $ChunkSize $ErrorHandler );
BEGIN {
    # This is the size we'll try to read, write, and (de)compress.
    # You could set it to something different if you had lots of memory
    # and needed more speed.
    $ChunkSize ||= 32768;

    $ErrorHandler = \&Carp::carp;
}

# BEGIN block is necessary here so that other modules can use the constants.
use vars qw( @EXPORT_OK %EXPORT_TAGS );
BEGIN {
    @EXPORT_OK   = ('computeCRC32');
    %EXPORT_TAGS = (
        CONSTANTS => [ qw(
            FA_MSDOS
            FA_UNIX
            GPBF_ENCRYPTED_MASK
            GPBF_DEFLATING_COMPRESSION_MASK
            GPBF_HAS_DATA_DESCRIPTOR_MASK
            COMPRESSION_STORED
            COMPRESSION_DEFLATED
            COMPRESSION_LEVEL_NONE
            COMPRESSION_LEVEL_DEFAULT
            COMPRESSION_LEVEL_FASTEST
            COMPRESSION_LEVEL_BEST_COMPRESSION
            IFA_TEXT_FILE_MASK
            IFA_TEXT_FILE
            IFA_BINARY_FILE
            ) ],

        MISC_CONSTANTS => [ qw(
            FA_AMIGA
            FA_VAX_VMS
            FA_VM_CMS
            FA_ATARI_ST
            FA_OS2_HPFS
            FA_MACINTOSH
            FA_Z_SYSTEM
            FA_CPM
            FA_TOPS20
            FA_WINDOWS_NTFS
            FA_QDOS
            FA_ACORN
            FA_VFAT
            FA_MVS
            FA_BEOS
            FA_TANDEM
            FA_THEOS
            GPBF_IMPLODING_8K_SLIDING_DICTIONARY_MASK
            GPBF_IMPLODING_3_SHANNON_FANO_TREES_MASK
            GPBF_IS_COMPRESSED_PATCHED_DATA_MASK
            COMPRESSION_SHRUNK
            DEFLATING_COMPRESSION_NORMAL
            DEFLATING_COMPRESSION_MAXIMUM
            DEFLATING_COMPRESSION_FAST
            DEFLATING_COMPRESSION_SUPER_FAST
            COMPRESSION_REDUCED_1
            COMPRESSION_REDUCED_2
            COMPRESSION_REDUCED_3
            COMPRESSION_REDUCED_4
            COMPRESSION_IMPLODED
            COMPRESSION_TOKENIZED
            COMPRESSION_DEFLATED_ENHANCED
            COMPRESSION_PKWARE_DATA_COMPRESSION_LIBRARY_IMPLODED
            ) ],

        ERROR_CODES => [ qw(
            AZ_OK
            AZ_STREAM_END
            AZ_ERROR
            AZ_FORMAT_ERROR
            AZ_IO_ERROR
            ) ],

        # For Internal Use Only
        PKZIP_CONSTANTS => [ qw(
            SIGNATURE_FORMAT
            SIGNATURE_LENGTH
            LOCAL_FILE_HEADER_SIGNATURE
            LOCAL_FILE_HEADER_FORMAT
            LOCAL_FILE_HEADER_LENGTH
            CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE
            DATA_DESCRIPTOR_FORMAT
            DATA_DESCRIPTOR_LENGTH
            DATA_DESCRIPTOR_SIGNATURE
            DATA_DESCRIPTOR_FORMAT_NO_SIG
            DATA_DESCRIPTOR_LENGTH_NO_SIG
            CENTRAL_DIRECTORY_FILE_HEADER_FORMAT
            CENTRAL_DIRECTORY_FILE_HEADER_LENGTH
            END_OF_CENTRAL_DIRECTORY_SIGNATURE
            END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING
            END_OF_CENTRAL_DIRECTORY_FORMAT
            END_OF_CENTRAL_DIRECTORY_LENGTH
            ) ],

        # For Internal Use Only
        UTILITY_METHODS => [ qw(
            _error
            _printError
            _ioError
            _formatError
            _subclassResponsibility
            _binmode
            _isSeekable
            _newFileHandle
            _readSignature
            _asZipDirName
            ) ],
    );

    # Add all the constant names and error code names to @EXPORT_OK
    Exporter::export_ok_tags( qw(
        CONSTANTS
        ERROR_CODES
        PKZIP_CONSTANTS
        UTILITY_METHODS
        MISC_CONSTANTS
        ) );

}

# Error codes
use constant AZ_OK           => 0;
use constant AZ_STREAM_END   => 1;
use constant AZ_ERROR        => 2;
use constant AZ_FORMAT_ERROR => 3;
use constant AZ_IO_ERROR     => 4;

# File types
# Values of Archive::Zip::Member->fileAttributeFormat()

use constant FA_MSDOS        => 0;
use constant FA_AMIGA        => 1;
use constant FA_VAX_VMS      => 2;
use constant FA_UNIX         => 3;
use constant FA_VM_CMS       => 4;
use constant FA_ATARI_ST     => 5;
use constant FA_OS2_HPFS     => 6;
use constant FA_MACINTOSH    => 7;
use constant FA_Z_SYSTEM     => 8;
use constant FA_CPM          => 9;
use constant FA_TOPS20       => 10;
use constant FA_WINDOWS_NTFS => 11;
use constant FA_QDOS         => 12;
use constant FA_ACORN        => 13;
use constant FA_VFAT         => 14;
use constant FA_MVS          => 15;
use constant FA_BEOS         => 16;
use constant FA_TANDEM       => 17;
use constant FA_THEOS        => 18;

# general-purpose bit flag masks
# Found in Archive::Zip::Member->bitFlag()

use constant GPBF_ENCRYPTED_MASK             => 1 << 0;
use constant GPBF_DEFLATING_COMPRESSION_MASK => 3 << 1;
use constant GPBF_HAS_DATA_DESCRIPTOR_MASK   => 1 << 3;

# deflating compression types, if compressionMethod == COMPRESSION_DEFLATED
# ( Archive::Zip::Member->bitFlag() & GPBF_DEFLATING_COMPRESSION_MASK )

use constant DEFLATING_COMPRESSION_NORMAL     => 0 << 1;
use constant DEFLATING_COMPRESSION_MAXIMUM    => 1 << 1;
use constant DEFLATING_COMPRESSION_FAST       => 2 << 1;
use constant DEFLATING_COMPRESSION_SUPER_FAST => 3 << 1;

# compression method

# these two are the only ones supported in this module
use constant COMPRESSION_STORED                 => 0; # file is stored (no compression)
use constant COMPRESSION_DEFLATED               => 8; # file is Deflated
use constant COMPRESSION_LEVEL_NONE             => 0;
use constant COMPRESSION_LEVEL_DEFAULT          => -1;
use constant COMPRESSION_LEVEL_FASTEST          => 1;
use constant COMPRESSION_LEVEL_BEST_COMPRESSION => 9;

# internal file attribute bits
# Found in Archive::Zip::Member::internalFileAttributes()

use constant IFA_TEXT_FILE_MASK => 1;
use constant IFA_TEXT_FILE      => 1;
use constant IFA_BINARY_FILE    => 0;

# PKZIP file format miscellaneous constants (for internal use only)
use constant SIGNATURE_FORMAT   => "V";
use constant SIGNATURE_LENGTH   => 4;

# these lengths are without the signature.
use constant LOCAL_FILE_HEADER_SIGNATURE   => 0x04034b50;
use constant LOCAL_FILE_HEADER_FORMAT      => "v3 V4 v2";
use constant LOCAL_FILE_HEADER_LENGTH      => 26;

# PKZIP docs don't mention the signature, but Info-Zip writes it.
use constant DATA_DESCRIPTOR_SIGNATURE     => 0x08074b50;
use constant DATA_DESCRIPTOR_FORMAT        => "V3";
use constant DATA_DESCRIPTOR_LENGTH        => 12;

# but the signature is apparently optional.
use constant DATA_DESCRIPTOR_FORMAT_NO_SIG => "V2";
use constant DATA_DESCRIPTOR_LENGTH_NO_SIG => 8;

use constant CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE  => 0x02014b50;
use constant CENTRAL_DIRECTORY_FILE_HEADER_FORMAT     => "C2 v3 V4 v5 V2";
use constant CENTRAL_DIRECTORY_FILE_HEADER_LENGTH     => 42;

use constant END_OF_CENTRAL_DIRECTORY_SIGNATURE        => 0x06054b50;
use constant END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING =>
    pack( "V", END_OF_CENTRAL_DIRECTORY_SIGNATURE );
use constant END_OF_CENTRAL_DIRECTORY_FORMAT           => "v4 V2 v";
use constant END_OF_CENTRAL_DIRECTORY_LENGTH           => 18;

use constant GPBF_IMPLODING_8K_SLIDING_DICTIONARY_MASK => 1 << 1;
use constant GPBF_IMPLODING_3_SHANNON_FANO_TREES_MASK  => 1 << 2;
use constant GPBF_IS_COMPRESSED_PATCHED_DATA_MASK      => 1 << 5;

# the rest of these are not supported in this module
use constant COMPRESSION_SHRUNK    => 1;    # file is Shrunk
use constant COMPRESSION_REDUCED_1 => 2;    # file is Reduced CF=1
use constant COMPRESSION_REDUCED_2 => 3;    # file is Reduced CF=2
use constant COMPRESSION_REDUCED_3 => 4;    # file is Reduced CF=3
use constant COMPRESSION_REDUCED_4 => 5;    # file is Reduced CF=4
use constant COMPRESSION_IMPLODED  => 6;    # file is Imploded
use constant COMPRESSION_TOKENIZED => 7;    # reserved for Tokenizing compr.
use constant COMPRESSION_DEFLATED_ENHANCED => 9;   # reserved for enh. Deflating
use constant COMPRESSION_PKWARE_DATA_COMPRESSION_LIBRARY_IMPLODED => 10;

# Load the various required classes
require Archive::Zip::Archive;
require Archive::Zip::Member;
require Archive::Zip::FileMember;
require Archive::Zip::DirectoryMember;
require Archive::Zip::ZipFileMember;
require Archive::Zip::NewFileMember;
require Archive::Zip::StringMember;

use constant ZIPARCHIVECLASS => 'Archive::Zip::Archive';
use constant ZIPMEMBERCLASS  => 'Archive::Zip::Member';

# Convenience functions

sub _ISA ($$) {
    # Can't rely on Scalar::Util, so use the next best way
    local $@;
    !! eval { ref $_[0] and $_[0]->isa($_[1]) };
}

sub _CAN ($$) {
    local $@;
    !! eval { ref $_[0] and $_[0]->can($_[1]) };
}





#####################################################################
# Methods

sub new {
    my $class = shift;
    return $class->ZIPARCHIVECLASS->new(@_);
}

sub computeCRC32 {
    my ( $data, $crc );

    if ( ref( $_[0] ) eq 'HASH' ) {
        $data = $_[0]->{string};
        $crc  = $_[0]->{checksum};
    }
    else {
        $data = shift;
        $data = shift if ref($data);
        $crc  = shift;
    }

	return Compress::Raw::Zlib::crc32( $data, $crc );
}

# Report or change chunk size used for reading and writing.
# Also sets Zlib's default buffer size (eventually).
sub setChunkSize {
    shift if ref( $_[0] ) eq 'Archive::Zip::Archive';
    my $chunkSize = ( ref( $_[0] ) eq 'HASH' ) ? shift->{chunkSize} : shift;
    my $oldChunkSize = $Archive::Zip::ChunkSize;
    $Archive::Zip::ChunkSize = $chunkSize if ($chunkSize);
    return $oldChunkSize;
}

sub chunkSize {
    return $Archive::Zip::ChunkSize;
}

sub setErrorHandler {
    my $errorHandler = ( ref( $_[0] ) eq 'HASH' ) ? shift->{subroutine} : shift;
    $errorHandler = \&Carp::carp unless defined($errorHandler);
    my $oldErrorHandler = $Archive::Zip::ErrorHandler;
    $Archive::Zip::ErrorHandler = $errorHandler;
    return $oldErrorHandler;
}





######################################################################
# Private utility functions (not methods).

sub _printError {
    my $string = join ( ' ', @_, "\n" );
    my $oldCarpLevel = $Carp::CarpLevel;
    $Carp::CarpLevel += 2;
    &{$ErrorHandler} ($string);
    $Carp::CarpLevel = $oldCarpLevel;
}

# This is called on format errors.
sub _formatError {
    shift if ref( $_[0] );
    _printError( 'format error:', @_ );
    return AZ_FORMAT_ERROR;
}

# This is called on IO errors.
sub _ioError {
    shift if ref( $_[0] );
    _printError( 'IO error:', @_, ':', $! );
    return AZ_IO_ERROR;
}

# This is called on generic errors.
sub _error {
    shift if ref( $_[0] );
    _printError( 'error:', @_ );
    return AZ_ERROR;
}

# Called when a subclass should have implemented
# something but didn't
sub _subclassResponsibility {
    Carp::croak("subclass Responsibility\n");
}

# Try to set the given file handle or object into binary mode.
sub _binmode {
    my $fh = shift;
    return _CAN( $fh, 'binmode' ) ? $fh->binmode() : binmode($fh);
}

# Attempt to guess whether file handle is seekable.
# Because of problems with Windows, this only returns true when
# the file handle is a real file.  
sub _isSeekable {
    my $fh = shift;
    return 0 unless ref $fh;
    if ( _ISA($fh, 'IO::Scalar') ) {
        # IO::Scalar objects are brokenly-seekable
        return 0;
    }
    if ( _ISA($fh, 'IO::String') ) {
        return 1;
    }
    if ( _ISA($fh, 'IO::Seekable') ) {
        # Unfortunately, some things like FileHandle objects
        # return true for Seekable, but AREN'T!!!!!
        if ( _ISA($fh, 'FileHandle') ) {
            return 0;
        } else {
            return 1;
        }
    }
    if ( _CAN($fh, 'stat') ) {
        return -f $fh;
    }
    return (
        _CAN($fh, 'seek') and _CAN($fh, 'tell')
        ) ? 1 : 0;
}

# Print to the filehandle, while making sure the pesky Perl special global 
# variables don't interfere.
sub _print
{
    my ($self, $fh, @data) = @_;

    local $\;

    return $fh->print(@data);
}

# Return an opened IO::Handle
# my ( $status, fh ) = _newFileHandle( 'fileName', 'w' );
# Can take a filename, file handle, or ref to GLOB
# Or, if given something that is a ref but not an IO::Handle,
# passes back the same thing.
sub _newFileHandle {
    my $fd     = shift;
    my $status = 1;
    my $handle;

    if ( ref($fd) ) {
        if ( _ISA($fd, 'IO::Scalar') or _ISA($fd, 'IO::String') ) {
            $handle = $fd;
        } elsif ( _ISA($fd, 'IO::Handle') or ref($fd) eq 'GLOB' ) {
            $handle = IO::File->new;
            $status = $handle->fdopen( $fd, @_ );
        } else {
            $handle = $fd;
        }
    } else {
        $handle = IO::File->new;
        $status = $handle->open( $fd, @_ );
    }

    return ( $status, $handle );
}

# Returns next signature from given file handle, leaves
# file handle positioned afterwards.
# In list context, returns ($status, $signature)
# ( $status, $signature) = _readSignature( $fh, $fileName );

sub _readSignature {
    my $fh                = shift;
    my $fileName          = shift;
    my $expectedSignature = shift;    # optional

    my $signatureData;
    my $bytesRead = $fh->read( $signatureData, SIGNATURE_LENGTH );
    if ( $bytesRead != SIGNATURE_LENGTH ) {
        return _ioError("reading header signature");
    }
    my $signature = unpack( SIGNATURE_FORMAT, $signatureData );
    my $status    = AZ_OK;

    # compare with expected signature, if any, or any known signature.
    if ( ( defined($expectedSignature) && $signature != $expectedSignature )
        || ( !defined($expectedSignature)
            && $signature != CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE
            && $signature != LOCAL_FILE_HEADER_SIGNATURE
            && $signature != END_OF_CENTRAL_DIRECTORY_SIGNATURE
            && $signature != DATA_DESCRIPTOR_SIGNATURE ) )
    {
        my $errmsg = sprintf( "bad signature: 0x%08x", $signature );
        if ( _isSeekable($fh) )
        {
            $errmsg .=
              sprintf( " at offset %d", $fh->tell() - SIGNATURE_LENGTH );
        }

        $status = _formatError("$errmsg in file $fileName");
    }

    return ( $status, $signature );
}

# Utility method to make and open a temp file.
# Will create $temp_dir if it doesn't exist.
# Returns file handle and name:
#
# my ($fh, $name) = Archive::Zip::tempFile();
# my ($fh, $name) = Archive::Zip::tempFile('mytempdir');
#

sub tempFile {
    my $dir = ( ref( $_[0] ) eq 'HASH' ) ? shift->{tempDir} : shift;
    my ( $fh, $filename ) = File::Temp::tempfile(
        SUFFIX => '.zip',
        UNLINK => 0,        # we will delete it!
        $dir ? ( DIR => $dir ) : ()
    );
    return ( undef, undef ) unless $fh;
    my ( $status, $newfh ) = _newFileHandle( $fh, 'w+' );
    return ( $newfh, $filename );
}

# Return the normalized directory name as used in a zip file (path
# separators become slashes, etc.). 
# Will translate internal slashes in path components (i.e. on Macs) to
# underscores.  Discards volume names.
# When $forceDir is set, returns paths with trailing slashes (or arrays
# with trailing blank members).
#
# If third argument is a reference, returns volume information there.
#
# input         output
# .             ('.')   '.'
# ./a           ('a')   a
# ./a/b         ('a','b')   a/b
# ./a/b/        ('a','b')   a/b
# a/b/          ('a','b')   a/b
# /a/b/         ('','a','b')    /a/b
# c:\a\b\c.doc  ('','a','b','c.doc')    /a/b/c.doc      # on Windoze
# "i/o maps:whatever"   ('i_o maps', 'whatever')  "i_o maps/whatever"   # on Macs
sub _asZipDirName    
{
    my $name      = shift;
    my $forceDir  = shift;
    my $volReturn = shift;
    my ( $volume, $directories, $file ) =
      File::Spec->splitpath( File::Spec->canonpath($name), $forceDir );
    $$volReturn = $volume if ( ref($volReturn) );
    my @dirs = map { $_ =~ s{/}{_}g; $_ } File::Spec->splitdir($directories);
    if ( @dirs > 0 ) { pop (@dirs) unless $dirs[-1] }   # remove empty component
    push ( @dirs, defined($file) ? $file : '' );
    #return wantarray ? @dirs : join ( '/', @dirs );
    return join ( '/', @dirs );
}

# Return an absolute local name for a zip name.
# Assume a directory if zip name has trailing slash.
# Takes an optional volume name in FS format (like 'a:').
#
sub _asLocalName    
{
    my $name   = shift;    # zip format
    my $volume = shift;
    $volume = '' unless defined($volume);    # local FS format

    my @paths = split ( /\//, $name );
    my $filename = pop (@paths);
    $filename = '' unless defined($filename);
    my $localDirs = @paths ? File::Spec->catdir(@paths) : '';
    my $localName = File::Spec->catpath( $volume, $localDirs, $filename );
    unless ( $volume ) {
        $localName = File::Spec->rel2abs( $localName, Cwd::getcwd() );
    }
    return $localName;
}

1;

__END__

#line 2060
FILE   3fb75f46/Archive/Zip/Archive.pm  s#line 1 "/home/danny/perl5/lib/perl5/Archive/Zip/Archive.pm"
package Archive::Zip::Archive;

# Represents a generic ZIP archive

use strict;
use File::Path;
use File::Find ();
use File::Spec ();
use File::Copy ();
use File::Basename;
use Cwd;

use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw( Archive::Zip );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
  :PKZIP_CONSTANTS
  :UTILITY_METHODS
);

# Note that this returns undef on read errors, else new zip object.

sub new {
    my $class = shift;
    my $self  = bless(
        {
            'diskNumber'                            => 0,
            'diskNumberWithStartOfCentralDirectory' => 0,
            'numberOfCentralDirectoriesOnThisDisk'  => 0, # shld be # of members
            'numberOfCentralDirectories'            => 0, # shld be # of members
            'centralDirectorySize' => 0,    # must re-compute on write
            'centralDirectoryOffsetWRTStartingDiskNumber' =>
              0,                            # must re-compute
            'writeEOCDOffset'             => 0,
            'writeCentralDirectoryOffset' => 0,
            'zipfileComment'              => '',
            'eocdOffset'                  => 0,
            'fileName'                    => ''
        },
        $class
    );
    $self->{'members'} = [];
    my $fileName = ( ref( $_[0] ) eq 'HASH' ) ? shift->{filename} : shift;
    if ($fileName) {
        my $status = $self->read($fileName);
        return $status == AZ_OK ? $self : undef;
    }
    return $self;
}

sub storeSymbolicLink {
    my $self = shift;
    $self->{'storeSymbolicLink'} = shift;
}

sub members {
    @{ shift->{'members'} };
}

sub numberOfMembers {
    scalar( shift->members() );
}

sub memberNames {
    my $self = shift;
    return map { $_->fileName() } $self->members();
}

# return ref to member with given name or undef
sub memberNamed {
    my $self     = shift;
    my $fileName = ( ref( $_[0] ) eq 'HASH' ) ? shift->{zipName} : shift;
    foreach my $member ( $self->members() ) {
        return $member if $member->fileName() eq $fileName;
    }
    return undef;
}

sub membersMatching {
    my $self    = shift;
    my $pattern = ( ref( $_[0] ) eq 'HASH' ) ? shift->{regex} : shift;
    return grep { $_->fileName() =~ /$pattern/ } $self->members();
}

sub diskNumber {
    shift->{'diskNumber'};
}

sub diskNumberWithStartOfCentralDirectory {
    shift->{'diskNumberWithStartOfCentralDirectory'};
}

sub numberOfCentralDirectoriesOnThisDisk {
    shift->{'numberOfCentralDirectoriesOnThisDisk'};
}

sub numberOfCentralDirectories {
    shift->{'numberOfCentralDirectories'};
}

sub centralDirectorySize {
    shift->{'centralDirectorySize'};
}

sub centralDirectoryOffsetWRTStartingDiskNumber {
    shift->{'centralDirectoryOffsetWRTStartingDiskNumber'};
}

sub zipfileComment {
    my $self    = shift;
    my $comment = $self->{'zipfileComment'};
    if (@_) {
        my $new_comment = ( ref( $_[0] ) eq 'HASH' ) ? shift->{comment} : shift;
        $self->{'zipfileComment'} = pack( 'C0a*', $new_comment );    # avoid unicode
    }
    return $comment;
}

sub eocdOffset {
    shift->{'eocdOffset'};
}

# Return the name of the file last read.
sub fileName {
    shift->{'fileName'};
}

sub removeMember {
    my $self    = shift;
    my $member  = ( ref( $_[0] ) eq 'HASH' ) ? shift->{memberOrZipName} : shift;
    $member = $self->memberNamed($member) unless ref($member);
    return undef unless $member;
    my @newMembers = grep { $_ != $member } $self->members();
    $self->{'members'} = \@newMembers;
    return $member;
}

sub replaceMember {
    my $self = shift;

    my ( $oldMember, $newMember );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $oldMember = $_[0]->{memberOrZipName};
        $newMember = $_[0]->{newMember};
    }
    else {
        ( $oldMember, $newMember ) = @_;
    }

    $oldMember = $self->memberNamed($oldMember) unless ref($oldMember);
    return undef unless $oldMember;
    return undef unless $newMember;
    my @newMembers =
      map { ( $_ == $oldMember ) ? $newMember : $_ } $self->members();
    $self->{'members'} = \@newMembers;
    return $oldMember;
}

sub extractMember {
    my $self = shift;

    my ( $member, $name );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $member = $_[0]->{memberOrZipName};
        $name   = $_[0]->{name};
    }
    else {
        ( $member, $name ) = @_;
    }

    $member = $self->memberNamed($member) unless ref($member);
    return _error('member not found') unless $member;
    my $originalSize = $member->compressedSize();
    my ( $volumeName, $dirName, $fileName );
    if ( defined($name) ) {
        ( $volumeName, $dirName, $fileName ) = File::Spec->splitpath($name);
        $dirName = File::Spec->catpath( $volumeName, $dirName, '' );
    }
    else {
        $name = $member->fileName();
        ( $dirName = $name ) =~ s{[^/]*$}{};
        $dirName = Archive::Zip::_asLocalName($dirName);
        $name    = Archive::Zip::_asLocalName($name);
    }
    if ( $dirName && !-d $dirName ) {
        mkpath($dirName);
        return _ioError("can't create dir $dirName") if ( !-d $dirName );
    }
    my $rc = $member->extractToFileNamed( $name, @_ );

    # TODO refactor this fix into extractToFileNamed()
    $member->{'compressedSize'} = $originalSize;
    return $rc;
}

sub extractMemberWithoutPaths {
    my $self = shift;

    my ( $member, $name );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $member = $_[0]->{memberOrZipName};
        $name   = $_[0]->{name};
    }
    else {
        ( $member, $name ) = @_;
    }

    $member = $self->memberNamed($member) unless ref($member);
    return _error('member not found') unless $member;
    my $originalSize = $member->compressedSize();
    return AZ_OK if $member->isDirectory();
    unless ($name) {
        $name = $member->fileName();
        $name =~ s{.*/}{};    # strip off directories, if any
        $name = Archive::Zip::_asLocalName($name);
    }
    my $rc = $member->extractToFileNamed( $name, @_ );
    $member->{'compressedSize'} = $originalSize;
    return $rc;
}

sub addMember {
    my $self       = shift;
    my $newMember  = ( ref( $_[0] ) eq 'HASH' ) ? shift->{member} : shift;
    push( @{ $self->{'members'} }, $newMember ) if $newMember;
    return $newMember;
}

sub addFile {
    my $self = shift;

    my ( $fileName, $newName, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fileName         = $_[0]->{filename};
        $newName          = $_[0]->{zipName};
        $compressionLevel = $_[0]->{compressionLevel};
    }
    else {
        ( $fileName, $newName, $compressionLevel ) = @_;
    }

    my $newMember = $self->ZIPMEMBERCLASS->newFromFile( $fileName, $newName );
    $newMember->desiredCompressionLevel($compressionLevel);
    if ( $self->{'storeSymbolicLink'} && -l $fileName ) {
        my $newMember = $self->ZIPMEMBERCLASS->newFromString(readlink $fileName, $newName);
        # For symbolic links, External File Attribute is set to 0xA1FF0000 by Info-ZIP
        $newMember->{'externalFileAttributes'} = 0xA1FF0000;
        $self->addMember($newMember);
    } else {
        $self->addMember($newMember);
    }
    return $newMember;
}

sub addString {
    my $self = shift;

    my ( $stringOrStringRef, $name, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $stringOrStringRef = $_[0]->{string};
        $name              = $_[0]->{zipName};
        $compressionLevel  = $_[0]->{compressionLevel};
    }
    else {
        ( $stringOrStringRef, $name, $compressionLevel ) = @_;;
    }

    my $newMember = $self->ZIPMEMBERCLASS->newFromString(
        $stringOrStringRef, $name
    );
    $newMember->desiredCompressionLevel($compressionLevel);
    return $self->addMember($newMember);
}

sub addDirectory {
    my $self = shift;

    my ( $name, $newName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $name    = $_[0]->{directoryName};
        $newName = $_[0]->{zipName};
    }
    else {
        ( $name, $newName ) = @_;
    }

    my $newMember = $self->ZIPMEMBERCLASS->newDirectoryNamed( $name, $newName );
    if ( $self->{'storeSymbolicLink'} && -l $name ) {
        my $link = readlink $name;
        ( $newName =~ s{/$}{} ) if $newName; # Strip trailing /
        my $newMember = $self->ZIPMEMBERCLASS->newFromString($link, $newName);
        # For symbolic links, External File Attribute is set to 0xA1FF0000 by Info-ZIP
        $newMember->{'externalFileAttributes'} = 0xA1FF0000;
        $self->addMember($newMember);
    } else {
        $self->addMember($newMember);
    }
    return $newMember;
}

# add either a file or a directory.

sub addFileOrDirectory {
    my $self = shift;

    my ( $name, $newName, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $name             = $_[0]->{name};
        $newName          = $_[0]->{zipName};
        $compressionLevel = $_[0]->{compressionLevel};
    }
    else {
        ( $name, $newName, $compressionLevel ) = @_;
    }

    $name =~ s{/$}{};
    if ( $newName ) {
        $newName =~ s{/$}{};
    } else {
        $newName = $name;
    }
    if ( -f $name ) {
        return $self->addFile( $name, $newName, $compressionLevel );
    }
    elsif ( -d $name ) {
        return $self->addDirectory( $name, $newName );
    }
    else {
        return _error("$name is neither a file nor a directory");
    }
}

sub contents {
    my $self = shift;

    my ( $member, $newContents );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $member      = $_[0]->{memberOrZipName};
        $newContents = $_[0]->{contents};
    }
    else {
        ( $member, $newContents ) = @_;
    }

    return _error('No member name given') unless $member;
    $member = $self->memberNamed($member) unless ref($member);
    return undef unless $member;
    return $member->contents($newContents);
}

sub writeToFileNamed {
    my $self = shift;
    my $fileName =
      ( ref( $_[0] ) eq 'HASH' ) ? shift->{filename} : shift;  # local FS format
    foreach my $member ( $self->members() ) {
        if ( $member->_usesFileNamed($fileName) ) {
            return _error( "$fileName is needed by member "
                  . $member->fileName()
                  . "; consider using overwrite() or overwriteAs() instead." );
        }
    }
    my ( $status, $fh ) = _newFileHandle( $fileName, 'w' );
    return _ioError("Can't open $fileName for write") unless $status;
    my $retval = $self->writeToFileHandle( $fh, 1 );
    $fh->close();
    $fh = undef;

    return $retval;
}

# It is possible to write data to the FH before calling this,
# perhaps to make a self-extracting archive.
sub writeToFileHandle {
    my $self = shift;

    my ( $fh, $fhIsSeekable );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fh           = $_[0]->{fileHandle};
        $fhIsSeekable =
          exists( $_[0]->{seek} ) ? $_[0]->{seek} : _isSeekable($fh);
    }
    else {
        $fh           = shift;
        $fhIsSeekable = @_ ? shift : _isSeekable($fh);
    }

    return _error('No filehandle given')   unless $fh;
    return _ioError('filehandle not open') unless $fh->opened();
    _binmode($fh);

    # Find out where the current position is.
    my $offset = $fhIsSeekable ? $fh->tell() : 0;
    $offset    = 0 if $offset < 0;

    foreach my $member ( $self->members() ) {
        my $retval = $member->_writeToFileHandle( $fh, $fhIsSeekable, $offset );
        $member->endRead();
        return $retval if $retval != AZ_OK;
        $offset += $member->_localHeaderSize() + $member->_writeOffset();
        $offset +=
          $member->hasDataDescriptor()
          ? DATA_DESCRIPTOR_LENGTH + SIGNATURE_LENGTH
          : 0;

        # changed this so it reflects the last successful position
        $self->{'writeCentralDirectoryOffset'} = $offset;
    }
    return $self->writeCentralDirectory($fh);
}

# Write zip back to the original file,
# as safely as possible.
# Returns AZ_OK if successful.
sub overwrite {
    my $self = shift;
    return $self->overwriteAs( $self->{'fileName'} );
}

# Write zip to the specified file,
# as safely as possible.
# Returns AZ_OK if successful.
sub overwriteAs {
    my $self    = shift;
    my $zipName = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{filename} : shift;
    return _error("no filename in overwriteAs()") unless defined($zipName);

    my ( $fh, $tempName ) = Archive::Zip::tempFile();
    return _error( "Can't open temp file", $! ) unless $fh;

    ( my $backupName = $zipName ) =~ s{(\.[^.]*)?$}{.zbk};

    my $status = $self->writeToFileHandle($fh);
    $fh->close();
    $fh = undef;

    if ( $status != AZ_OK ) {
        unlink($tempName);
        _printError("Can't write to $tempName");
        return $status;
    }

    my $err;

    # rename the zip
    if ( -f $zipName && !rename( $zipName, $backupName ) ) {
        $err = $!;
        unlink($tempName);
        return _error( "Can't rename $zipName as $backupName", $err );
    }

    # move the temp to the original name (possibly copying)
    unless ( File::Copy::move( $tempName, $zipName ) ) {
        $err = $!;
        rename( $backupName, $zipName );
        unlink($tempName);
        return _error( "Can't move $tempName to $zipName", $err );
    }

    # unlink the backup
    if ( -f $backupName && !unlink($backupName) ) {
        $err = $!;
        return _error( "Can't unlink $backupName", $err );
    }

    return AZ_OK;
}

# Used only during writing
sub _writeCentralDirectoryOffset {
    shift->{'writeCentralDirectoryOffset'};
}

sub _writeEOCDOffset {
    shift->{'writeEOCDOffset'};
}

# Expects to have _writeEOCDOffset() set
sub _writeEndOfCentralDirectory {
    my ( $self, $fh ) = @_;

    $self->_print($fh, END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING)
      or return _ioError('writing EOCD Signature');
    my $zipfileCommentLength = length( $self->zipfileComment() );

    my $header = pack(
        END_OF_CENTRAL_DIRECTORY_FORMAT,
        0,                          # {'diskNumber'},
        0,                          # {'diskNumberWithStartOfCentralDirectory'},
        $self->numberOfMembers(),   # {'numberOfCentralDirectoriesOnThisDisk'},
        $self->numberOfMembers(),   # {'numberOfCentralDirectories'},
        $self->_writeEOCDOffset() - $self->_writeCentralDirectoryOffset(),
        $self->_writeCentralDirectoryOffset(),
        $zipfileCommentLength
    );
    $self->_print($fh, $header)
      or return _ioError('writing EOCD header');
    if ($zipfileCommentLength) {
        $self->_print($fh,  $self->zipfileComment() )
          or return _ioError('writing zipfile comment');
    }
    return AZ_OK;
}

# $offset can be specified to truncate a zip file.
sub writeCentralDirectory {
    my $self = shift;

    my ( $fh, $offset );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fh     = $_[0]->{fileHandle};
        $offset = $_[0]->{offset};
    }
    else {
        ( $fh, $offset ) = @_;
    }

    if ( defined($offset) ) {
        $self->{'writeCentralDirectoryOffset'} = $offset;
        $fh->seek( $offset, IO::Seekable::SEEK_SET )
          or return _ioError('seeking to write central directory');
    }
    else {
        $offset = $self->_writeCentralDirectoryOffset();
    }

    foreach my $member ( $self->members() ) {
        my $status = $member->_writeCentralDirectoryFileHeader($fh);
        return $status if $status != AZ_OK;
        $offset += $member->_centralDirectoryHeaderSize();
        $self->{'writeEOCDOffset'} = $offset;
    }
    return $self->_writeEndOfCentralDirectory($fh);
}

sub read {
    my $self     = shift;
    my $fileName = ( ref( $_[0] ) eq 'HASH' ) ? shift->{filename} : shift;
    return _error('No filename given') unless $fileName;
    my ( $status, $fh ) = _newFileHandle( $fileName, 'r' );
    return _ioError("opening $fileName for read") unless $status;

    $status = $self->readFromFileHandle( $fh, $fileName );
    return $status if $status != AZ_OK;

    $fh->close();
    $self->{'fileName'} = $fileName;
    return AZ_OK;
}

sub readFromFileHandle {
    my $self = shift;

    my ( $fh, $fileName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fh       = $_[0]->{fileHandle};
        $fileName = $_[0]->{filename};
    }
    else {
        ( $fh, $fileName ) = @_;
    }

    $fileName = $fh unless defined($fileName);
    return _error('No filehandle given')   unless $fh;
    return _ioError('filehandle not open') unless $fh->opened();

    _binmode($fh);
    $self->{'fileName'} = "$fh";

    # TODO: how to support non-seekable zips?
    return _error('file not seekable')
      unless _isSeekable($fh);

    $fh->seek( 0, 0 );    # rewind the file

    my $status = $self->_findEndOfCentralDirectory($fh);
    return $status if $status != AZ_OK;

    my $eocdPosition = $fh->tell();

    $status = $self->_readEndOfCentralDirectory($fh);
    return $status if $status != AZ_OK;

    $fh->seek( $eocdPosition - $self->centralDirectorySize(),
        IO::Seekable::SEEK_SET )
      or return _ioError("Can't seek $fileName");

    # Try to detect garbage at beginning of archives
    # This should be 0
    $self->{'eocdOffset'} = $eocdPosition - $self->centralDirectorySize() # here
      - $self->centralDirectoryOffsetWRTStartingDiskNumber();

    for ( ; ; ) {
        my $newMember =
          $self->ZIPMEMBERCLASS->_newFromZipFile( $fh, $fileName,
            $self->eocdOffset() );
        my $signature;
        ( $status, $signature ) = _readSignature( $fh, $fileName );
        return $status if $status != AZ_OK;
        last           if $signature == END_OF_CENTRAL_DIRECTORY_SIGNATURE;
        $status = $newMember->_readCentralDirectoryFileHeader();
        return $status if $status != AZ_OK;
        $status = $newMember->endRead();
        return $status if $status != AZ_OK;
        $newMember->_becomeDirectoryIfNecessary();
        push( @{ $self->{'members'} }, $newMember );
    }

    return AZ_OK;
}

# Read EOCD, starting from position before signature.
# Return AZ_OK on success.
sub _readEndOfCentralDirectory {
    my $self = shift;
    my $fh   = shift;

    # Skip past signature
    $fh->seek( SIGNATURE_LENGTH, IO::Seekable::SEEK_CUR )
      or return _ioError("Can't seek past EOCD signature");

    my $header = '';
    my $bytesRead = $fh->read( $header, END_OF_CENTRAL_DIRECTORY_LENGTH );
    if ( $bytesRead != END_OF_CENTRAL_DIRECTORY_LENGTH ) {
        return _ioError("reading end of central directory");
    }

    my $zipfileCommentLength;
    (
        $self->{'diskNumber'},
        $self->{'diskNumberWithStartOfCentralDirectory'},
        $self->{'numberOfCentralDirectoriesOnThisDisk'},
        $self->{'numberOfCentralDirectories'},
        $self->{'centralDirectorySize'},
        $self->{'centralDirectoryOffsetWRTStartingDiskNumber'},
        $zipfileCommentLength
    ) = unpack( END_OF_CENTRAL_DIRECTORY_FORMAT, $header );

    if ($zipfileCommentLength) {
        my $zipfileComment = '';
        $bytesRead = $fh->read( $zipfileComment, $zipfileCommentLength );
        if ( $bytesRead != $zipfileCommentLength ) {
            return _ioError("reading zipfile comment");
        }
        $self->{'zipfileComment'} = $zipfileComment;
    }

    return AZ_OK;
}

# Seek in my file to the end, then read backwards until we find the
# signature of the central directory record. Leave the file positioned right
# before the signature. Returns AZ_OK if success.
sub _findEndOfCentralDirectory {
    my $self = shift;
    my $fh   = shift;
    my $data = '';
    $fh->seek( 0, IO::Seekable::SEEK_END )
      or return _ioError("seeking to end");

    my $fileLength = $fh->tell();
    if ( $fileLength < END_OF_CENTRAL_DIRECTORY_LENGTH + 4 ) {
        return _formatError("file is too short");
    }

    my $seekOffset = 0;
    my $pos        = -1;
    for ( ; ; ) {
        $seekOffset += 512;
        $seekOffset = $fileLength if ( $seekOffset > $fileLength );
        $fh->seek( -$seekOffset, IO::Seekable::SEEK_END )
          or return _ioError("seek failed");
        my $bytesRead = $fh->read( $data, $seekOffset );
        if ( $bytesRead != $seekOffset ) {
            return _ioError("read failed");
        }
        $pos = rindex( $data, END_OF_CENTRAL_DIRECTORY_SIGNATURE_STRING );
        last
          if ( $pos >= 0
            or $seekOffset == $fileLength
            or $seekOffset >= $Archive::Zip::ChunkSize );
    }

    if ( $pos >= 0 ) {
        $fh->seek( $pos - $seekOffset, IO::Seekable::SEEK_CUR )
          or return _ioError("seeking to EOCD");
        return AZ_OK;
    }
    else {
        return _formatError("can't find EOCD signature");
    }
}

# Used to avoid taint problems when chdir'ing.
# Not intended to increase security in any way; just intended to shut up the -T
# complaints.  If your Cwd module is giving you unreliable returns from cwd()
# you have bigger problems than this.
sub _untaintDir {
    my $dir = shift;
    $dir =~ m/\A(.+)\z/s;
    return $1;
}

sub addTree {
    my $self = shift;

    my ( $root, $dest, $pred, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{zipName};
        $pred             = $_[0]->{select};
        $compressionLevel = $_[0]->{compressionLevel};
    }
    else {
        ( $root, $dest, $pred, $compressionLevel ) = @_;
    }

    return _error("root arg missing in call to addTree()")
      unless defined($root);
    $dest = '' unless defined($dest);
    $pred = sub { -r } unless defined($pred);

    my @files;
    my $startDir = _untaintDir( cwd() );

    return _error( 'undef returned by _untaintDir on cwd ', cwd() )
      unless $startDir;

    # This avoids chdir'ing in Find, in a way compatible with older
    # versions of File::Find.
    my $wanted = sub {
        local $main::_ = $File::Find::name;
        my $dir = _untaintDir($File::Find::dir);
        chdir($startDir);
        push( @files, $File::Find::name ) if (&$pred);
        chdir($dir);
    };

    File::Find::find( $wanted, $root );

    my $rootZipName = _asZipDirName( $root, 1 );    # with trailing slash
    my $pattern = $rootZipName eq './' ? '^' : "^\Q$rootZipName\E";

    $dest = _asZipDirName( $dest, 1 );              # with trailing slash

    foreach my $fileName (@files) {
        my $isDir = -d $fileName;

        # normalize, remove leading ./
        my $archiveName = _asZipDirName( $fileName, $isDir );
        if ( $archiveName eq $rootZipName ) { $archiveName = $dest }
        else { $archiveName =~ s{$pattern}{$dest} }
        next if $archiveName =~ m{^\.?/?$};         # skip current dir
        my $member = $isDir
          ? $self->addDirectory( $fileName, $archiveName )
          : $self->addFile( $fileName, $archiveName );
        $member->desiredCompressionLevel($compressionLevel);

        return _error("add $fileName failed in addTree()") if !$member;
    }
    return AZ_OK;
}

sub addTreeMatching {
    my $self = shift;

    my ( $root, $dest, $pattern, $pred, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{zipName};
        $pattern          = $_[0]->{pattern};
        $pred             = $_[0]->{select};
        $compressionLevel = $_[0]->{compressionLevel};
    }
    else {
        ( $root, $dest, $pattern, $pred, $compressionLevel ) = @_;
    }

    return _error("root arg missing in call to addTreeMatching()")
      unless defined($root);
    $dest = '' unless defined($dest);
    return _error("pattern missing in call to addTreeMatching()")
      unless defined($pattern);
    my $matcher =
      $pred ? sub { m{$pattern} && &$pred } : sub { m{$pattern} && -r };
    return $self->addTree( $root, $dest, $matcher, $compressionLevel );
}

# $zip->extractTree( $root, $dest [, $volume] );
#
# $root and $dest are Unix-style.
# $volume is in local FS format.
#
sub extractTree {
    my $self = shift;

    my ( $root, $dest, $volume );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $root   = $_[0]->{root};
        $dest   = $_[0]->{zipName};
        $volume = $_[0]->{volume};
    }
    else {
        ( $root, $dest, $volume ) = @_;
    }

    $root = '' unless defined($root);
    $dest = './' unless defined($dest);
    my $pattern = "^\Q$root";
    my @members = $self->membersMatching($pattern);

    foreach my $member (@members) {
        my $fileName = $member->fileName();           # in Unix format
        $fileName =~ s{$pattern}{$dest};    # in Unix format
                                            # convert to platform format:
        $fileName = Archive::Zip::_asLocalName( $fileName, $volume );
        my $status = $member->extractToFileNamed($fileName);
        return $status if $status != AZ_OK;
    }
    return AZ_OK;
}

# $zip->updateMember( $memberOrName, $fileName );
# Returns (possibly updated) member, if any; undef on errors.

sub updateMember {
    my $self = shift;

    my ( $oldMember, $fileName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $oldMember = $_[0]->{memberOrZipName};
        $fileName  = $_[0]->{name};
    }
    else {
        ( $oldMember, $fileName ) = @_;
    }

    if ( !defined($fileName) ) {
        _error("updateMember(): missing fileName argument");
        return undef;
    }

    my @newStat = stat($fileName);
    if ( !@newStat ) {
        _ioError("Can't stat $fileName");
        return undef;
    }

    my $isDir = -d _;

    my $memberName;

    if ( ref($oldMember) ) {
        $memberName = $oldMember->fileName();
    }
    else {
        $oldMember = $self->memberNamed( $memberName = $oldMember )
          || $self->memberNamed( $memberName =
              _asZipDirName( $oldMember, $isDir ) );
    }

    unless ( defined($oldMember)
        && $oldMember->lastModTime() == $newStat[9]
        && $oldMember->isDirectory() == $isDir
        && ( $isDir || ( $oldMember->uncompressedSize() == $newStat[7] ) ) )
    {

        # create the new member
        my $newMember = $isDir
          ? $self->ZIPMEMBERCLASS->newDirectoryNamed( $fileName, $memberName )
          : $self->ZIPMEMBERCLASS->newFromFile( $fileName, $memberName );

        unless ( defined($newMember) ) {
            _error("creation of member $fileName failed in updateMember()");
            return undef;
        }

        # replace old member or append new one
        if ( defined($oldMember) ) {
            $self->replaceMember( $oldMember, $newMember );
        }
        else { $self->addMember($newMember); }

        return $newMember;
    }

    return $oldMember;
}

# $zip->updateTree( $root, [ $dest, [ $pred [, $mirror]]] );
#
# This takes the same arguments as addTree, but first checks to see
# whether the file or directory already exists in the zip file.
#
# If the fourth argument $mirror is true, then delete all my members
# if corresponding files weren't found.

sub updateTree {
    my $self = shift;

    my ( $root, $dest, $pred, $mirror, $compressionLevel );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $root             = $_[0]->{root};
        $dest             = $_[0]->{zipName};
        $pred             = $_[0]->{select};
        $mirror           = $_[0]->{mirror};
        $compressionLevel = $_[0]->{compressionLevel};
    }
    else {
        ( $root, $dest, $pred, $mirror, $compressionLevel ) = @_;
    }

    return _error("root arg missing in call to updateTree()")
      unless defined($root);
    $dest = '' unless defined($dest);
    $pred = sub { -r } unless defined($pred);

    $dest = _asZipDirName( $dest, 1 );
    my $rootZipName = _asZipDirName( $root, 1 );    # with trailing slash
    my $pattern = $rootZipName eq './' ? '^' : "^\Q$rootZipName\E";

    my @files;
    my $startDir = _untaintDir( cwd() );

    return _error( 'undef returned by _untaintDir on cwd ', cwd() )
      unless $startDir;

    # This avoids chdir'ing in Find, in a way compatible with older
    # versions of File::Find.
    my $wanted = sub {
        local $main::_ = $File::Find::name;
        my $dir = _untaintDir($File::Find::dir);
        chdir($startDir);
        push( @files, $File::Find::name ) if (&$pred);
        chdir($dir);
    };

    File::Find::find( $wanted, $root );

    # Now @files has all the files that I could potentially be adding to
    # the zip. Only add the ones that are necessary.
    # For each file (updated or not), add its member name to @done.
    my %done;
    foreach my $fileName (@files) {
        my @newStat = stat($fileName);
        my $isDir   = -d _;

        # normalize, remove leading ./
        my $memberName = _asZipDirName( $fileName, $isDir );
        if ( $memberName eq $rootZipName ) { $memberName = $dest }
        else { $memberName =~ s{$pattern}{$dest} }
        next if $memberName =~ m{^\.?/?$};    # skip current dir

        $done{$memberName} = 1;
        my $changedMember = $self->updateMember( $memberName, $fileName );
        $changedMember->desiredCompressionLevel($compressionLevel);
        return _error("updateTree failed to update $fileName")
          unless ref($changedMember);
    }

    # @done now has the archive names corresponding to all the found files.
    # If we're mirroring, delete all those members that aren't in @done.
    if ($mirror) {
        foreach my $member ( $self->members() ) {
            $self->removeMember($member)
              unless $done{ $member->fileName() };
        }
    }

    return AZ_OK;
}

1;
FILE   'd6602cbd/Archive/Zip/DirectoryMember.pm  #line 1 "/home/danny/perl5/lib/perl5/Archive/Zip/DirectoryMember.pm"
package Archive::Zip::DirectoryMember;

use strict;
use File::Path;

use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw( Archive::Zip::Member );
}

use Archive::Zip qw(
  :ERROR_CODES
  :UTILITY_METHODS
);

sub _newNamed {
    my $class    = shift;
    my $fileName = shift;    # FS name
    my $newName  = shift;    # Zip name
    $newName = _asZipDirName($fileName) unless $newName;
    my $self = $class->new(@_);
    $self->{'externalFileName'} = $fileName;
    $self->fileName($newName);

    if ( -e $fileName ) {

        # -e does NOT do a full stat, so we need to do one now
        if ( -d _ ) {
            my @stat = stat(_);
            $self->unixFileAttributes( $stat[2] );
            my $mod_t = $stat[9];
            if ( $^O eq 'MSWin32' and !$mod_t ) {
                $mod_t = time();
            }
            $self->setLastModFileDateTimeFromUnix($mod_t);

        } else {    # hmm.. trying to add a non-directory?
            _error( $fileName, ' exists but is not a directory' );
            return undef;
        }
    } else {
        $self->unixFileAttributes( $self->DEFAULT_DIRECTORY_PERMISSIONS );
        $self->setLastModFileDateTimeFromUnix( time() );
    }
    return $self;
}

sub externalFileName {
    shift->{'externalFileName'};
}

sub isDirectory {
    return 1;
}

sub extractToFileNamed {
    my $self    = shift;
    my $name    = shift;                                 # local FS name
    my $attribs = $self->unixFileAttributes() & 07777;
    mkpath( $name, 0, $attribs );                        # croaks on error
    utime( $self->lastModTime(), $self->lastModTime(), $name );
    return AZ_OK;
}

sub fileName {
    my $self    = shift;
    my $newName = shift;
    $newName =~ s{/?$}{/} if defined($newName);
    return $self->SUPER::fileName($newName);
}

# So people don't get too confused. This way it looks like the problem
# is in their code...
sub contents {
    return wantarray ? ( undef, AZ_OK ) : undef;
}

1;
FILE   "27acfff0/Archive/Zip/FileMember.pm  �#line 1 "/home/danny/perl5/lib/perl5/Archive/Zip/FileMember.pm"
package Archive::Zip::FileMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw ( Archive::Zip::Member );
}

use Archive::Zip qw(
  :UTILITY_METHODS
);

sub externalFileName {
    shift->{'externalFileName'};
}

# Return true if I depend on the named file
sub _usesFileNamed {
    my $self     = shift;
    my $fileName = shift;
    my $xfn      = $self->externalFileName();
    return undef if ref($xfn);
    return $xfn eq $fileName;
}

sub fh {
    my $self = shift;
    $self->_openFile()
      if !defined( $self->{'fh'} ) || !$self->{'fh'}->opened();
    return $self->{'fh'};
}

# opens my file handle from my file name
sub _openFile {
    my $self = shift;
    my ( $status, $fh ) = _newFileHandle( $self->externalFileName(), 'r' );
    if ( !$status ) {
        _ioError( "Can't open", $self->externalFileName() );
        return undef;
    }
    $self->{'fh'} = $fh;
    _binmode($fh);
    return $fh;
}

# Make sure I close my file handle
sub endRead {
    my $self = shift;
    undef $self->{'fh'};    # _closeFile();
    return $self->SUPER::endRead(@_);
}

sub _become {
    my $self     = shift;
    my $newClass = shift;
    return $self if ref($self) eq $newClass;
    delete( $self->{'externalFileName'} );
    delete( $self->{'fh'} );
    return $self->SUPER::_become($newClass);
}

1;
FILE   b9860f95/Archive/Zip/Member.pm  N#line 1 "/home/danny/perl5/lib/perl5/Archive/Zip/Member.pm"
package Archive::Zip::Member;

# A generic membet of an archive

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw( Archive::Zip );
}

use Archive::Zip qw(
  :CONSTANTS
  :MISC_CONSTANTS
  :ERROR_CODES
  :PKZIP_CONSTANTS
  :UTILITY_METHODS
);

use Time::Local ();
use Compress::Raw::Zlib qw( Z_OK Z_STREAM_END MAX_WBITS );
use File::Path;
use File::Basename;

use constant ZIPFILEMEMBERCLASS   => 'Archive::Zip::ZipFileMember';
use constant NEWFILEMEMBERCLASS   => 'Archive::Zip::NewFileMember';
use constant STRINGMEMBERCLASS    => 'Archive::Zip::StringMember';
use constant DIRECTORYMEMBERCLASS => 'Archive::Zip::DirectoryMember';

# Unix perms for default creation of files/dirs.
use constant DEFAULT_DIRECTORY_PERMISSIONS => 040755;
use constant DEFAULT_FILE_PERMISSIONS      => 0100666;
use constant DIRECTORY_ATTRIB              => 040000;
use constant FILE_ATTRIB                   => 0100000;

# Returns self if successful, else undef
# Assumes that fh is positioned at beginning of central directory file header.
# Leaves fh positioned immediately after file header or EOCD signature.
sub _newFromZipFile {
    my $class = shift;
    my $self  = $class->ZIPFILEMEMBERCLASS->_newFromZipFile(@_);
    return $self;
}

sub newFromString {
    my $class = shift;

    my ( $stringOrStringRef, $fileName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $stringOrStringRef = $_[0]->{string};
        $fileName          = $_[0]->{zipName};
    }
    else {
        ( $stringOrStringRef, $fileName ) = @_;
    }

    my $self  = $class->STRINGMEMBERCLASS->_newFromString( $stringOrStringRef,
        $fileName );
    return $self;
}

sub newFromFile {
    my $class = shift;

    my ( $fileName, $zipName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $fileName = $_[0]->{fileName};
        $zipName  = $_[0]->{zipName};
    }
    else {
        ( $fileName, $zipName ) = @_;
    }

    my $self = $class->NEWFILEMEMBERCLASS->_newFromFileNamed( $fileName,
      $zipName );
    return $self;
}

sub newDirectoryNamed {
    my $class = shift;

    my ( $directoryName, $newName );
    if ( ref( $_[0] ) eq 'HASH' ) {
        $directoryName = $_[0]->{directoryName};
        $newName       = $_[0]->{zipName};
    }
    else {
        ( $directoryName, $newName ) = @_;
    }

    my $self  = $class->DIRECTORYMEMBERCLASS->_newNamed( $directoryName,
        $newName );
    return $self;
}

sub new {
    my $class = shift;
    my $self  = {
        'lastModFileDateTime'      => 0,
        'fileAttributeFormat'      => FA_UNIX,
        'versionMadeBy'            => 20,
        'versionNeededToExtract'   => 20,
        'bitFlag'                  => 0,
        'compressionMethod'        => COMPRESSION_STORED,
        'desiredCompressionMethod' => COMPRESSION_STORED,
        'desiredCompressionLevel'  => COMPRESSION_LEVEL_NONE,
        'internalFileAttributes'   => 0,
        'externalFileAttributes'   => 0,                        # set later
        'fileName'                 => '',
        'cdExtraField'             => '',
        'localExtraField'          => '',
        'fileComment'              => '',
        'crc32'                    => 0,
        'compressedSize'           => 0,
        'uncompressedSize'         => 0,
        'isSymbolicLink'           => 0,
        @_
    };
    bless( $self, $class );
    $self->unixFileAttributes( $self->DEFAULT_FILE_PERMISSIONS );
    return $self;
}

sub _becomeDirectoryIfNecessary {
    my $self = shift;
    $self->_become(DIRECTORYMEMBERCLASS)
      if $self->isDirectory();
    return $self;
}

# Morph into given class (do whatever cleanup I need to do)
sub _become {
    return bless( $_[0], $_[1] );
}

sub versionMadeBy {
    shift->{'versionMadeBy'};
}

sub fileAttributeFormat {
    my $self = shift;

    if (@_) {
        $self->{fileAttributeFormat} = ( ref( $_[0] ) eq 'HASH' )
        ? $_[0]->{format} : $_[0];
    }
    else {
        return $self->{fileAttributeFormat};
    }
}

sub versionNeededToExtract {
    shift->{'versionNeededToExtract'};
}

sub bitFlag {
    my $self = shift;

    # Set General Purpose Bit Flags according to the desiredCompressionLevel setting
    if ( $self->desiredCompressionLevel == 1 || $self->desiredCompressionLevel == 2 ) {
        $self->{'bitFlag'} = DEFLATING_COMPRESSION_FAST;
    } elsif ( $self->desiredCompressionLevel == 3 || $self->desiredCompressionLevel == 4
          || $self->desiredCompressionLevel == 5 || $self->desiredCompressionLevel == 6
          || $self->desiredCompressionLevel == 7 ) {
        $self->{'bitFlag'} = DEFLATING_COMPRESSION_NORMAL;
    } elsif ( $self->desiredCompressionLevel == 8 || $self->desiredCompressionLevel == 9 ) {
        $self->{'bitFlag'} = DEFLATING_COMPRESSION_MAXIMUM;
    }
    $self->{'bitFlag'};
}

sub compressionMethod {
    shift->{'compressionMethod'};
}

sub desiredCompressionMethod {
    my $self = shift;
    my $newDesiredCompressionMethod =
      ( ref( $_[0] ) eq 'HASH' ) ? shift->{compressionMethod} : shift;
    my $oldDesiredCompressionMethod = $self->{'desiredCompressionMethod'};
    if ( defined($newDesiredCompressionMethod) ) {
        $self->{'desiredCompressionMethod'} = $newDesiredCompressionMethod;
        if ( $newDesiredCompressionMethod == COMPRESSION_STORED ) {
            $self->{'desiredCompressionLevel'} = 0;
            $self->{'bitFlag'} &= ~GPBF_HAS_DATA_DESCRIPTOR_MASK;

        } elsif ( $oldDesiredCompressionMethod == COMPRESSION_STORED ) {
            $self->{'desiredCompressionLevel'} = COMPRESSION_LEVEL_DEFAULT;
        }
    }
    return $oldDesiredCompressionMethod;
}

sub desiredCompressionLevel {
    my $self = shift;
    my $newDesiredCompressionLevel =
      ( ref( $_[0] ) eq 'HASH' ) ? shift->{compressionLevel} : shift;
    my $oldDesiredCompressionLevel = $self->{'desiredCompressionLevel'};
    if ( defined($newDesiredCompressionLevel) ) {
        $self->{'desiredCompressionLevel'}  = $newDesiredCompressionLevel;
        $self->{'desiredCompressionMethod'} = (
            $newDesiredCompressionLevel
            ? COMPRESSION_DEFLATED
            : COMPRESSION_STORED
        );
    }
    return $oldDesiredCompressionLevel;
}

sub fileName {
    my $self    = shift;
    my $newName = shift;
    if ($newName) {
        $newName =~ s{[\\/]+}{/}g;    # deal with dos/windoze problems
        $self->{'fileName'} = $newName;
    }
    return $self->{'fileName'};
}

sub lastModFileDateTime {
    my $modTime = shift->{'lastModFileDateTime'};
    $modTime =~ m/^(\d+)$/;           # untaint
    return $1;
}

sub lastModTime {
    my $self = shift;
    return _dosToUnixTime( $self->lastModFileDateTime() );
}

sub setLastModFileDateTimeFromUnix {
    my $self   = shift;
    my $time_t = shift;
    $self->{'lastModFileDateTime'} = _unixToDosTime($time_t);
}

sub internalFileAttributes {
    shift->{'internalFileAttributes'};
}

sub externalFileAttributes {
    shift->{'externalFileAttributes'};
}

# Convert UNIX permissions into proper value for zip file
# Usable as a function or a method
sub _mapPermissionsFromUnix {
    my $self    = shift;
    my $mode    = shift;
    my $attribs = $mode << 16;

    # Microsoft Windows Explorer needs this bit set for directories
    if ( $mode & DIRECTORY_ATTRIB ) {
        $attribs |= 16;
    }

    return $attribs;

    # TODO: map more MS-DOS perms
}

# Convert ZIP permissions into Unix ones
#
# This was taken from Info-ZIP group's portable UnZip
# zipfile-extraction program, version 5.50.
# http://www.info-zip.org/pub/infozip/
#
# See the mapattr() function in unix/unix.c
# See the attribute format constants in unzpriv.h
#
# XXX Note that there's one situation that isn't implemented
# yet that depends on the "extra field."
sub _mapPermissionsToUnix {
    my $self = shift;

    my $format  = $self->{'fileAttributeFormat'};
    my $attribs = $self->{'externalFileAttributes'};

    my $mode = 0;

    if ( $format == FA_AMIGA ) {
        $attribs = $attribs >> 17 & 7;                         # Amiga RWE bits
        $mode    = $attribs << 6 | $attribs << 3 | $attribs;
        return $mode;
    }

    if ( $format == FA_THEOS ) {
        $attribs &= 0xF1FFFFFF;
        if ( ( $attribs & 0xF0000000 ) != 0x40000000 ) {
            $attribs &= 0x01FFFFFF;    # not a dir, mask all ftype bits
        }
        else {
            $attribs &= 0x41FFFFFF;    # leave directory bit as set
        }
    }

    if (   $format == FA_UNIX
        || $format == FA_VAX_VMS
        || $format == FA_ACORN
        || $format == FA_ATARI_ST
        || $format == FA_BEOS
        || $format == FA_QDOS
        || $format == FA_TANDEM )
    {
        $mode = $attribs >> 16;
        return $mode if $mode != 0 or not $self->localExtraField;

        # warn("local extra field is: ", $self->localExtraField, "\n");

        # XXX This condition is not implemented
        # I'm just including the comments from the info-zip section for now.

        # Some (non-Info-ZIP) implementations of Zip for Unix and
        # VMS (and probably others ??) leave 0 in the upper 16-bit
        # part of the external_file_attributes field. Instead, they
        # store file permission attributes in some extra field.
        # As a work-around, we search for the presence of one of
        # these extra fields and fall back to the MSDOS compatible
        # part of external_file_attributes if one of the known
        # e.f. types has been detected.
        # Later, we might implement extraction of the permission
        # bits from the VMS extra field. But for now, the work-around
        # should be sufficient to provide "readable" extracted files.
        # (For ASI Unix e.f., an experimental remap from the e.f.
        # mode value IS already provided!)
    }

    # PKWARE's PKZip for Unix marks entries as FA_MSDOS, but stores the
    # Unix attributes in the upper 16 bits of the external attributes
    # field, just like Info-ZIP's Zip for Unix.  We try to use that
    # value, after a check for consistency with the MSDOS attribute
    # bits (see below).
    if ( $format == FA_MSDOS ) {
        $mode = $attribs >> 16;
    }

    # FA_MSDOS, FA_OS2_HPFS, FA_WINDOWS_NTFS, FA_MACINTOSH, FA_TOPS20
    $attribs = !( $attribs & 1 ) << 1 | ( $attribs & 0x10 ) >> 4;

    # keep previous $mode setting when its "owner"
    # part appears to be consistent with DOS attribute flags!
    return $mode if ( $mode & 0700 ) == ( 0400 | $attribs << 6 );
    $mode = 0444 | $attribs << 6 | $attribs << 3 | $attribs;
    return $mode;
}

sub unixFileAttributes {
    my $self     = shift;
    my $oldPerms = $self->_mapPermissionsToUnix;

    my $perms;
    if ( @_ ) {
        $perms = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{attributes} : $_[0];

        if ( $self->isDirectory ) {
            $perms &= ~FILE_ATTRIB;
            $perms |= DIRECTORY_ATTRIB;
        } else {
            $perms &= ~DIRECTORY_ATTRIB;
            $perms |= FILE_ATTRIB;
        }
        $self->{externalFileAttributes} = $self->_mapPermissionsFromUnix($perms);
    }

    return $oldPerms;
}

sub localExtraField {
    my $self = shift;

    if (@_) {
        $self->{localExtraField} = ( ref( $_[0] ) eq 'HASH' )
          ? $_[0]->{field} : $_[0];
    }
    else {
        return $self->{localExtraField};
    }
}

sub cdExtraField {
    my $self = shift;

    if (@_) {
        $self->{cdExtraField} = ( ref( $_[0] ) eq 'HASH' )
          ? $_[0]->{field} : $_[0];
    }
    else {
        return $self->{cdExtraField};
    }
}

sub extraFields {
    my $self = shift;
    return $self->localExtraField() . $self->cdExtraField();
}

sub fileComment {
    my $self = shift;

    if (@_) {
        $self->{fileComment} = ( ref( $_[0] ) eq 'HASH' )
          ? pack( 'C0a*', $_[0]->{comment} ) : pack( 'C0a*', $_[0] );
    }
    else {
        return $self->{fileComment};
    }
}

sub hasDataDescriptor {
    my $self = shift;
    if (@_) {
        my $shouldHave = shift;
        if ($shouldHave) {
            $self->{'bitFlag'} |= GPBF_HAS_DATA_DESCRIPTOR_MASK;
        }
        else {
            $self->{'bitFlag'} &= ~GPBF_HAS_DATA_DESCRIPTOR_MASK;
        }
    }
    return $self->{'bitFlag'} & GPBF_HAS_DATA_DESCRIPTOR_MASK;
}

sub crc32 {
    shift->{'crc32'};
}

sub crc32String {
    sprintf( "%08x", shift->{'crc32'} );
}

sub compressedSize {
    shift->{'compressedSize'};
}

sub uncompressedSize {
    shift->{'uncompressedSize'};
}

sub isEncrypted {
    shift->bitFlag() & GPBF_ENCRYPTED_MASK;
}

sub isTextFile {
    my $self = shift;
    my $bit  = $self->internalFileAttributes() & IFA_TEXT_FILE_MASK;
    if (@_) {
        my $flag = ( ref( $_[0] ) eq 'HASH' ) ? shift->{flag} : shift;
        $self->{'internalFileAttributes'} &= ~IFA_TEXT_FILE_MASK;
        $self->{'internalFileAttributes'} |=
          ( $flag ? IFA_TEXT_FILE: IFA_BINARY_FILE );
    }
    return $bit == IFA_TEXT_FILE;
}

sub isBinaryFile {
    my $self = shift;
    my $bit  = $self->internalFileAttributes() & IFA_TEXT_FILE_MASK;
    if (@_) {
        my $flag = shift;
        $self->{'internalFileAttributes'} &= ~IFA_TEXT_FILE_MASK;
        $self->{'internalFileAttributes'} |=
          ( $flag ? IFA_BINARY_FILE: IFA_TEXT_FILE );
    }
    return $bit == IFA_BINARY_FILE;
}

sub extractToFileNamed {
    my $self = shift;

    # local FS name
    my $name = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{name} : $_[0];
    $self->{'isSymbolicLink'} = 0;

    # Check if the file / directory is a symbolic link or not
    if ( $self->{'externalFileAttributes'} == 0xA1FF0000 ) {
        $self->{'isSymbolicLink'} = 1;
        $self->{'newName'} = $name;
        my ( $status, $fh ) = _newFileHandle( $name, 'r' );
        my $retval = $self->extractToFileHandle($fh);
        $fh->close();
    } else {
        #return _writeSymbolicLink($self, $name) if $self->isSymbolicLink();
        return _error("encryption unsupported") if $self->isEncrypted();
        mkpath( dirname($name) );    # croaks on error
        my ( $status, $fh ) = _newFileHandle( $name, 'w' );
        return _ioError("Can't open file $name for write") unless $status;
        my $retval = $self->extractToFileHandle($fh);
        $fh->close();
        chmod ($self->unixFileAttributes(), $name)
            or return _error("Can't chmod() ${name}: $!");
        utime( $self->lastModTime(), $self->lastModTime(), $name );
        return $retval;
    }
}

sub _writeSymbolicLink {
    my $self = shift;
    my $name = shift;
    my $chunkSize = $Archive::Zip::ChunkSize;
    #my ( $outRef, undef ) = $self->readChunk($chunkSize);
    my $fh;
    my $retval = $self->extractToFileHandle($fh);
    my ( $outRef, undef ) = $self->readChunk(100);
}

sub isSymbolicLink {
    my $self = shift;
    if ( $self->{'externalFileAttributes'} == 0xA1FF0000 ) {
        $self->{'isSymbolicLink'} = 1;
    } else {
        return 0;
    }
    1;
}

sub isDirectory {
    return 0;
}

sub externalFileName {
    return undef;
}

# The following are used when copying data
sub _writeOffset {
    shift->{'writeOffset'};
}

sub _readOffset {
    shift->{'readOffset'};
}

sub writeLocalHeaderRelativeOffset {
    shift->{'writeLocalHeaderRelativeOffset'};
}

sub wasWritten { shift->{'wasWritten'} }

sub _dataEnded {
    shift->{'dataEnded'};
}

sub _readDataRemaining {
    shift->{'readDataRemaining'};
}

sub _inflater {
    shift->{'inflater'};
}

sub _deflater {
    shift->{'deflater'};
}

# Return the total size of my local header
sub _localHeaderSize {
    my $self = shift;
    return SIGNATURE_LENGTH + LOCAL_FILE_HEADER_LENGTH +
      length( $self->fileName() ) + length( $self->localExtraField() );
}

# Return the total size of my CD header
sub _centralDirectoryHeaderSize {
    my $self = shift;
    return SIGNATURE_LENGTH + CENTRAL_DIRECTORY_FILE_HEADER_LENGTH +
      length( $self->fileName() ) + length( $self->cdExtraField() ) +
      length( $self->fileComment() );
}

# DOS date/time format
# 0-4 (5) Second divided by 2
# 5-10 (6) Minute (0-59)
# 11-15 (5) Hour (0-23 on a 24-hour clock)
# 16-20 (5) Day of the month (1-31)
# 21-24 (4) Month (1 = January, 2 = February, etc.)
# 25-31 (7) Year offset from 1980 (add 1980 to get actual year)

# Convert DOS date/time format to unix time_t format
# NOT AN OBJECT METHOD!
sub _dosToUnixTime {
    my $dt = shift;
    return time() unless defined($dt);

    my $year = ( ( $dt >> 25 ) & 0x7f ) + 80;
    my $mon  = ( ( $dt >> 21 ) & 0x0f ) - 1;
    my $mday = ( ( $dt >> 16 ) & 0x1f );

    my $hour = ( ( $dt >> 11 ) & 0x1f );
    my $min  = ( ( $dt >> 5 ) & 0x3f );
    my $sec  = ( ( $dt << 1 ) & 0x3e );

    # catch errors
    my $time_t =
      eval { Time::Local::timelocal( $sec, $min, $hour, $mday, $mon, $year ); };
    return time() if ($@);
    return $time_t;
}

# Note, this isn't exactly UTC 1980, it's 1980 + 12 hours and 1
# minute so that nothing timezoney can muck us up.
my $safe_epoch = 315576060;

# convert a unix time to DOS date/time
# NOT AN OBJECT METHOD!
sub _unixToDosTime {
    my $time_t = shift;
    unless ($time_t) {
        _error("Tried to add member with zero or undef value for time");
        $time_t = $safe_epoch;
    }
    if ( $time_t < $safe_epoch ) {
        _ioError("Unsupported date before 1980 encountered, moving to 1980");
        $time_t = $safe_epoch;
    }
    my ( $sec, $min, $hour, $mday, $mon, $year ) = localtime($time_t);
    my $dt = 0;
    $dt += ( $sec >> 1 );
    $dt += ( $min << 5 );
    $dt += ( $hour << 11 );
    $dt += ( $mday << 16 );
    $dt += ( ( $mon + 1 ) << 21 );
    $dt += ( ( $year - 80 ) << 25 );
    return $dt;
}

# Write my local header to a file handle.
# Stores the offset to the start of the header in my
# writeLocalHeaderRelativeOffset member.
# Returns AZ_OK on success.
sub _writeLocalFileHeader {
    my $self = shift;
    my $fh   = shift;

    my $signatureData = pack( SIGNATURE_FORMAT, LOCAL_FILE_HEADER_SIGNATURE );
    $self->_print($fh, $signatureData)
      or return _ioError("writing local header signature");

    my $header = pack(
        LOCAL_FILE_HEADER_FORMAT,
        $self->versionNeededToExtract(),
        $self->bitFlag(),
        $self->desiredCompressionMethod(),
        $self->lastModFileDateTime(),
        $self->crc32(),
        $self->compressedSize(),    # may need to be re-written later
        $self->uncompressedSize(),
        length( $self->fileName() ),
        length( $self->localExtraField() )
    );

    $self->_print($fh, $header) or return _ioError("writing local header");

    # Check for a valid filename or a filename equal to a literal `0'
    if ( $self->fileName() || $self->fileName eq '0' ) {
        $self->_print($fh, $self->fileName() )
          or return _ioError("writing local header filename");
    }
    if ( $self->localExtraField() ) {
        $self->_print($fh, $self->localExtraField() )
          or return _ioError("writing local extra field");
    }

    return AZ_OK;
}

sub _writeCentralDirectoryFileHeader {
    my $self = shift;
    my $fh   = shift;

    my $sigData =
      pack( SIGNATURE_FORMAT, CENTRAL_DIRECTORY_FILE_HEADER_SIGNATURE );
    $self->_print($fh, $sigData)
      or return _ioError("writing central directory header signature");

    my $fileNameLength    = length( $self->fileName() );
    my $extraFieldLength  = length( $self->cdExtraField() );
    my $fileCommentLength = length( $self->fileComment() );

    my $header = pack(
        CENTRAL_DIRECTORY_FILE_HEADER_FORMAT,
        $self->versionMadeBy(),
        $self->fileAttributeFormat(),
        $self->versionNeededToExtract(),
        $self->bitFlag(),
        $self->desiredCompressionMethod(),
        $self->lastModFileDateTime(),
        $self->crc32(),            # these three fields should have been updated
        $self->_writeOffset(),     # by writing the data stream out
        $self->uncompressedSize(), #
        $fileNameLength,
        $extraFieldLength,
        $fileCommentLength,
        0,                         # {'diskNumberStart'},
        $self->internalFileAttributes(),
        $self->externalFileAttributes(),
        $self->writeLocalHeaderRelativeOffset()
    );

    $self->_print($fh, $header)
      or return _ioError("writing central directory header");
    if ($fileNameLength) {
        $self->_print($fh,  $self->fileName() )
          or return _ioError("writing central directory header signature");
    }
    if ($extraFieldLength) {
        $self->_print($fh,  $self->cdExtraField() )
          or return _ioError("writing central directory extra field");
    }
    if ($fileCommentLength) {
        $self->_print($fh,  $self->fileComment() )
          or return _ioError("writing central directory file comment");
    }

    return AZ_OK;
}

# This writes a data descriptor to the given file handle.
# Assumes that crc32, writeOffset, and uncompressedSize are
# set correctly (they should be after a write).
# Further, the local file header should have the
# GPBF_HAS_DATA_DESCRIPTOR_MASK bit set.
sub _writeDataDescriptor {
    my $self   = shift;
    my $fh     = shift;
    my $header = pack(
        SIGNATURE_FORMAT . DATA_DESCRIPTOR_FORMAT,
        DATA_DESCRIPTOR_SIGNATURE,
        $self->crc32(),
        $self->_writeOffset(),    # compressed size
        $self->uncompressedSize()
    );

    $self->_print($fh, $header)
      or return _ioError("writing data descriptor");
    return AZ_OK;
}

# Re-writes the local file header with new crc32 and compressedSize fields.
# To be called after writing the data stream.
# Assumes that filename and extraField sizes didn't change since last written.
sub _refreshLocalFileHeader {
    my $self = shift;
    my $fh   = shift;

    my $here = $fh->tell();
    $fh->seek( $self->writeLocalHeaderRelativeOffset() + SIGNATURE_LENGTH,
        IO::Seekable::SEEK_SET )
      or return _ioError("seeking to rewrite local header");

    my $header = pack(
        LOCAL_FILE_HEADER_FORMAT,
        $self->versionNeededToExtract(),
        $self->bitFlag(),
        $self->desiredCompressionMethod(),
        $self->lastModFileDateTime(),
        $self->crc32(),
        $self->_writeOffset(),    # compressed size
        $self->uncompressedSize(),
        length( $self->fileName() ),
        length( $self->localExtraField() )
    );

    $self->_print($fh, $header)
      or return _ioError("re-writing local header");
    $fh->seek( $here, IO::Seekable::SEEK_SET )
      or return _ioError("seeking after rewrite of local header");

    return AZ_OK;
}

sub readChunk {
    my $self = shift;
    my $chunkSize = ( ref( $_[0] ) eq 'HASH' ) ? $_[0]->{chunkSize} : $_[0];

    if ( $self->readIsDone() ) {
        $self->endRead();
        my $dummy = '';
        return ( \$dummy, AZ_STREAM_END );
    }

    $chunkSize = $Archive::Zip::ChunkSize if not defined($chunkSize);
    $chunkSize = $self->_readDataRemaining()
      if $chunkSize > $self->_readDataRemaining();

    my $buffer = '';
    my $outputRef;
    my ( $bytesRead, $status ) = $self->_readRawChunk( \$buffer, $chunkSize );
    return ( \$buffer, $status ) unless $status == AZ_OK;

    $self->{'readDataRemaining'} -= $bytesRead;
    $self->{'readOffset'} += $bytesRead;

    if ( $self->compressionMethod() == COMPRESSION_STORED ) {
        $self->{'crc32'} = $self->computeCRC32( $buffer, $self->{'crc32'} );
    }

    ( $outputRef, $status ) = &{ $self->{'chunkHandler'} }( $self, \$buffer );
    $self->{'writeOffset'} += length($$outputRef);

    $self->endRead()
      if $self->readIsDone();

    return ( $outputRef, $status );
}

# Read the next raw chunk of my data. Subclasses MUST implement.
#	my ( $bytesRead, $status) = $self->_readRawChunk( \$buffer, $chunkSize );
sub _readRawChunk {
    my $self = shift;
    return $self->_subclassResponsibility();
}

# A place holder to catch rewindData errors if someone ignores
# the error code.
sub _noChunk {
    my $self = shift;
    return ( \undef, _error("trying to copy chunk when init failed") );
}

# Basically a no-op so that I can have a consistent interface.
# ( $outputRef, $status) = $self->_copyChunk( \$buffer );
sub _copyChunk {
    my ( $self, $dataRef ) = @_;
    return ( $dataRef, AZ_OK );
}

# ( $outputRef, $status) = $self->_deflateChunk( \$buffer );
sub _deflateChunk {
    my ( $self, $buffer ) = @_;
    my ( $status ) = $self->_deflater()->deflate( $buffer, my $out );

    if ( $self->_readDataRemaining() == 0 ) {
        my $extraOutput;
        ( $status ) = $self->_deflater()->flush($extraOutput);
        $out .= $extraOutput;
        $self->endRead();
        return ( \$out, AZ_STREAM_END );
    }
    elsif ( $status == Z_OK ) {
        return ( \$out, AZ_OK );
    }
    else {
        $self->endRead();
        my $retval = _error( 'deflate error', $status );
        my $dummy = '';
        return ( \$dummy, $retval );
    }
}

# ( $outputRef, $status) = $self->_inflateChunk( \$buffer );
sub _inflateChunk {
    my ( $self, $buffer ) = @_;
    my ( $status ) = $self->_inflater()->inflate( $buffer, my $out );
    my $retval;
    $self->endRead() unless $status == Z_OK;
    if ( $status == Z_OK || $status == Z_STREAM_END ) {
        $retval = ( $status == Z_STREAM_END ) ? AZ_STREAM_END: AZ_OK;
        return ( \$out, $retval );
    }
    else {
        $retval = _error( 'inflate error', $status );
        my $dummy = '';
        return ( \$dummy, $retval );
    }
}

sub rewindData {
    my $self = shift;
    my $status;

    # set to trap init errors
    $self->{'chunkHandler'} = $self->can('_noChunk');

    # Work around WinZip bug with 0-length DEFLATED files
    $self->desiredCompressionMethod(COMPRESSION_STORED)
      if $self->uncompressedSize() == 0;

    # assume that we're going to read the whole file, and compute the CRC anew.
    $self->{'crc32'} = 0
      if ( $self->compressionMethod() == COMPRESSION_STORED );

    # These are the only combinations of methods we deal with right now.
    if (    $self->compressionMethod() == COMPRESSION_STORED
        and $self->desiredCompressionMethod() == COMPRESSION_DEFLATED )
    {
        ( $self->{'deflater'}, $status ) = Compress::Raw::Zlib::Deflate->new(
            '-Level'      => $self->desiredCompressionLevel(),
            '-WindowBits' => -MAX_WBITS(),                     # necessary magic
            '-Bufsize'    => $Archive::Zip::ChunkSize,
            @_
        );    # pass additional options
        return _error( 'deflateInit error:', $status )
          unless $status == Z_OK;
        $self->{'chunkHandler'} = $self->can('_deflateChunk');
    }
    elsif ( $self->compressionMethod() == COMPRESSION_DEFLATED
        and $self->desiredCompressionMethod() == COMPRESSION_STORED )
    {
        ( $self->{'inflater'}, $status ) = Compress::Raw::Zlib::Inflate->new(
            '-WindowBits' => -MAX_WBITS(),               # necessary magic
            '-Bufsize'    => $Archive::Zip::ChunkSize,
            @_
        );    # pass additional options
        return _error( 'inflateInit error:', $status )
          unless $status == Z_OK;
        $self->{'chunkHandler'} = $self->can('_inflateChunk');
    }
    elsif ( $self->compressionMethod() == $self->desiredCompressionMethod() ) {
        $self->{'chunkHandler'} = $self->can('_copyChunk');
    }
    else {
        return _error(
            sprintf(
                "Unsupported compression combination: read %d, write %d",
                $self->compressionMethod(),
                $self->desiredCompressionMethod()
            )
        );
    }

    $self->{'readDataRemaining'} =
      ( $self->compressionMethod() == COMPRESSION_STORED )
      ? $self->uncompressedSize()
      : $self->compressedSize();
    $self->{'dataEnded'}  = 0;
    $self->{'readOffset'} = 0;

    return AZ_OK;
}

sub endRead {
    my $self = shift;
    delete $self->{'inflater'};
    delete $self->{'deflater'};
    $self->{'dataEnded'}         = 1;
    $self->{'readDataRemaining'} = 0;
    return AZ_OK;
}

sub readIsDone {
    my $self = shift;
    return ( $self->_dataEnded() or !$self->_readDataRemaining() );
}

sub contents {
    my $self        = shift;
    my $newContents = shift;

    if ( defined($newContents) ) {

        # change our type and call the subclass contents method.
        $self->_become(STRINGMEMBERCLASS);
        return $self->contents( pack( 'C0a*', $newContents ) )
          ;    # in case of Unicode
    }
    else {
        my $oldCompression =
          $self->desiredCompressionMethod(COMPRESSION_STORED);
        my $status = $self->rewindData(@_);
        if ( $status != AZ_OK ) {
            $self->endRead();
            return $status;
        }
        my $retval = '';
        while ( $status == AZ_OK ) {
            my $ref;
            ( $ref, $status ) = $self->readChunk( $self->_readDataRemaining() );

            # did we get it in one chunk?
            if ( length($$ref) == $self->uncompressedSize() ) {
                $retval = $$ref;
            }
            else { $retval .= $$ref }
        }
        $self->desiredCompressionMethod($oldCompression);
        $self->endRead();
        $status = AZ_OK if $status == AZ_STREAM_END;
        $retval = undef unless $status == AZ_OK;
        return wantarray ? ( $retval, $status ) : $retval;
    }
}

sub extractToFileHandle {
    my $self = shift;
    return _error("encryption unsupported") if $self->isEncrypted();
    my $fh = ( ref( $_[0] ) eq 'HASH' ) ? shift->{fileHandle} : shift;
    _binmode($fh);
    my $oldCompression = $self->desiredCompressionMethod(COMPRESSION_STORED);
    my $status         = $self->rewindData(@_);
    $status = $self->_writeData($fh) if $status == AZ_OK;
    $self->desiredCompressionMethod($oldCompression);
    $self->endRead();
    return $status;
}

# write local header and data stream to file handle
sub _writeToFileHandle {
    my $self         = shift;
    my $fh           = shift;
    my $fhIsSeekable = shift;
    my $offset       = shift;

    return _error("no member name given for $self")
      if $self->fileName() eq '';

    $self->{'writeLocalHeaderRelativeOffset'} = $offset;
    $self->{'wasWritten'}                     = 0;

    # Determine if I need to write a data descriptor
    # I need to do this if I can't refresh the header
    # and I don't know compressed size or crc32 fields.
    my $headerFieldsUnknown = (
        ( $self->uncompressedSize() > 0 )
          and ($self->compressionMethod() == COMPRESSION_STORED
            or $self->desiredCompressionMethod() == COMPRESSION_DEFLATED )
    );

    my $shouldWriteDataDescriptor =
      ( $headerFieldsUnknown and not $fhIsSeekable );

    $self->hasDataDescriptor(1)
      if ($shouldWriteDataDescriptor);

    $self->{'writeOffset'} = 0;

    my $status = $self->rewindData();
    ( $status = $self->_writeLocalFileHeader($fh) )
      if $status == AZ_OK;
    ( $status = $self->_writeData($fh) )
      if $status == AZ_OK;
    if ( $status == AZ_OK ) {
        $self->{'wasWritten'} = 1;
        if ( $self->hasDataDescriptor() ) {
            $status = $self->_writeDataDescriptor($fh);
        }
        elsif ($headerFieldsUnknown) {
            $status = $self->_refreshLocalFileHeader($fh);
        }
    }

    return $status;
}

# Copy my (possibly compressed) data to given file handle.
# Returns C<AZ_OK> on success
sub _writeData {
    my $self    = shift;
    my $writeFh = shift;

    # If symbolic link, just create one if the operating system is Linux, Unix, BSD or VMS
    # TODO: Add checks for other operating systems
    if ( $self->{'isSymbolicLink'} == 1 && $^O eq 'linux' ) {
        my $chunkSize = $Archive::Zip::ChunkSize;
        my ( $outRef, $status ) = $self->readChunk($chunkSize);
        symlink $$outRef, $self->{'newName'};
    } else {
        return AZ_OK if ( $self->uncompressedSize() == 0 );
        my $status;
        my $chunkSize = $Archive::Zip::ChunkSize;
        while ( $self->_readDataRemaining() > 0 ) {
            my $outRef;
            ( $outRef, $status ) = $self->readChunk($chunkSize);
            return $status if ( $status != AZ_OK and $status != AZ_STREAM_END );

            if ( length($$outRef) > 0 ) {
                $self->_print($writeFh, $$outRef)
                  or return _ioError("write error during copy");
            }

            last if $status == AZ_STREAM_END;
        }
        $self->{'compressedSize'} = $self->_writeOffset();
    }
    return AZ_OK;
}

# Return true if I depend on the named file
sub _usesFileNamed {
    return 0;
}

1;
FILE   %fc53c330/Archive/Zip/NewFileMember.pm  �#line 1 "/home/danny/perl5/lib/perl5/Archive/Zip/NewFileMember.pm"
package Archive::Zip::NewFileMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw ( Archive::Zip::FileMember );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
  :UTILITY_METHODS
);

# Given a file name, set up for eventual writing.
sub _newFromFileNamed {
    my $class    = shift;
    my $fileName = shift;    # local FS format
    my $newName  = shift;
    $newName = _asZipDirName($fileName) unless defined($newName);
    return undef unless ( stat($fileName) && -r _ && !-d _ );
    my $self = $class->new(@_);
    $self->{'fileName'} = $newName;
    $self->{'externalFileName'}  = $fileName;
    $self->{'compressionMethod'} = COMPRESSION_STORED;
    my @stat = stat(_);
    $self->{'compressedSize'} = $self->{'uncompressedSize'} = $stat[7];
    $self->desiredCompressionMethod(
        ( $self->compressedSize() > 0 )
        ? COMPRESSION_DEFLATED
        : COMPRESSION_STORED
    );
    $self->unixFileAttributes( $stat[2] );
    $self->setLastModFileDateTimeFromUnix( $stat[9] );
    $self->isTextFile( -T _ );
    return $self;
}

sub rewindData {
    my $self = shift;

    my $status = $self->SUPER::rewindData(@_);
    return $status unless $status == AZ_OK;

    return AZ_IO_ERROR unless $self->fh();
    $self->fh()->clearerr();
    $self->fh()->seek( 0, IO::Seekable::SEEK_SET )
      or return _ioError( "rewinding", $self->externalFileName() );
    return AZ_OK;
}

# Return bytes read. Note that first parameter is a ref to a buffer.
# my $data;
# my ( $bytesRead, $status) = $self->readRawChunk( \$data, $chunkSize );
sub _readRawChunk {
    my ( $self, $dataRef, $chunkSize ) = @_;
    return ( 0, AZ_OK ) unless $chunkSize;
    my $bytesRead = $self->fh()->read( $$dataRef, $chunkSize )
      or return ( 0, _ioError("reading data") );
    return ( $bytesRead, AZ_OK );
}

# If I already exist, extraction is a no-op.
sub extractToFileNamed {
    my $self = shift;
    my $name = shift;    # local FS name
    if ( File::Spec->rel2abs($name) eq
        File::Spec->rel2abs( $self->externalFileName() ) and -r $name )
    {
        return AZ_OK;
    }
    else {
        return $self->SUPER::extractToFileNamed( $name, @_ );
    }
}

1;
FILE   $3ff88b2b/Archive/Zip/StringMember.pm  
#line 1 "/home/danny/perl5/lib/perl5/Archive/Zip/StringMember.pm"
package Archive::Zip::StringMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw( Archive::Zip::Member );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
);

# Create a new string member. Default is COMPRESSION_STORED.
# Can take a ref to a string as well.
sub _newFromString {
    my $class  = shift;
    my $string = shift;
    my $name   = shift;
    my $self   = $class->new(@_);
    $self->contents($string);
    $self->fileName($name) if defined($name);

    # Set the file date to now
    $self->setLastModFileDateTimeFromUnix( time() );
    $self->unixFileAttributes( $self->DEFAULT_FILE_PERMISSIONS );
    return $self;
}

sub _become {
    my $self     = shift;
    my $newClass = shift;
    return $self if ref($self) eq $newClass;
    delete( $self->{'contents'} );
    return $self->SUPER::_become($newClass);
}

# Get or set my contents. Note that we do not call the superclass
# version of this, because it calls us.
sub contents {
    my $self   = shift;
    my $string = shift;
    if ( defined($string) ) {
        $self->{'contents'} =
          pack( 'C0a*', ( ref($string) eq 'SCALAR' ) ? $$string : $string );
        $self->{'uncompressedSize'} = $self->{'compressedSize'} =
          length( $self->{'contents'} );
        $self->{'compressionMethod'} = COMPRESSION_STORED;
    }
    return $self->{'contents'};
}

# Return bytes read. Note that first parameter is a ref to a buffer.
# my $data;
# my ( $bytesRead, $status) = $self->readRawChunk( \$data, $chunkSize );
sub _readRawChunk {
    my ( $self, $dataRef, $chunkSize ) = @_;
    $$dataRef = substr( $self->contents(), $self->_readOffset(), $chunkSize );
    return ( length($$dataRef), AZ_OK );
}

1;
FILE   %a8bc56f0/Archive/Zip/ZipFileMember.pm  5#line 1 "/home/danny/perl5/lib/perl5/Archive/Zip/ZipFileMember.pm"
package Archive::Zip::ZipFileMember;

use strict;
use vars qw( $VERSION @ISA );

BEGIN {
    $VERSION = '1.30';
    @ISA     = qw ( Archive::Zip::FileMember );
}

use Archive::Zip qw(
  :CONSTANTS
  :ERROR_CODES
  :PKZIP_CONSTANTS
  :UTILITY_METHODS
);

# Create a new Archive::Zip::ZipFileMember
# given a filename and optional open file handle
#
sub _newFromZipFile {
    my $class              = shift;
    my $fh                 = shift;
    my $externalFileName   = shift;
    my $possibleEocdOffset = shift;    # normally 0

    my $self = $class->new(
        'crc32'                     => 0,
        'diskNumberStart'           => 0,
        'localHeaderRelativeOffset' => 0,
        'dataOffset' => 0,    # localHeaderRelativeOffset + header length
        @_
    );
    $self->{'externalFileName'}   = $externalFileName;
    $self->{'fh'}                 = $fh;
    $self->{'possibleEocdOffset'} = $possibleEocdOffset;
    return $self;
}

sub isDirectory {
    my $self = shift;
    return (
        substr( $self->fileName, -1, 1 ) eq '/'
        and
        $self->uncompressedSize == 0
    );
}

# Seek to the beginning of the local header, just past the signature.
# Verify that the local header signature is in fact correct.
# Update the localHeaderRelativeOffset if necessary by adding the possibleEocdOffset.
# Returns status.

sub _seekToLocalHeader {
    my $self          = shift;
    my $where         = shift;    # optional
    my $previousWhere = shift;    # optional

    $where = $self->localHeaderRelativeOffset() unless defined($where);

    # avoid loop on certain corrupt files (from Julian Field)
    return _formatError("corrupt zip file")
      if defined($previousWhere) && $where == $previousWhere;

    my $status;
    my $signature;

    $status = $self->fh()->seek( $where, IO::Seekable::SEEK_SET );
    return _ioError("seeking to local header") unless $status;

    ( $status, $signature ) =
      _readSignature( $self->fh(), $self->externalFileName(),
        LOCAL_FILE_HEADER_SIGNATURE );
    return $status if $status == AZ_IO_ERROR;

    # retry with EOCD offset if any was given.
    if ( $status == AZ_FORMAT_ERROR && $self->{'possibleEocdOffset'} ) {
        $status = $self->_seekToLocalHeader(
            $self->localHeaderRelativeOffset() + $self->{'possibleEocdOffset'},
            $where
        );
        if ( $status == AZ_OK ) {
            $self->{'localHeaderRelativeOffset'} +=
              $self->{'possibleEocdOffset'};
            $self->{'possibleEocdOffset'} = 0;
        }
    }

    return $status;
}

# Because I'm going to delete the file handle, read the local file
# header if the file handle is seekable. If it isn't, I assume that
# I've already read the local header.
# Return ( $status, $self )

sub _become {
    my $self     = shift;
    my $newClass = shift;
    return $self if ref($self) eq $newClass;

    my $status = AZ_OK;

    if ( _isSeekable( $self->fh() ) ) {
        my $here = $self->fh()->tell();
        $status = $self->_seekToLocalHeader();
        $status = $self->_readLocalFileHeader() if $status == AZ_OK;
        $self->fh()->seek( $here, IO::Seekable::SEEK_SET );
        return $status unless $status == AZ_OK;
    }

    delete( $self->{'eocdCrc32'} );
    delete( $self->{'diskNumberStart'} );
    delete( $self->{'localHeaderRelativeOffset'} );
    delete( $self->{'dataOffset'} );

    return $self->SUPER::_become($newClass);
}

sub diskNumberStart {
    shift->{'diskNumberStart'};
}

sub localHeaderRelativeOffset {
    shift->{'localHeaderRelativeOffset'};
}

sub dataOffset {
    shift->{'dataOffset'};
}

# Skip local file header, updating only extra field stuff.
# Assumes that fh is positioned before signature.
sub _skipLocalFileHeader {
    my $self = shift;
    my $header;
    my $bytesRead = $self->fh()->read( $header, LOCAL_FILE_HEADER_LENGTH );
    if ( $bytesRead != LOCAL_FILE_HEADER_LENGTH ) {
        return _ioError("reading local file header");
    }
    my $fileNameLength;
    my $extraFieldLength;
    my $bitFlag;
    (
        undef,    # $self->{'versionNeededToExtract'},
        $bitFlag,
        undef,    # $self->{'compressionMethod'},
        undef,    # $self->{'lastModFileDateTime'},
        undef,    # $crc32,
        undef,    # $compressedSize,
        undef,    # $uncompressedSize,
        $fileNameLength,
        $extraFieldLength
    ) = unpack( LOCAL_FILE_HEADER_FORMAT, $header );

    if ($fileNameLength) {
        $self->fh()->seek( $fileNameLength, IO::Seekable::SEEK_CUR )
          or return _ioError("skipping local file name");
    }

    if ($extraFieldLength) {
        $bytesRead =
          $self->fh()->read( $self->{'localExtraField'}, $extraFieldLength );
        if ( $bytesRead != $extraFieldLength ) {
            return _ioError("reading local extra field");
        }
    }

    $self->{'dataOffset'} = $self->fh()->tell();

    if ( $bitFlag & GPBF_HAS_DATA_DESCRIPTOR_MASK ) {

        # Read the crc32, compressedSize, and uncompressedSize from the
        # extended data descriptor, which directly follows the compressed data.
        #
        # Skip over the compressed file data (assumes that EOCD compressedSize
        # was correct)
        $self->fh()->seek( $self->{'compressedSize'}, IO::Seekable::SEEK_CUR )
          or return _ioError("seeking to extended local header");

        # these values should be set correctly from before.
        my $oldCrc32            = $self->{'eocdCrc32'};
        my $oldCompressedSize   = $self->{'compressedSize'};
        my $oldUncompressedSize = $self->{'uncompressedSize'};

        my $status = $self->_readDataDescriptor();
        return $status unless $status == AZ_OK;

        return _formatError(
            "CRC or size mismatch while skipping data descriptor")
          if ( $oldCrc32 != $self->{'crc32'}
            || $oldUncompressedSize != $self->{'uncompressedSize'} );
    }

    return AZ_OK;
}

# Read from a local file header into myself. Returns AZ_OK if successful.
# Assumes that fh is positioned after signature.
# Note that crc32, compressedSize, and uncompressedSize will be 0 if
# GPBF_HAS_DATA_DESCRIPTOR_MASK is set in the bitFlag.

sub _readLocalFileHeader {
    my $self = shift;
    my $header;
    my $bytesRead = $self->fh()->read( $header, LOCAL_FILE_HEADER_LENGTH );
    if ( $bytesRead != LOCAL_FILE_HEADER_LENGTH ) {
        return _ioError("reading local file header");
    }
    my $fileNameLength;
    my $crc32;
    my $compressedSize;
    my $uncompressedSize;
    my $extraFieldLength;
    (
        $self->{'versionNeededToExtract'}, $self->{'bitFlag'},
        $self->{'compressionMethod'},      $self->{'lastModFileDateTime'},
        $crc32,                            $compressedSize,
        $uncompressedSize,                 $fileNameLength,
        $extraFieldLength
    ) = unpack( LOCAL_FILE_HEADER_FORMAT, $header );

    if ($fileNameLength) {
        my $fileName;
        $bytesRead = $self->fh()->read( $fileName, $fileNameLength );
        if ( $bytesRead != $fileNameLength ) {
            return _ioError("reading local file name");
        }
        $self->fileName($fileName);
    }

    if ($extraFieldLength) {
        $bytesRead =
          $self->fh()->read( $self->{'localExtraField'}, $extraFieldLength );
        if ( $bytesRead != $extraFieldLength ) {
            return _ioError("reading local extra field");
        }
    }

    $self->{'dataOffset'} = $self->fh()->tell();

    if ( $self->hasDataDescriptor() ) {

        # Read the crc32, compressedSize, and uncompressedSize from the
        # extended data descriptor.
        # Skip over the compressed file data (assumes that EOCD compressedSize
        # was correct)
        $self->fh()->seek( $self->{'compressedSize'}, IO::Seekable::SEEK_CUR )
          or return _ioError("seeking to extended local header");

        my $status = $self->_readDataDescriptor();
        return $status unless $status == AZ_OK;
    }
    else {
        return _formatError(
            "CRC or size mismatch after reading data descriptor")
          if ( $self->{'crc32'} != $crc32
            || $self->{'uncompressedSize'} != $uncompressedSize );
    }

    return AZ_OK;
}

# This will read the data descriptor, which is after the end of compressed file
# data in members that that have GPBF_HAS_DATA_DESCRIPTOR_MASK set in their
# bitFlag.
# The only reliable way to find these is to rely on the EOCD compressedSize.
# Assumes that file is positioned immediately after the compressed data.
# Returns status; sets crc32, compressedSize, and uncompressedSize.
sub _readDataDescriptor {
    my $self = shift;
    my $signatureData;
    my $header;
    my $crc32;
    my $compressedSize;
    my $uncompressedSize;

    my $bytesRead = $self->fh()->read( $signatureData, SIGNATURE_LENGTH );
    return _ioError("reading header signature")
      if $bytesRead != SIGNATURE_LENGTH;
    my $signature = unpack( SIGNATURE_FORMAT, $signatureData );

    # unfortunately, the signature appears to be optional.
    if ( $signature == DATA_DESCRIPTOR_SIGNATURE
        && ( $signature != $self->{'crc32'} ) )
    {
        $bytesRead = $self->fh()->read( $header, DATA_DESCRIPTOR_LENGTH );
        return _ioError("reading data descriptor")
          if $bytesRead != DATA_DESCRIPTOR_LENGTH;

        ( $crc32, $compressedSize, $uncompressedSize ) =
          unpack( DATA_DESCRIPTOR_FORMAT, $header );
    }
    else {
        $bytesRead =
          $self->fh()->read( $header, DATA_DESCRIPTOR_LENGTH_NO_SIG );
        return _ioError("reading data descriptor")
          if $bytesRead != DATA_DESCRIPTOR_LENGTH_NO_SIG;

        $crc32 = $signature;
        ( $compressedSize, $uncompressedSize ) =
          unpack( DATA_DESCRIPTOR_FORMAT_NO_SIG, $header );
    }

    $self->{'eocdCrc32'} = $self->{'crc32'}
      unless defined( $self->{'eocdCrc32'} );
    $self->{'crc32'}            = $crc32;
    $self->{'compressedSize'}   = $compressedSize;
    $self->{'uncompressedSize'} = $uncompressedSize;

    return AZ_OK;
}

# Read a Central Directory header. Return AZ_OK on success.
# Assumes that fh is positioned right after the signature.

sub _readCentralDirectoryFileHeader {
    my $self      = shift;
    my $fh        = $self->fh();
    my $header    = '';
    my $bytesRead = $fh->read( $header, CENTRAL_DIRECTORY_FILE_HEADER_LENGTH );
    if ( $bytesRead != CENTRAL_DIRECTORY_FILE_HEADER_LENGTH ) {
        return _ioError("reading central dir header");
    }
    my ( $fileNameLength, $extraFieldLength, $fileCommentLength );
    (
        $self->{'versionMadeBy'},
        $self->{'fileAttributeFormat'},
        $self->{'versionNeededToExtract'},
        $self->{'bitFlag'},
        $self->{'compressionMethod'},
        $self->{'lastModFileDateTime'},
        $self->{'crc32'},
        $self->{'compressedSize'},
        $self->{'uncompressedSize'},
        $fileNameLength,
        $extraFieldLength,
        $fileCommentLength,
        $self->{'diskNumberStart'},
        $self->{'internalFileAttributes'},
        $self->{'externalFileAttributes'},
        $self->{'localHeaderRelativeOffset'}
    ) = unpack( CENTRAL_DIRECTORY_FILE_HEADER_FORMAT, $header );

    $self->{'eocdCrc32'} = $self->{'crc32'};

    if ($fileNameLength) {
        $bytesRead = $fh->read( $self->{'fileName'}, $fileNameLength );
        if ( $bytesRead != $fileNameLength ) {
            _ioError("reading central dir filename");
        }
    }
    if ($extraFieldLength) {
        $bytesRead = $fh->read( $self->{'cdExtraField'}, $extraFieldLength );
        if ( $bytesRead != $extraFieldLength ) {
            return _ioError("reading central dir extra field");
        }
    }
    if ($fileCommentLength) {
        $bytesRead = $fh->read( $self->{'fileComment'}, $fileCommentLength );
        if ( $bytesRead != $fileCommentLength ) {
            return _ioError("reading central dir file comment");
        }
    }

    # NK 10/21/04: added to avoid problems with manipulated headers
    if (    $self->{'uncompressedSize'} != $self->{'compressedSize'}
        and $self->{'compressionMethod'} == COMPRESSION_STORED )
    {
        $self->{'uncompressedSize'} = $self->{'compressedSize'};
    }

    $self->desiredCompressionMethod( $self->compressionMethod() );

    return AZ_OK;
}

sub rewindData {
    my $self = shift;

    my $status = $self->SUPER::rewindData(@_);
    return $status unless $status == AZ_OK;

    return AZ_IO_ERROR unless $self->fh();

    $self->fh()->clearerr();

    # Seek to local file header.
    # The only reason that I'm doing this this way is that the extraField
    # length seems to be different between the CD header and the LF header.
    $status = $self->_seekToLocalHeader();
    return $status unless $status == AZ_OK;

    # skip local file header
    $status = $self->_skipLocalFileHeader();
    return $status unless $status == AZ_OK;

    # Seek to beginning of file data
    $self->fh()->seek( $self->dataOffset(), IO::Seekable::SEEK_SET )
      or return _ioError("seeking to beginning of file data");

    return AZ_OK;
}

# Return bytes read. Note that first parameter is a ref to a buffer.
# my $data;
# my ( $bytesRead, $status) = $self->readRawChunk( \$data, $chunkSize );
sub _readRawChunk {
    my ( $self, $dataRef, $chunkSize ) = @_;
    return ( 0, AZ_OK ) unless $chunkSize;
    my $bytesRead = $self->fh()->read( $$dataRef, $chunkSize )
      or return ( 0, _ioError("reading data") );
    return ( $bytesRead, AZ_OK );
}

1;
FILE   1b647806/Compress/Zlib.pm  =##line 1 "/home/danny/perl5/lib/perl5/Compress/Zlib.pm"

package Compress::Zlib;

require 5.006 ;
require Exporter;
use Carp ;
use IO::Handle ;
use Scalar::Util qw(dualvar);

use IO::Compress::Base::Common 2.055 ;
use Compress::Raw::Zlib 2.055 ;
use IO::Compress::Gzip 2.055 ;
use IO::Uncompress::Gunzip 2.055 ;

use strict ;
use warnings ;
use bytes ;
our ($VERSION, $XS_VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

$VERSION = '2.055';
$XS_VERSION = $VERSION; 
$VERSION = eval $VERSION;

@ISA = qw(Exporter);
# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.
@EXPORT = qw(
        deflateInit inflateInit

        compress uncompress

        gzopen $gzerrno
    );

push @EXPORT, @Compress::Raw::Zlib::EXPORT ;

@EXPORT_OK = qw(memGunzip memGzip zlib_version);
%EXPORT_TAGS = (
    ALL         => \@EXPORT
);

BEGIN
{
    *zlib_version = \&Compress::Raw::Zlib::zlib_version;
}

use constant FLAG_APPEND             => 1 ;
use constant FLAG_CRC                => 2 ;
use constant FLAG_ADLER              => 4 ;
use constant FLAG_CONSUME_INPUT      => 8 ;

our (@my_z_errmsg);

@my_z_errmsg = (
    "need dictionary",     # Z_NEED_DICT     2
    "stream end",          # Z_STREAM_END    1
    "",                    # Z_OK            0
    "file error",          # Z_ERRNO        (-1)
    "stream error",        # Z_STREAM_ERROR (-2)
    "data error",          # Z_DATA_ERROR   (-3)
    "insufficient memory", # Z_MEM_ERROR    (-4)
    "buffer error",        # Z_BUF_ERROR    (-5)
    "incompatible version",# Z_VERSION_ERROR(-6)
    );


sub _set_gzerr
{
    my $value = shift ;

    if ($value == 0) {
        $Compress::Zlib::gzerrno = 0 ;
    }
    elsif ($value == Z_ERRNO() || $value > 2) {
        $Compress::Zlib::gzerrno = $! ;
    }
    else {
        $Compress::Zlib::gzerrno = dualvar($value+0, $my_z_errmsg[2 - $value]);
    }

    return $value ;
}

sub _set_gzerr_undef
{
    _set_gzerr(@_);
    return undef;
}

sub _save_gzerr
{
    my $gz = shift ;
    my $test_eof = shift ;

    my $value = $gz->errorNo() || 0 ;
    my $eof = $gz->eof() ;

    if ($test_eof) {
        # gzread uses Z_STREAM_END to denote a successful end
        $value = Z_STREAM_END() if $gz->eof() && $value == 0 ;
    }

    _set_gzerr($value) ;
}

sub gzopen($$)
{
    my ($file, $mode) = @_ ;

    my $gz ;
    my %defOpts = (Level    => Z_DEFAULT_COMPRESSION(),
                   Strategy => Z_DEFAULT_STRATEGY(),
                  );

    my $writing ;
    $writing = ! ($mode =~ /r/i) ;
    $writing = ($mode =~ /[wa]/i) ;

    $defOpts{Level}    = $1               if $mode =~ /(\d)/;
    $defOpts{Strategy} = Z_FILTERED()     if $mode =~ /f/i;
    $defOpts{Strategy} = Z_HUFFMAN_ONLY() if $mode =~ /h/i;
    $defOpts{Append}   = 1                if $mode =~ /a/i;

    my $infDef = $writing ? 'deflate' : 'inflate';
    my @params = () ;

    croak "gzopen: file parameter is not a filehandle or filename"
        unless isaFilehandle $file || isaFilename $file  || 
               (ref $file && ref $file eq 'SCALAR');

    return undef unless $mode =~ /[rwa]/i ;

    _set_gzerr(0) ;

    if ($writing) {
        $gz = new IO::Compress::Gzip($file, Minimal => 1, AutoClose => 1, 
                                     %defOpts) 
            or $Compress::Zlib::gzerrno = $IO::Compress::Gzip::GzipError;
    }
    else {
        $gz = new IO::Uncompress::Gunzip($file, 
                                         Transparent => 1,
                                         Append => 0, 
                                         AutoClose => 1, 
                                         MultiStream => 1,
                                         Strict => 0) 
            or $Compress::Zlib::gzerrno = $IO::Uncompress::Gunzip::GunzipError;
    }

    return undef
        if ! defined $gz ;

    bless [$gz, $infDef], 'Compress::Zlib::gzFile';
}

sub Compress::Zlib::gzFile::gzread
{
    my $self = shift ;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'inflate';

    my $len = defined $_[1] ? $_[1] : 4096 ; 

    my $gz = $self->[0] ;
    if ($self->gzeof() || $len == 0) {
        # Zap the output buffer to match ver 1 behaviour.
        $_[0] = "" ;
        _save_gzerr($gz, 1);
        return 0 ;
    }

    my $status = $gz->read($_[0], $len) ; 
    _save_gzerr($gz, 1);
    return $status ;
}

sub Compress::Zlib::gzFile::gzreadline
{
    my $self = shift ;

    my $gz = $self->[0] ;
    {
        # Maintain backward compatibility with 1.x behaviour
        # It didn't support $/, so this can't either.
        local $/ = "\n" ;
        $_[0] = $gz->getline() ; 
    }
    _save_gzerr($gz, 1);
    return defined $_[0] ? length $_[0] : 0 ;
}

sub Compress::Zlib::gzFile::gzwrite
{
    my $self = shift ;
    my $gz = $self->[0] ;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'deflate';

    $] >= 5.008 and (utf8::downgrade($_[0], 1) 
        or croak "Wide character in gzwrite");

    my $status = $gz->write($_[0]) ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gztell
{
    my $self = shift ;
    my $gz = $self->[0] ;
    my $status = $gz->tell() ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzseek
{
    my $self   = shift ;
    my $offset = shift ;
    my $whence = shift ;

    my $gz = $self->[0] ;
    my $status ;
    eval { $status = $gz->seek($offset, $whence) ; };
    if ($@)
    {
        my $error = $@;
        $error =~ s/^.*: /gzseek: /;
        $error =~ s/ at .* line \d+\s*$//;
        croak $error;
    }
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzflush
{
    my $self = shift ;
    my $f    = shift ;

    my $gz = $self->[0] ;
    my $status = $gz->flush($f) ;
    my $err = _save_gzerr($gz);
    return $status ? 0 : $err;
}

sub Compress::Zlib::gzFile::gzclose
{
    my $self = shift ;
    my $gz = $self->[0] ;

    my $status = $gz->close() ;
    my $err = _save_gzerr($gz);
    return $status ? 0 : $err;
}

sub Compress::Zlib::gzFile::gzeof
{
    my $self = shift ;
    my $gz = $self->[0] ;

    return 0
        if $self->[1] ne 'inflate';

    my $status = $gz->eof() ;
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzsetparams
{
    my $self = shift ;
    croak "Usage: Compress::Zlib::gzFile::gzsetparams(file, level, strategy)"
        unless @_ eq 2 ;

    my $gz = $self->[0] ;
    my $level = shift ;
    my $strategy = shift;

    return _set_gzerr(Z_STREAM_ERROR())
        if $self->[1] ne 'deflate';
 
    my $status = *$gz->{Compress}->deflateParams(-Level   => $level, 
                                                -Strategy => $strategy);
    _save_gzerr($gz);
    return $status ;
}

sub Compress::Zlib::gzFile::gzerror
{
    my $self = shift ;
    my $gz = $self->[0] ;
    
    return $Compress::Zlib::gzerrno ;
}


sub compress($;$)
{
    my ($x, $output, $err, $in) =('', '', '', '') ;

    if (ref $_[0] ) {
        $in = $_[0] ;
        croak "not a scalar reference" unless ref $in eq 'SCALAR' ;
    }
    else {
        $in = \$_[0] ;
    }

    $] >= 5.008 and (utf8::downgrade($$in, 1) 
        or croak "Wide character in compress");

    my $level = (@_ == 2 ? $_[1] : Z_DEFAULT_COMPRESSION() );

    $x = Compress::Raw::Zlib::_deflateInit(FLAG_APPEND,
                                           $level,
                                           Z_DEFLATED,
                                           MAX_WBITS,
                                           MAX_MEM_LEVEL,
                                           Z_DEFAULT_STRATEGY,
                                           4096,
                                           '') 
            or return undef ;

    $err = $x->deflate($in, $output) ;
    return undef unless $err == Z_OK() ;

    $err = $x->flush($output) ;
    return undef unless $err == Z_OK() ;
    
    return $output ;
}

sub uncompress($)
{
    my ($output, $in) =('', '') ;

    if (ref $_[0] ) {
        $in = $_[0] ;
        croak "not a scalar reference" unless ref $in eq 'SCALAR' ;
    }
    else {
        $in = \$_[0] ;
    }

    $] >= 5.008 and (utf8::downgrade($$in, 1) 
        or croak "Wide character in uncompress");    
        
    my ($obj, $status) = Compress::Raw::Zlib::_inflateInit(0,
                                MAX_WBITS, 4096, "") ;   
                                
    $status == Z_OK 
        or return undef;
    
    $obj->inflate($in, $output) == Z_STREAM_END 
        or return undef;
    
    return $output;
}
 
sub deflateInit(@)
{
    my ($got) = ParseParameters(0,
                {
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                'Level'         => [1, 1, Parse_signed,   Z_DEFAULT_COMPRESSION()],
                'Method'        => [1, 1, Parse_unsigned, Z_DEFLATED()],
                'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                'MemLevel'      => [1, 1, Parse_unsigned, MAX_MEM_LEVEL()],
                'Strategy'      => [1, 1, Parse_unsigned, Z_DEFAULT_STRATEGY()],
                'Dictionary'    => [1, 1, Parse_any,      ""],
                }, @_ ) ;

    croak "Compress::Zlib::deflateInit: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $obj ;
 
    my $status = 0 ;
    ($obj, $status) = 
      Compress::Raw::Zlib::_deflateInit(0,
                $got->value('Level'), 
                $got->value('Method'), 
                $got->value('WindowBits'), 
                $got->value('MemLevel'), 
                $got->value('Strategy'), 
                $got->value('Bufsize'),
                $got->value('Dictionary')) ;

    my $x = ($status == Z_OK() ? bless $obj, "Zlib::OldDeflate"  : undef) ;
    return wantarray ? ($x, $status) : $x ;
}
 
sub inflateInit(@)
{
    my ($got) = ParseParameters(0,
                {
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                'Dictionary'    => [1, 1, Parse_any,      ""],
                }, @_) ;


    croak "Compress::Zlib::inflateInit: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $status = 0 ;
    my $obj ;
    ($obj, $status) = Compress::Raw::Zlib::_inflateInit(FLAG_CONSUME_INPUT,
                                $got->value('WindowBits'), 
                                $got->value('Bufsize'), 
                                $got->value('Dictionary')) ;

    my $x = ($status == Z_OK() ? bless $obj, "Zlib::OldInflate"  : undef) ;

    wantarray ? ($x, $status) : $x ;
}

package Zlib::OldDeflate ;

our (@ISA);
@ISA = qw(Compress::Raw::Zlib::deflateStream);


sub deflate
{
    my $self = shift ;
    my $output ;

    my $status = $self->SUPER::deflate($_[0], $output) ;
    wantarray ? ($output, $status) : $output ;
}

sub flush
{
    my $self = shift ;
    my $output ;
    my $flag = shift || Compress::Zlib::Z_FINISH();
    my $status = $self->SUPER::flush($output, $flag) ;
    
    wantarray ? ($output, $status) : $output ;
}

package Zlib::OldInflate ;

our (@ISA);
@ISA = qw(Compress::Raw::Zlib::inflateStream);

sub inflate
{
    my $self = shift ;
    my $output ;
    my $status = $self->SUPER::inflate($_[0], $output) ;
    wantarray ? ($output, $status) : $output ;
}

package Compress::Zlib ;

use IO::Compress::Gzip::Constants 2.055 ;

sub memGzip($)
{
    _set_gzerr(0);
    my $x = Compress::Raw::Zlib::_deflateInit(FLAG_APPEND|FLAG_CRC,
                                           Z_BEST_COMPRESSION,
                                           Z_DEFLATED,
                                           -MAX_WBITS(),
                                           MAX_MEM_LEVEL,
                                           Z_DEFAULT_STRATEGY,
                                           4096,
                                           '') 
            or return undef ;
 
    # if the deflation buffer isn't a reference, make it one
    my $string = (ref $_[0] ? $_[0] : \$_[0]) ;

    $] >= 5.008 and (utf8::downgrade($$string, 1) 
        or croak "Wide character in memGzip");

    my $out;
    my $status ;

    $x->deflate($string, $out) == Z_OK
        or return undef ;
 
    $x->flush($out) == Z_OK
        or return undef ;
 
    return IO::Compress::Gzip::Constants::GZIP_MINIMUM_HEADER . 
           $out . 
           pack("V V", $x->crc32(), $x->total_in());
}


sub _removeGzipHeader($)
{
    my $string = shift ;

    return Z_DATA_ERROR() 
        if length($$string) < GZIP_MIN_HEADER_SIZE ;

    my ($magic1, $magic2, $method, $flags, $time, $xflags, $oscode) = 
        unpack ('CCCCVCC', $$string);

    return Z_DATA_ERROR()
        unless $magic1 == GZIP_ID1 and $magic2 == GZIP_ID2 and
           $method == Z_DEFLATED() and !($flags & GZIP_FLG_RESERVED) ;
    substr($$string, 0, GZIP_MIN_HEADER_SIZE) = '' ;

    # skip extra field
    if ($flags & GZIP_FLG_FEXTRA)
    {
        return Z_DATA_ERROR()
            if length($$string) < GZIP_FEXTRA_HEADER_SIZE ;

        my ($extra_len) = unpack ('v', $$string);
        $extra_len += GZIP_FEXTRA_HEADER_SIZE;
        return Z_DATA_ERROR()
            if length($$string) < $extra_len ;

        substr($$string, 0, $extra_len) = '';
    }

    # skip orig name
    if ($flags & GZIP_FLG_FNAME)
    {
        my $name_end = index ($$string, GZIP_NULL_BYTE);
        return Z_DATA_ERROR()
           if $name_end == -1 ;
        substr($$string, 0, $name_end + 1) =  '';
    }

    # skip comment
    if ($flags & GZIP_FLG_FCOMMENT)
    {
        my $comment_end = index ($$string, GZIP_NULL_BYTE);
        return Z_DATA_ERROR()
            if $comment_end == -1 ;
        substr($$string, 0, $comment_end + 1) = '';
    }

    # skip header crc
    if ($flags & GZIP_FLG_FHCRC)
    {
        return Z_DATA_ERROR()
            if length ($$string) < GZIP_FHCRC_SIZE ;
        substr($$string, 0, GZIP_FHCRC_SIZE) = '';
    }
    
    return Z_OK();
}

sub _ret_gun_error
{
    $Compress::Zlib::gzerrno = $IO::Uncompress::Gunzip::GunzipError;
    return undef;
}


sub memGunzip($)
{
    # if the buffer isn't a reference, make it one
    my $string = (ref $_[0] ? $_[0] : \$_[0]);
 
    $] >= 5.008 and (utf8::downgrade($$string, 1) 
        or croak "Wide character in memGunzip");

    _set_gzerr(0);

    my $status = _removeGzipHeader($string) ;
    $status == Z_OK() 
        or return _set_gzerr_undef($status);
     
    my $bufsize = length $$string > 4096 ? length $$string : 4096 ;
    my $x = Compress::Raw::Zlib::_inflateInit(FLAG_CRC | FLAG_CONSUME_INPUT,
                                -MAX_WBITS(), $bufsize, '') 
              or return _ret_gun_error();

    my $output = '' ;
    $status = $x->inflate($string, $output);
    
    if ( $status == Z_OK() )
    {
        _set_gzerr(Z_DATA_ERROR());
        return undef;
    }

    return _ret_gun_error()
        if ($status != Z_STREAM_END());

    if (length $$string >= 8)
    {
        my ($crc, $len) = unpack ("VV", substr($$string, 0, 8));
        substr($$string, 0, 8) = '';
        return _set_gzerr_undef(Z_DATA_ERROR())
            unless $len == length($output) and
                   $crc == Compress::Raw::Zlib::crc32($output);
    }
    else
    {
        $$string = '';
    }

    return $output;   
}

# Autoload methods go after __END__, and are processed by the autosplit program.

1;
__END__


#line 1507
FILE   6a945c1c/File/GlobMapper.pm  �#line 1 "/home/danny/perl5/lib/perl5/File/GlobMapper.pm"
package File::GlobMapper;

use strict;
use warnings;
use Carp;

our ($CSH_GLOB);

BEGIN
{
    if ($] < 5.006)
    { 
        require File::BSDGlob; import File::BSDGlob qw(:glob) ;
        $CSH_GLOB = File::BSDGlob::GLOB_CSH() ;
        *globber = \&File::BSDGlob::csh_glob;
    }  
    else
    { 
        require File::Glob; import File::Glob qw(:glob) ;
        $CSH_GLOB = File::Glob::GLOB_CSH() ;
        #*globber = \&File::Glob::bsd_glob;
        *globber = \&File::Glob::csh_glob;
    }  
}

our ($Error);

our ($VERSION, @EXPORT_OK);
$VERSION = '1.000';
@EXPORT_OK = qw( globmap );


our ($noPreBS, $metachars, $matchMetaRE, %mapping, %wildCount);
$noPreBS = '(?<!\\\)' ; # no preceding backslash
$metachars = '.*?[](){}';
$matchMetaRE = '[' . quotemeta($metachars) . ']';

%mapping = (
                '*' => '([^/]*)',
                '?' => '([^/])',
                '.' => '\.',
                '[' => '([',
                '(' => '(',
                ')' => ')',
           );

%wildCount = map { $_ => 1 } qw/ * ? . { ( [ /;           

sub globmap ($$;)
{
    my $inputGlob = shift ;
    my $outputGlob = shift ;

    my $obj = new File::GlobMapper($inputGlob, $outputGlob, @_)
        or croak "globmap: $Error" ;
    return $obj->getFileMap();
}

sub new
{
    my $class = shift ;
    my $inputGlob = shift ;
    my $outputGlob = shift ;
    # TODO -- flags needs to default to whatever File::Glob does
    my $flags = shift || $CSH_GLOB ;
    #my $flags = shift ;

    $inputGlob =~ s/^\s*\<\s*//;
    $inputGlob =~ s/\s*\>\s*$//;

    $outputGlob =~ s/^\s*\<\s*//;
    $outputGlob =~ s/\s*\>\s*$//;

    my %object =
            (   InputGlob   => $inputGlob,
                OutputGlob  => $outputGlob,
                GlobFlags   => $flags,
                Braces      => 0,
                WildCount   => 0,
                Pairs       => [],
                Sigil       => '#',
            );

    my $self = bless \%object, ref($class) || $class ;

    $self->_parseInputGlob()
        or return undef ;

    $self->_parseOutputGlob()
        or return undef ;
    
    my @inputFiles = globber($self->{InputGlob}, $flags) ;

    if (GLOB_ERROR)
    {
        $Error = $!;
        return undef ;
    }

    #if (whatever)
    {
        my $missing = grep { ! -e $_ } @inputFiles ;

        if ($missing)
        {
            $Error = "$missing input files do not exist";
            return undef ;
        }
    }

    $self->{InputFiles} = \@inputFiles ;

    $self->_getFiles()
        or return undef ;

    return $self;
}

sub _retError
{
    my $string = shift ;
    $Error = "$string in input fileglob" ;
    return undef ;
}

sub _unmatched
{
    my $delimeter = shift ;

    _retError("Unmatched $delimeter");
    return undef ;
}

sub _parseBit
{
    my $self = shift ;

    my $string = shift ;

    my $out = '';
    my $depth = 0 ;

    while ($string =~ s/(.*?)$noPreBS(,|$matchMetaRE)//)
    {
        $out .= quotemeta($1) ;
        $out .= $mapping{$2} if defined $mapping{$2};

        ++ $self->{WildCount} if $wildCount{$2} ;

        if ($2 eq ',')
        { 
            return _unmatched "("
                if $depth ;
            
            $out .= '|';
        }
        elsif ($2 eq '(')
        { 
            ++ $depth ;
        }
        elsif ($2 eq ')')
        { 
            return _unmatched ")"
                if ! $depth ;

            -- $depth ;
        }
        elsif ($2 eq '[')
        {
            # TODO -- quotemeta & check no '/'
            # TODO -- check for \]  & other \ within the []
            $string =~ s#(.*?\])##
                or return _unmatched "[" ;
            $out .= "$1)" ;
        }
        elsif ($2 eq ']')
        {
            return _unmatched "]" ;
        }
        elsif ($2 eq '{' || $2 eq '}')
        {
            return _retError "Nested {} not allowed" ;
        }
    }

    $out .= quotemeta $string;

    return _unmatched "("
        if $depth ;

    return $out ;
}

sub _parseInputGlob
{
    my $self = shift ;

    my $string = $self->{InputGlob} ;
    my $inGlob = '';

    # Multiple concatenated *'s don't make sense
    #$string =~ s#\*\*+#*# ;

    # TODO -- Allow space to delimit patterns?
    #my @strings = split /\s+/, $string ;
    #for my $str (@strings)
    my $out = '';
    my $depth = 0 ;

    while ($string =~ s/(.*?)$noPreBS($matchMetaRE)//)
    {
        $out .= quotemeta($1) ;
        $out .= $mapping{$2} if defined $mapping{$2};
        ++ $self->{WildCount} if $wildCount{$2} ;

        if ($2 eq '(')
        { 
            ++ $depth ;
        }
        elsif ($2 eq ')')
        { 
            return _unmatched ")"
                if ! $depth ;

            -- $depth ;
        }
        elsif ($2 eq '[')
        {
            # TODO -- quotemeta & check no '/' or '(' or ')'
            # TODO -- check for \]  & other \ within the []
            $string =~ s#(.*?\])##
                or return _unmatched "[";
            $out .= "$1)" ;
        }
        elsif ($2 eq ']')
        {
            return _unmatched "]" ;
        }
        elsif ($2 eq '}')
        {
            return _unmatched "}" ;
        }
        elsif ($2 eq '{')
        {
            # TODO -- check no '/' within the {}
            # TODO -- check for \}  & other \ within the {}

            my $tmp ;
            unless ( $string =~ s/(.*?)$noPreBS\}//)
            {
                return _unmatched "{";
            }
            #$string =~ s#(.*?)\}##;

            #my $alt = join '|', 
            #          map { quotemeta $_ } 
            #          split "$noPreBS,", $1 ;
            my $alt = $self->_parseBit($1);
            defined $alt or return 0 ;
            $out .= "($alt)" ;

            ++ $self->{Braces} ;
        }
    }

    return _unmatched "("
        if $depth ;

    $out .= quotemeta $string ;


    $self->{InputGlob} =~ s/$noPreBS[\(\)]//g;
    $self->{InputPattern} = $out ;

    #print "# INPUT '$self->{InputGlob}' => '$out'\n";

    return 1 ;

}

sub _parseOutputGlob
{
    my $self = shift ;

    my $string = $self->{OutputGlob} ;
    my $maxwild = $self->{WildCount};

    if ($self->{GlobFlags} & GLOB_TILDE)
    #if (1)
    {
        $string =~ s{
              ^ ~             # find a leading tilde
              (               # save this in $1
                  [^/]        # a non-slash character
                        *     # repeated 0 or more times (0 means me)
              )
            }{
              $1
                  ? (getpwnam($1))[7]
                  : ( $ENV{HOME} || $ENV{LOGDIR} )
            }ex;

    }

    # max #1 must be == to max no of '*' in input
    while ( $string =~ m/#(\d)/g )
    {
        croak "Max wild is #$maxwild, you tried #$1"
            if $1 > $maxwild ;
    }

    my $noPreBS = '(?<!\\\)' ; # no preceding backslash
    #warn "noPreBS = '$noPreBS'\n";

    #$string =~ s/${noPreBS}\$(\d)/\${$1}/g;
    $string =~ s/${noPreBS}#(\d)/\${$1}/g;
    $string =~ s#${noPreBS}\*#\${inFile}#g;
    $string = '"' . $string . '"';

    #print "OUTPUT '$self->{OutputGlob}' => '$string'\n";
    $self->{OutputPattern} = $string ;

    return 1 ;
}

sub _getFiles
{
    my $self = shift ;

    my %outInMapping = ();
    my %inFiles = () ;

    foreach my $inFile (@{ $self->{InputFiles} })
    {
        next if $inFiles{$inFile} ++ ;

        my $outFile = $inFile ;

        if ( $inFile =~ m/$self->{InputPattern}/ )
        {
            no warnings 'uninitialized';
            eval "\$outFile = $self->{OutputPattern};" ;

            if (defined $outInMapping{$outFile})
            {
                $Error =  "multiple input files map to one output file";
                return undef ;
            }
            $outInMapping{$outFile} = $inFile;
            push @{ $self->{Pairs} }, [$inFile, $outFile];
        }
    }

    return 1 ;
}

sub getFileMap
{
    my $self = shift ;

    return $self->{Pairs} ;
}

sub getHash
{
    my $self = shift ;

    return { map { $_->[0] => $_->[1] } @{ $self->{Pairs} } } ;
}

1;

__END__

#line 680FILE   '8c6fd3be/IO/Compress/Adapter/Deflate.pm  �#line 1 "/home/danny/perl5/lib/perl5/IO/Compress/Adapter/Deflate.pm"
package IO::Compress::Adapter::Deflate ;

use strict;
use warnings;
use bytes;

use IO::Compress::Base::Common 2.055 qw(:Status);
use Compress::Raw::Zlib  2.055 qw( !crc32 !adler32 ) ;
                                  
require Exporter;                                     
our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, @EXPORT, %DEFLATE_CONSTANTS);

$VERSION = '2.055';
@ISA = qw(Exporter);
@EXPORT_OK = @Compress::Raw::Zlib::DEFLATE_CONSTANTS;
%EXPORT_TAGS = %Compress::Raw::Zlib::DEFLATE_CONSTANTS;
@EXPORT = @EXPORT_OK;
%DEFLATE_CONSTANTS = %EXPORT_TAGS ;

sub mkCompObject
{
    my $crc32    = shift ;
    my $adler32  = shift ;
    my $level    = shift ;
    my $strategy = shift ;

    my ($def, $status) = new Compress::Raw::Zlib::Deflate
                                -AppendOutput   => 1,
                                -CRC32          => $crc32,
                                -ADLER32        => $adler32,
                                -Level          => $level,
                                -Strategy       => $strategy,
                                -WindowBits     => - MAX_WBITS;

    return (undef, "Cannot create Deflate object: $status", $status) 
        if $status != Z_OK;    

    return bless {'Def'        => $def,
                  'Error'      => '',
                 } ;     
}

sub compr
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflate($_[0], $_[1]) ;
    $self->{ErrorNo} = $status;

    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;    
}

sub flush
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $opt = $_[1] || Z_FINISH;
    my $status = $def->flush($_[0], $opt);
    $self->{ErrorNo} = $status;

    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;    
    
}

sub close
{
    my $self = shift ;

    my $def   = $self->{Def};

    $def->flush($_[0], Z_FINISH)
        if defined $def ;
}

sub reset
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflateReset() ;
    $self->{ErrorNo} = $status;
    if ($status != Z_OK)
    {
        $self->{Error} = "Deflate Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;    
}

sub deflateParams 
{
    my $self = shift ;

    my $def   = $self->{Def};

    my $status = $def->deflateParams(@_);
    $self->{ErrorNo} = $status;
    if ($status != Z_OK)
    {
        $self->{Error} = "deflateParams Error: $status"; 
        return STATUS_ERROR;
    }

    return STATUS_OK;   
}



#sub total_out
#{
#    my $self = shift ;
#    $self->{Def}->total_out();
#}
#
#sub total_in
#{
#    my $self = shift ;
#    $self->{Def}->total_in();
#}

sub compressedBytes
{
    my $self = shift ;

    $self->{Def}->compressedBytes();
}

sub uncompressedBytes
{
    my $self = shift ;
    $self->{Def}->uncompressedBytes();
}




sub crc32
{
    my $self = shift ;
    $self->{Def}->crc32();
}

sub adler32
{
    my $self = shift ;
    $self->{Def}->adler32();
}


1;

__END__

FILE   2212502d/IO/Compress/Base.pm  T
#line 1 "/home/danny/perl5/lib/perl5/IO/Compress/Base.pm"

package IO::Compress::Base ;

require 5.006 ;

use strict ;
use warnings;

use IO::Compress::Base::Common 2.055 ;

use IO::File qw(SEEK_SET SEEK_END); ;
use Scalar::Util qw(blessed readonly);

#use File::Glob;
#require Exporter ;
use Carp() ;
use Symbol();
use bytes;

our (@ISA, $VERSION);
@ISA    = qw(Exporter IO::File);

$VERSION = '2.055';

#Can't locate object method "SWASHNEW" via package "utf8" (perhaps you forgot to load "utf8"?) at .../ext/Compress-Zlib/Gzip/blib/lib/Compress/Zlib/Common.pm line 16.

sub saveStatus
{
    my $self   = shift ;
    ${ *$self->{ErrorNo} } = shift() + 0 ;
    ${ *$self->{Error} } = '' ;

    return ${ *$self->{ErrorNo} } ;
}


sub saveErrorString
{
    my $self   = shift ;
    my $retval = shift ;
    ${ *$self->{Error} } = shift ;
    ${ *$self->{ErrorNo} } = shift() + 0 if @_ ;

    return $retval;
}

sub croakError
{
    my $self   = shift ;
    $self->saveErrorString(0, $_[0]);
    Carp::croak $_[0];
}

sub closeError
{
    my $self = shift ;
    my $retval = shift ;

    my $errno = *$self->{ErrorNo};
    my $error = ${ *$self->{Error} };

    $self->close();

    *$self->{ErrorNo} = $errno ;
    ${ *$self->{Error} } = $error ;

    return $retval;
}



sub error
{
    my $self   = shift ;
    return ${ *$self->{Error} } ;
}

sub errorNo
{
    my $self   = shift ;
    return ${ *$self->{ErrorNo} } ;
}


sub writeAt
{
    my $self = shift ;
    my $offset = shift;
    my $data = shift;

    if (defined *$self->{FH}) {
        my $here = tell(*$self->{FH});
        return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) 
            if $here < 0 ;
        seek(*$self->{FH}, $offset, SEEK_SET)
            or return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;
        defined *$self->{FH}->write($data, length $data)
            or return $self->saveErrorString(undef, $!, $!) ;
        seek(*$self->{FH}, $here, SEEK_SET)
            or return $self->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;
    }
    else {
        substr(${ *$self->{Buffer} }, $offset, length($data)) = $data ;
    }

    return 1;
}

sub outputPayload
{

    my $self = shift ;
    return $self->output(@_);
}


sub output
{
    my $self = shift ;
    my $data = shift ;
    my $last = shift ;

    return 1 
        if length $data == 0 && ! $last ;

    if ( *$self->{FilterContainer} ) {
        *_ = \$data;
        &{ *$self->{FilterContainer} }();
    }

    if (length $data) {
        if ( defined *$self->{FH} ) {
                defined *$self->{FH}->write( $data, length $data )
                or return $self->saveErrorString(0, $!, $!); 
        }
        else {
                ${ *$self->{Buffer} } .= $data ;
        }
    }

    return 1;
}

sub getOneShotParams
{
    return ( 'MultiStream' => [1, 1, Parse_boolean,   1],
           );
}

sub checkParams
{
    my $self = shift ;
    my $class = shift ;

    my $got = shift || IO::Compress::Base::Parameters::new();

    $got->parse(
        {
            # Generic Parameters
            'AutoClose' => [1, 1, Parse_boolean,   0],
            #'Encode'    => [1, 1, Parse_any,       undef],
            'Strict'    => [0, 1, Parse_boolean,   1],
            'Append'    => [1, 1, Parse_boolean,   0],
            'BinModeIn' => [1, 1, Parse_boolean,   0],

            'FilterContainer' => [1, 1, Parse_code,  undef],

            $self->getExtraParams(),
            *$self->{OneShot} ? $self->getOneShotParams() 
                              : (),
        }, 
        @_) or $self->croakError("${class}: $got->{Error}")  ;

    return $got ;
}

sub _create
{
    my $obj = shift;
    my $got = shift;

    *$obj->{Closed} = 1 ;

    my $class = ref $obj;
    $obj->croakError("$class: Missing Output parameter")
        if ! @_ && ! $got ;

    my $outValue = shift ;
    my $oneShot = 1 ;

    if (! $got)
    {
        $oneShot = 0 ;
        $got = $obj->checkParams($class, undef, @_)
            or return undef ;
    }

    my $lax = ! $got->value('Strict') ;

    my $outType = whatIsOutput($outValue);

    $obj->ckOutputParam($class, $outValue)
        or return undef ;

    if ($outType eq 'buffer') {
        *$obj->{Buffer} = $outValue;
    }
    else {
        my $buff = "" ;
        *$obj->{Buffer} = \$buff ;
    }

    # Merge implies Append
    my $merge = $got->value('Merge') ;
    my $appendOutput = $got->value('Append') || $merge ;
    *$obj->{Append} = $appendOutput;
    *$obj->{FilterContainer} = $got->value('FilterContainer') ;

    if ($merge)
    {
        # Switch off Merge mode if output file/buffer is empty/doesn't exist
        if (($outType eq 'buffer' && length $$outValue == 0 ) ||
            ($outType ne 'buffer' && (! -e $outValue || (-w _ && -z _))) )
          { $merge = 0 }
    }

    # If output is a file, check that it is writable
    #no warnings;
    #if ($outType eq 'filename' && -e $outValue && ! -w _)
    #  { return $obj->saveErrorString(undef, "Output file '$outValue' is not writable" ) }



    if ($got->parsed('Encode')) { 
        my $want_encoding = $got->value('Encode');
        *$obj->{Encoding} = getEncoding($obj, $class, $want_encoding);
    }

    $obj->ckParams($got)
        or $obj->croakError("${class}: " . $obj->error());


    $obj->saveStatus(STATUS_OK) ;

    my $status ;
    if (! $merge)
    {
        *$obj->{Compress} = $obj->mkComp($got)
            or return undef;
        
        *$obj->{UnCompSize} = new U64 ;
        *$obj->{CompSize} = new U64 ;

        if ( $outType eq 'buffer') {
            ${ *$obj->{Buffer} }  = ''
                unless $appendOutput ;
        }
        else {
            if ($outType eq 'handle') {
                *$obj->{FH} = $outValue ;
                setBinModeOutput(*$obj->{FH}) ;
                $outValue->flush() ;
                *$obj->{Handle} = 1 ;
                if ($appendOutput)
                {
                    seek(*$obj->{FH}, 0, SEEK_END)
                        or return $obj->saveErrorString(undef, "Cannot seek to end of output filehandle: $!", $!) ;

                }
            }
            elsif ($outType eq 'filename') {    
                no warnings;
                my $mode = '>' ;
                $mode = '>>'
                    if $appendOutput;
                *$obj->{FH} = new IO::File "$mode $outValue" 
                    or return $obj->saveErrorString(undef, "cannot open file '$outValue': $!", $!) ;
                *$obj->{StdIO} = ($outValue eq '-'); 
                setBinModeOutput(*$obj->{FH}) ;
            }
        }

        *$obj->{Header} = $obj->mkHeader($got) ;
        $obj->output( *$obj->{Header} )
            or return undef;
        $obj->beforePayload();
    }
    else
    {
        *$obj->{Compress} = $obj->createMerge($outValue, $outType)
            or return undef;
    }

    *$obj->{Closed} = 0 ;
    *$obj->{AutoClose} = $got->value('AutoClose') ;
    *$obj->{Output} = $outValue;
    *$obj->{ClassName} = $class;
    *$obj->{Got} = $got;
    *$obj->{OneShot} = 0 ;

    return $obj ;
}

sub ckOutputParam 
{
    my $self = shift ;
    my $from = shift ;
    my $outType = whatIsOutput($_[0]);

    $self->croakError("$from: output parameter not a filename, filehandle or scalar ref")
        if ! $outType ;

    #$self->croakError("$from: output filename is undef or null string")
        #if $outType eq 'filename' && (! defined $_[0] || $_[0] eq '')  ;

    $self->croakError("$from: output buffer is read-only")
        if $outType eq 'buffer' && readonly(${ $_[0] });
    
    return 1;    
}


sub _def
{
    my $obj = shift ;
    
    my $class= (caller)[0] ;
    my $name = (caller(1))[3] ;

    $obj->croakError("$name: expected at least 1 parameters\n")
        unless @_ >= 1 ;

    my $input = shift ;
    my $haveOut = @_ ;
    my $output = shift ;

    my $x = new IO::Compress::Base::Validator($class, *$obj->{Error}, $name, $input, $output)
        or return undef ;

    push @_, $output if $haveOut && $x->{Hash};

    *$obj->{OneShot} = 1 ;

    my $got = $obj->checkParams($name, undef, @_)
        or return undef ;

    $x->{Got} = $got ;

#    if ($x->{Hash})
#    {
#        while (my($k, $v) = each %$input)
#        {
#            $v = \$input->{$k} 
#                unless defined $v ;
#
#            $obj->_singleTarget($x, 1, $k, $v, @_)
#                or return undef ;
#        }
#
#        return keys %$input ;
#    }

    if ($x->{GlobMap})
    {
        $x->{oneInput} = 1 ;
        foreach my $pair (@{ $x->{Pairs} })
        {
            my ($from, $to) = @$pair ;
            $obj->_singleTarget($x, 1, $from, $to, @_)
                or return undef ;
        }

        return scalar @{ $x->{Pairs} } ;
    }

    if (! $x->{oneOutput} )
    {
        my $inFile = ($x->{inType} eq 'filenames' 
                        || $x->{inType} eq 'filename');

        $x->{inType} = $inFile ? 'filename' : 'buffer';
        
        foreach my $in ($x->{oneInput} ? $input : @$input)
        {
            my $out ;
            $x->{oneInput} = 1 ;

            $obj->_singleTarget($x, $inFile, $in, \$out, @_)
                or return undef ;

            push @$output, \$out ;
            #if ($x->{outType} eq 'array')
            #  { push @$output, \$out }
            #else
            #  { $output->{$in} = \$out }
        }

        return 1 ;
    }

    # finally the 1 to 1 and n to 1
    return $obj->_singleTarget($x, 1, $input, $output, @_);

    Carp::croak "should not be here" ;
}

sub _singleTarget
{
    my $obj             = shift ;
    my $x               = shift ;
    my $inputIsFilename = shift;
    my $input           = shift;
    
    if ($x->{oneInput})
    {
        $obj->getFileInfo($x->{Got}, $input)
            if isaScalar($input) || (isaFilename($input) and $inputIsFilename) ;

        my $z = $obj->_create($x->{Got}, @_)
            or return undef ;


        defined $z->_wr2($input, $inputIsFilename) 
            or return $z->closeError(undef) ;

        return $z->close() ;
    }
    else
    {
        my $afterFirst = 0 ;
        my $inputIsFilename = ($x->{inType} ne 'array');
        my $keep = $x->{Got}->clone();

        #for my $element ( ($x->{inType} eq 'hash') ? keys %$input : @$input)
        for my $element ( @$input)
        {
            my $isFilename = isaFilename($element);

            if ( $afterFirst ++ )
            {
                defined addInterStream($obj, $element, $isFilename)
                    or return $obj->closeError(undef) ;
            }
            else
            {
                $obj->getFileInfo($x->{Got}, $element)
                    if isaScalar($element) || $isFilename;

                $obj->_create($x->{Got}, @_)
                    or return undef ;
            }

            defined $obj->_wr2($element, $isFilename) 
                or return $obj->closeError(undef) ;

            *$obj->{Got} = $keep->clone();
        }
        return $obj->close() ;
    }

}

sub _wr2
{
    my $self = shift ;

    my $source = shift ;
    my $inputIsFilename = shift;

    my $input = $source ;
    if (! $inputIsFilename)
    {
        $input = \$source 
            if ! ref $source;
    }

    if ( ref $input && ref $input eq 'SCALAR' )
    {
        return $self->syswrite($input, @_) ;
    }

    if ( ! ref $input  || isaFilehandle($input))
    {
        my $isFilehandle = isaFilehandle($input) ;

        my $fh = $input ;

        if ( ! $isFilehandle )
        {
            $fh = new IO::File "<$input"
                or return $self->saveErrorString(undef, "cannot open file '$input': $!", $!) ;
        }
        binmode $fh if *$self->{Got}->valueOrDefault('BinModeIn') ;

        my $status ;
        my $buff ;
        my $count = 0 ;
        while ($status = read($fh, $buff, 16 * 1024)) {
            $count += length $buff;
            defined $self->syswrite($buff, @_) 
                or return undef ;
        }

        return $self->saveErrorString(undef, $!, $!) 
            if ! defined $status ;

        if ( (!$isFilehandle || *$self->{AutoClose}) && $input ne '-')
        {    
            $fh->close() 
                or return undef ;
        }

        return $count ;
    }

    Carp::croak "Should not be here";
    return undef;
}

sub addInterStream
{
    my $self = shift ;
    my $input = shift ;
    my $inputIsFilename = shift ;

    if (*$self->{Got}->value('MultiStream'))
    {
        $self->getFileInfo(*$self->{Got}, $input)
            #if isaFilename($input) and $inputIsFilename ;
            if isaScalar($input) || isaFilename($input) ;

        # TODO -- newStream needs to allow gzip/zip header to be modified
        return $self->newStream();
    }
    elsif (*$self->{Got}->value('AutoFlush'))
    {
        #return $self->flush(Z_FULL_FLUSH);
    }

    return 1 ;
}

sub getFileInfo
{
}

sub TIEHANDLE
{
    return $_[0] if ref($_[0]);
    die "OOPS\n" ;
}
  
sub UNTIE
{
    my $self = shift ;
}

sub DESTROY
{
    my $self = shift ;
    local ($., $@, $!, $^E, $?);
    
    $self->close() ;

    # TODO - memory leak with 5.8.0 - this isn't called until 
    #        global destruction
    #
    %{ *$self } = () ;
    undef $self ;
}



sub filterUncompressed
{
}

sub syswrite
{
    my $self = shift ;

    my $buffer ;
    if (ref $_[0] ) {
        $self->croakError( *$self->{ClassName} . "::write: not a scalar reference" )
            unless ref $_[0] eq 'SCALAR' ;
        $buffer = $_[0] ;
    }
    else {
        $buffer = \$_[0] ;
    }

    $] >= 5.008 and ( utf8::downgrade($$buffer, 1) 
        or Carp::croak "Wide character in " .  *$self->{ClassName} . "::write:");


    if (@_ > 1) {
        my $slen = defined $$buffer ? length($$buffer) : 0;
        my $len = $slen;
        my $offset = 0;
        $len = $_[1] if $_[1] < $len;

        if (@_ > 2) {
            $offset = $_[2] || 0;
            $self->croakError(*$self->{ClassName} . "::write: offset outside string") 
                if $offset > $slen;
            if ($offset < 0) {
                $offset += $slen;
                $self->croakError( *$self->{ClassName} . "::write: offset outside string") if $offset < 0;
            }
            my $rem = $slen - $offset;
            $len = $rem if $rem < $len;
        }

        $buffer = \substr($$buffer, $offset, $len) ;
    }

    return 0 if ! defined $$buffer || length $$buffer == 0 ;

    if (*$self->{Encoding}) {
        $$buffer = *$self->{Encoding}->encode($$buffer);
    }

    $self->filterUncompressed($buffer);

    my $buffer_length = defined $$buffer ? length($$buffer) : 0 ;
    *$self->{UnCompSize}->add($buffer_length) ;

    my $outBuffer='';
    my $status = *$self->{Compress}->compr($buffer, $outBuffer) ;

    return $self->saveErrorString(undef, *$self->{Compress}{Error}, 
                                         *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    *$self->{CompSize}->add(length $outBuffer) ;

    $self->outputPayload($outBuffer)
        or return undef;

    return $buffer_length;
}

sub print
{
    my $self = shift;

    #if (ref $self) {
    #    $self = *$self{GLOB} ;
    #}

    if (defined $\) {
        if (defined $,) {
            defined $self->syswrite(join($,, @_) . $\);
        } else {
            defined $self->syswrite(join("", @_) . $\);
        }
    } else {
        if (defined $,) {
            defined $self->syswrite(join($,, @_));
        } else {
            defined $self->syswrite(join("", @_));
        }
    }
}

sub printf
{
    my $self = shift;
    my $fmt = shift;
    defined $self->syswrite(sprintf($fmt, @_));
}



sub flush
{
    my $self = shift ;

    my $outBuffer='';
    my $status = *$self->{Compress}->flush($outBuffer, @_) ;
    return $self->saveErrorString(0, *$self->{Compress}{Error}, 
                                    *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    if ( defined *$self->{FH} ) {
        *$self->{FH}->clearerr();
    }

    *$self->{CompSize}->add(length $outBuffer) ;

    $self->outputPayload($outBuffer)
        or return 0;

    if ( defined *$self->{FH} ) {
        defined *$self->{FH}->flush()
            or return $self->saveErrorString(0, $!, $!); 
    }

    return 1;
}

sub beforePayload
{
}

sub _newStream
{
    my $self = shift ;
    my $got  = shift;

    $self->_writeTrailer()
        or return 0 ;

    $self->ckParams($got)
        or $self->croakError("newStream: $self->{Error}");

    *$self->{Compress} = $self->mkComp($got)
        or return 0;

    *$self->{Header} = $self->mkHeader($got) ;
    $self->output(*$self->{Header} )
        or return 0;
    
    *$self->{UnCompSize}->reset();
    *$self->{CompSize}->reset();

    $self->beforePayload();

    return 1 ;
}

sub newStream
{
    my $self = shift ;
  
    my $got = $self->checkParams('newStream', *$self->{Got}, @_)
        or return 0 ;    

    $self->_newStream($got);

#    *$self->{Compress} = $self->mkComp($got)
#        or return 0;
#
#    *$self->{Header} = $self->mkHeader($got) ;
#    $self->output(*$self->{Header} )
#        or return 0;
#    
#    *$self->{UnCompSize}->reset();
#    *$self->{CompSize}->reset();
#
#    $self->beforePayload();
#
#    return 1 ;
}

sub reset
{
    my $self = shift ;
    return *$self->{Compress}->reset() ;
}

sub _writeTrailer
{
    my $self = shift ;

    my $trailer = '';

    my $status = *$self->{Compress}->close($trailer) ;
    return $self->saveErrorString(0, *$self->{Compress}{Error}, *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    *$self->{CompSize}->add(length $trailer) ;

    $trailer .= $self->mkTrailer();
    defined $trailer
      or return 0;

    return $self->output($trailer);
}

sub _writeFinalTrailer
{
    my $self = shift ;

    return $self->output($self->mkFinalTrailer());
}

sub close
{
    my $self = shift ;

    return 1 if *$self->{Closed} || ! *$self->{Compress} ;
    *$self->{Closed} = 1 ;

    untie *$self 
        if $] >= 5.008 ;

    $self->_writeTrailer()
        or return 0 ;

    $self->_writeFinalTrailer()
        or return 0 ;

    $self->output( "", 1 )
        or return 0;

    if (defined *$self->{FH}) {

        #if (! *$self->{Handle} || *$self->{AutoClose}) {
        if ((! *$self->{Handle} || *$self->{AutoClose}) && ! *$self->{StdIO}) {
            $! = 0 ;
            *$self->{FH}->close()
                or return $self->saveErrorString(0, $!, $!); 
        }
        delete *$self->{FH} ;
        # This delete can set $! in older Perls, so reset the errno
        $! = 0 ;
    }

    return 1;
}


#sub total_in
#sub total_out
#sub msg
#
#sub crc
#{
#    my $self = shift ;
#    return *$self->{Compress}->crc32() ;
#}
#
#sub msg
#{
#    my $self = shift ;
#    return *$self->{Compress}->msg() ;
#}
#
#sub dict_adler
#{
#    my $self = shift ;
#    return *$self->{Compress}->dict_adler() ;
#}
#
#sub get_Level
#{
#    my $self = shift ;
#    return *$self->{Compress}->get_Level() ;
#}
#
#sub get_Strategy
#{
#    my $self = shift ;
#    return *$self->{Compress}->get_Strategy() ;
#}


sub tell
{
    my $self = shift ;

    return *$self->{UnCompSize}->get32bit() ;
}

sub eof
{
    my $self = shift ;

    return *$self->{Closed} ;
}


sub seek
{
    my $self     = shift ;
    my $position = shift;
    my $whence   = shift ;

    my $here = $self->tell() ;
    my $target = 0 ;

    #use IO::Handle qw(SEEK_SET SEEK_CUR SEEK_END);
    use IO::Handle ;

    if ($whence == IO::Handle::SEEK_SET) {
        $target = $position ;
    }
    elsif ($whence == IO::Handle::SEEK_CUR || $whence == IO::Handle::SEEK_END) {
        $target = $here + $position ;
    }
    else {
        $self->croakError(*$self->{ClassName} . "::seek: unknown value, $whence, for whence parameter");
    }

    # short circuit if seeking to current offset
    return 1 if $target == $here ;    

    # Outlaw any attempt to seek backwards
    $self->croakError(*$self->{ClassName} . "::seek: cannot seek backwards")
        if $target < $here ;

    # Walk the file to the new offset
    my $offset = $target - $here ;

    my $buffer ;
    defined $self->syswrite("\x00" x $offset)
        or return 0;

    return 1 ;
}

sub binmode
{
    1;
#    my $self     = shift ;
#    return defined *$self->{FH} 
#            ? binmode *$self->{FH} 
#            : 1 ;
}

sub fileno
{
    my $self     = shift ;
    return defined *$self->{FH} 
            ? *$self->{FH}->fileno() 
            : undef ;
}

sub opened
{
    my $self     = shift ;
    return ! *$self->{Closed} ;
}

sub autoflush
{
    my $self     = shift ;
    return defined *$self->{FH} 
            ? *$self->{FH}->autoflush(@_) 
            : undef ;
}

sub input_line_number
{
    return undef ;
}


sub _notAvailable
{
    my $name = shift ;
    return sub { Carp::croak "$name Not Available: File opened only for output" ; } ;
}

*read     = _notAvailable('read');
*READ     = _notAvailable('read');
*readline = _notAvailable('readline');
*READLINE = _notAvailable('readline');
*getc     = _notAvailable('getc');
*GETC     = _notAvailable('getc');

*FILENO   = \&fileno;
*PRINT    = \&print;
*PRINTF   = \&printf;
*WRITE    = \&syswrite;
*write    = \&syswrite;
*SEEK     = \&seek; 
*TELL     = \&tell;
*EOF      = \&eof;
*CLOSE    = \&close;
*BINMODE  = \&binmode;

#*sysread  = \&_notAvailable;
#*syswrite = \&_write;

1; 

__END__

#line 1019
FILE   #a4453cca/IO/Compress/Base/Common.pm  \C#line 1 "/home/danny/perl5/lib/perl5/IO/Compress/Base/Common.pm"
package IO::Compress::Base::Common;

use strict ;
use warnings;
use bytes;

use Carp;
use Scalar::Util qw(blessed readonly);
use File::GlobMapper;

require Exporter;
our ($VERSION, @ISA, @EXPORT, %EXPORT_TAGS, $HAS_ENCODE);
@ISA = qw(Exporter);
$VERSION = '2.055';

@EXPORT = qw( isaFilehandle isaFilename isaScalar
              whatIsInput whatIsOutput 
              isaFileGlobString cleanFileGlobString oneTarget
              setBinModeInput setBinModeOutput
              ckInOutParams 
              createSelfTiedObject
              getEncoding

              isGeMax32

              MAX32

              WANT_CODE
              WANT_EXT
              WANT_UNDEF
              WANT_HASH

              STATUS_OK
              STATUS_ENDSTREAM
              STATUS_EOF
              STATUS_ERROR
          );  

%EXPORT_TAGS = ( Status => [qw( STATUS_OK
                                 STATUS_ENDSTREAM
                                 STATUS_EOF
                                 STATUS_ERROR
                           )]);

                       
use constant STATUS_OK        => 0;
use constant STATUS_ENDSTREAM => 1;
use constant STATUS_EOF       => 2;
use constant STATUS_ERROR     => -1;
use constant MAX16            => 0xFFFF ;  
use constant MAX32            => 0xFFFFFFFF ;  
use constant MAX32cmp         => 0xFFFFFFFF + 1 - 1; # for 5.6.x on 32-bit need to force an non-IV value 
          

sub isGeMax32
{
    return $_[0] >= MAX32cmp ;
}

sub hasEncode()
{
    if (! defined $HAS_ENCODE) {
        eval
        {
            require Encode;
            Encode->import();
        };

        $HAS_ENCODE = $@ ? 0 : 1 ;
    }

    return $HAS_ENCODE;
}

sub getEncoding($$$)
{
    my $obj = shift;
    my $class = shift ;
    my $want_encoding = shift ;

    $obj->croakError("$class: Encode module needed to use -Encode")
        if ! hasEncode();

    my $encoding = Encode::find_encoding($want_encoding);

    $obj->croakError("$class: Encoding '$want_encoding' is not available")
       if ! $encoding;

    return $encoding;
}

our ($needBinmode);
$needBinmode = ($^O eq 'MSWin32' || 
                    ($] >= 5.006 && eval ' ${^UNICODE} || ${^UTF8LOCALE} '))
                    ? 1 : 1 ;

sub setBinModeInput($)
{
    my $handle = shift ;

    binmode $handle 
        if  $needBinmode;
}

sub setBinModeOutput($)
{
    my $handle = shift ;

    binmode $handle 
        if  $needBinmode;
}

sub isaFilehandle($)
{
    use utf8; # Pragma needed to keep Perl 5.6.0 happy
    return (defined $_[0] and 
             (UNIVERSAL::isa($_[0],'GLOB') or 
              UNIVERSAL::isa($_[0],'IO::Handle') or
              UNIVERSAL::isa(\$_[0],'GLOB')) 
          )
}

sub isaScalar
{
    return ( defined($_[0]) and ref($_[0]) eq 'SCALAR' and defined ${ $_[0] } ) ;
}

sub isaFilename($)
{
    return (defined $_[0] and 
           ! ref $_[0]    and 
           UNIVERSAL::isa(\$_[0], 'SCALAR'));
}

sub isaFileGlobString
{
    return defined $_[0] && $_[0] =~ /^<.*>$/;
}

sub cleanFileGlobString
{
    my $string = shift ;

    $string =~ s/^\s*<\s*(.*)\s*>\s*$/$1/;

    return $string;
}

use constant WANT_CODE  => 1 ;
use constant WANT_EXT   => 2 ;
use constant WANT_UNDEF => 4 ;
#use constant WANT_HASH  => 8 ;
use constant WANT_HASH  => 0 ;

sub whatIsInput($;$)
{
    my $got = whatIs(@_);
    
    if (defined $got && $got eq 'filename' && defined $_[0] && $_[0] eq '-')
    {
        #use IO::File;
        $got = 'handle';
        $_[0] = *STDIN;
        #$_[0] = new IO::File("<-");
    }

    return $got;
}

sub whatIsOutput($;$)
{
    my $got = whatIs(@_);
    
    if (defined $got && $got eq 'filename' && defined $_[0] && $_[0] eq '-')
    {
        $got = 'handle';
        $_[0] = *STDOUT;
        #$_[0] = new IO::File(">-");
    }
    
    return $got;
}

sub whatIs ($;$)
{
    return 'handle' if isaFilehandle($_[0]);

    my $wantCode = defined $_[1] && $_[1] & WANT_CODE ;
    my $extended = defined $_[1] && $_[1] & WANT_EXT ;
    my $undef    = defined $_[1] && $_[1] & WANT_UNDEF ;
    my $hash     = defined $_[1] && $_[1] & WANT_HASH ;

    return 'undef'  if ! defined $_[0] && $undef ;

    if (ref $_[0]) {
        return ''       if blessed($_[0]); # is an object
        #return ''       if UNIVERSAL::isa($_[0], 'UNIVERSAL'); # is an object
        return 'buffer' if UNIVERSAL::isa($_[0], 'SCALAR');
        return 'array'  if UNIVERSAL::isa($_[0], 'ARRAY')  && $extended ;
        return 'hash'   if UNIVERSAL::isa($_[0], 'HASH')   && $hash ;
        return 'code'   if UNIVERSAL::isa($_[0], 'CODE')   && $wantCode ;
        return '';
    }

    return 'fileglob' if $extended && isaFileGlobString($_[0]);
    return 'filename';
}

sub oneTarget
{
    return $_[0] =~ /^(code|handle|buffer|filename)$/;
}

sub IO::Compress::Base::Validator::new
{
    my $class = shift ;

    my $Class = shift ;
    my $error_ref = shift ;
    my $reportClass = shift ;

    my %data = (Class       => $Class, 
                Error       => $error_ref,
                reportClass => $reportClass, 
               ) ;

    my $obj = bless \%data, $class ;

    local $Carp::CarpLevel = 1;

    my $inType    = $data{inType}    = whatIsInput($_[0], WANT_EXT|WANT_HASH);
    my $outType   = $data{outType}   = whatIsOutput($_[1], WANT_EXT|WANT_HASH);

    my $oneInput  = $data{oneInput}  = oneTarget($inType);
    my $oneOutput = $data{oneOutput} = oneTarget($outType);

    if (! $inType)
    {
        $obj->croakError("$reportClass: illegal input parameter") ;
        #return undef ;
    }    

#    if ($inType eq 'hash')
#    {
#        $obj->{Hash} = 1 ;
#        $obj->{oneInput} = 1 ;
#        return $obj->validateHash($_[0]);
#    }

    if (! $outType)
    {
        $obj->croakError("$reportClass: illegal output parameter") ;
        #return undef ;
    }    


    if ($inType ne 'fileglob' && $outType eq 'fileglob')
    {
        $obj->croakError("Need input fileglob for outout fileglob");
    }    

#    if ($inType ne 'fileglob' && $outType eq 'hash' && $inType ne 'filename' )
#    {
#        $obj->croakError("input must ne filename or fileglob when output is a hash");
#    }    

    if ($inType eq 'fileglob' && $outType eq 'fileglob')
    {
        $data{GlobMap} = 1 ;
        $data{inType} = $data{outType} = 'filename';
        my $mapper = new File::GlobMapper($_[0], $_[1]);
        if ( ! $mapper )
        {
            return $obj->saveErrorString($File::GlobMapper::Error) ;
        }
        $data{Pairs} = $mapper->getFileMap();

        return $obj;
    }
    
    $obj->croakError("$reportClass: input and output $inType are identical")
        if $inType eq $outType && $_[0] eq $_[1] && $_[0] ne '-' ;

    if ($inType eq 'fileglob') # && $outType ne 'fileglob'
    {
        my $glob = cleanFileGlobString($_[0]);
        my @inputs = glob($glob);

        if (@inputs == 0)
        {
            # TODO -- legal or die?
            die "globmap matched zero file -- legal or die???" ;
        }
        elsif (@inputs == 1)
        {
            $obj->validateInputFilenames($inputs[0])
                or return undef;
            $_[0] = $inputs[0]  ;
            $data{inType} = 'filename' ;
            $data{oneInput} = 1;
        }
        else
        {
            $obj->validateInputFilenames(@inputs)
                or return undef;
            $_[0] = [ @inputs ] ;
            $data{inType} = 'filenames' ;
        }
    }
    elsif ($inType eq 'filename')
    {
        $obj->validateInputFilenames($_[0])
            or return undef;
    }
    elsif ($inType eq 'array')
    {
        $data{inType} = 'filenames' ;
        $obj->validateInputArray($_[0])
            or return undef ;
    }

    return $obj->saveErrorString("$reportClass: output buffer is read-only")
        if $outType eq 'buffer' && readonly(${ $_[1] });

    if ($outType eq 'filename' )
    {
        $obj->croakError("$reportClass: output filename is undef or null string")
            if ! defined $_[1] || $_[1] eq ''  ;

        if (-e $_[1])
        {
            if (-d _ )
            {
                return $obj->saveErrorString("output file '$_[1]' is a directory");
            }
        }
    }
    
    return $obj ;
}

sub IO::Compress::Base::Validator::saveErrorString
{
    my $self   = shift ;
    ${ $self->{Error} } = shift ;
    return undef;
    
}

sub IO::Compress::Base::Validator::croakError
{
    my $self   = shift ;
    $self->saveErrorString($_[0]);
    croak $_[0];
}



sub IO::Compress::Base::Validator::validateInputFilenames
{
    my $self = shift ;

    foreach my $filename (@_)
    {
        $self->croakError("$self->{reportClass}: input filename is undef or null string")
            if ! defined $filename || $filename eq ''  ;

        next if $filename eq '-';

        if (! -e $filename )
        {
            return $self->saveErrorString("input file '$filename' does not exist");
        }

        if (-d _ )
        {
            return $self->saveErrorString("input file '$filename' is a directory");
        }

        if (! -r _ )
        {
            return $self->saveErrorString("cannot open file '$filename': $!");
        }
    }

    return 1 ;
}

sub IO::Compress::Base::Validator::validateInputArray
{
    my $self = shift ;

    if ( @{ $_[0] } == 0 )
    {
        return $self->saveErrorString("empty array reference") ;
    }    

    foreach my $element ( @{ $_[0] } )
    {
        my $inType  = whatIsInput($element);
    
        if (! $inType)
        {
            $self->croakError("unknown input parameter") ;
        }    
        elsif($inType eq 'filename')
        {
            $self->validateInputFilenames($element)
                or return undef ;
        }
        else
        {
            $self->croakError("not a filename") ;
        }
    }

    return 1 ;
}

#sub IO::Compress::Base::Validator::validateHash
#{
#    my $self = shift ;
#    my $href = shift ;
#
#    while (my($k, $v) = each %$href)
#    {
#        my $ktype = whatIsInput($k);
#        my $vtype = whatIsOutput($v, WANT_EXT|WANT_UNDEF) ;
#
#        if ($ktype ne 'filename')
#        {
#            return $self->saveErrorString("hash key not filename") ;
#        }    
#
#        my %valid = map { $_ => 1 } qw(filename buffer array undef handle) ;
#        if (! $valid{$vtype})
#        {
#            return $self->saveErrorString("hash value not ok") ;
#        }    
#    }
#
#    return $self ;
#}

sub createSelfTiedObject
{
    my $class = shift || (caller)[0] ;
    my $error_ref = shift ;

    my $obj = bless Symbol::gensym(), ref($class) || $class;
    tie *$obj, $obj if $] >= 5.005;
    *$obj->{Closed} = 1 ;
    $$error_ref = '';
    *$obj->{Error} = $error_ref ;
    my $errno = 0 ;
    *$obj->{ErrorNo} = \$errno ;

    return $obj;
}



#package Parse::Parameters ;
#
#
#require Exporter;
#our ($VERSION, @ISA, @EXPORT);
#$VERSION = '2.000_08';
#@ISA = qw(Exporter);

$EXPORT_TAGS{Parse} = [qw( ParseParameters 
                           Parse_any Parse_unsigned Parse_signed 
                           Parse_boolean Parse_string
                           Parse_code
                           Parse_multiple Parse_writable_scalar
                         )
                      ];              

push @EXPORT, @{ $EXPORT_TAGS{Parse} } ;

use constant Parse_any      => 0x01;
use constant Parse_unsigned => 0x02;
use constant Parse_signed   => 0x04;
use constant Parse_boolean  => 0x08;
use constant Parse_string   => 0x10;
use constant Parse_code     => 0x20;

#use constant Parse_store_ref        => 0x100 ;
use constant Parse_multiple         => 0x100 ;
use constant Parse_writable         => 0x200 ;
use constant Parse_writable_scalar  => 0x400 | Parse_writable ;

use constant OFF_PARSED     => 0 ;
use constant OFF_TYPE       => 1 ;
use constant OFF_DEFAULT    => 2 ;
use constant OFF_FIXED      => 3 ;
use constant OFF_FIRST_ONLY => 4 ;
use constant OFF_STICKY     => 5 ;



sub ParseParameters
{
    my $level = shift || 0 ; 

    my $sub = (caller($level + 1))[3] ;
    local $Carp::CarpLevel = 1 ;
    
    return $_[1]
        if @_ == 2 && defined $_[1] && UNIVERSAL::isa($_[1], "IO::Compress::Base::Parameters");
    
    my $p = new IO::Compress::Base::Parameters() ;            
    $p->parse(@_)
        or croak "$sub: $p->{Error}" ;

    return $p;
}

#package IO::Compress::Base::Parameters;

use strict;

use warnings;
use Carp;

sub IO::Compress::Base::Parameters::new
{
    my $class = shift ;

    my $obj = { Error => '',
                Got   => {},
              } ;

    #return bless $obj, ref($class) || $class || __PACKAGE__ ;
    return bless $obj, 'IO::Compress::Base::Parameters' ;
}

sub IO::Compress::Base::Parameters::setError
{
    my $self = shift ;
    my $error = shift ;
    my $retval = @_ ? shift : undef ;

    $self->{Error} = $error ;
    return $retval;
}
          
#sub getError
#{
#    my $self = shift ;
#    return $self->{Error} ;
#}
          
sub IO::Compress::Base::Parameters::parse
{
    my $self = shift ;

    my $default = shift ;

    my $got = $self->{Got} ;
    my $firstTime = keys %{ $got } == 0 ;
    my $other;

    my (@Bad) ;
    my @entered = () ;

    # Allow the options to be passed as a hash reference or
    # as the complete hash.
    if (@_ == 0) {
        @entered = () ;
    }
    elsif (@_ == 1) {
        my $href = $_[0] ;
    
        return $self->setError("Expected even number of parameters, got 1")
            if ! defined $href or ! ref $href or ref $href ne "HASH" ;
 
        foreach my $key (keys %$href) {
            push @entered, $key ;
            push @entered, \$href->{$key} ;
        }
    }
    else {
        my $count = @_;
        return $self->setError("Expected even number of parameters, got $count")
            if $count % 2 != 0 ;
        
        for my $i (0.. $count / 2 - 1) {
            if ($_[2 * $i] eq '__xxx__') {
                $other = $_[2 * $i + 1] ;
            }
            else {
                push @entered, $_[2 * $i] ;
                push @entered, \$_[2 * $i + 1] ;
            }
        }
    }


    while (my ($key, $v) = each %$default)
    {
        croak "need 4 params [@$v]"
            if @$v != 4 ;

        my ($first_only, $sticky, $type, $value) = @$v ;
        my $x ;
        $self->_checkType($key, \$value, $type, 0, \$x) 
            or return undef ;

        $key = lc $key;

        if ($firstTime || ! $sticky) {
            $x = []
                if $type & Parse_multiple;

            $got->{$key} = [0, $type, $value, $x, $first_only, $sticky] ;
        }

        $got->{$key}[OFF_PARSED] = 0 ;
    }

    my %parsed = ();
    
    if ($other) 
    {
        for my $key (keys %$default)  
        {
            my $canonkey = lc $key;
            if ($other->parsed($canonkey))
            {
                my $value = $other->value($canonkey);
#print "SET '$canonkey' to $value [$$value]\n";
                ++ $parsed{$canonkey};
                $got->{$canonkey}[OFF_PARSED]  = 1;
                $got->{$canonkey}[OFF_DEFAULT] = $value;
                $got->{$canonkey}[OFF_FIXED]   = $value;
            }
        }
    }
    
    for my $i (0.. @entered / 2 - 1) {
        my $key = $entered[2* $i] ;
        my $value = $entered[2* $i+1] ;

        #print "Key [$key] Value [$value]" ;
        #print defined $$value ? "[$$value]\n" : "[undef]\n";

        $key =~ s/^-// ;
        my $canonkey = lc $key;
 
        if ($got->{$canonkey} && ($firstTime ||
                                  ! $got->{$canonkey}[OFF_FIRST_ONLY]  ))
        {
            my $type = $got->{$canonkey}[OFF_TYPE] ;
            my $parsed = $parsed{$canonkey};
            ++ $parsed{$canonkey};

            return $self->setError("Muliple instances of '$key' found") 
                if $parsed && ($type & Parse_multiple) == 0 ;

            my $s ;
            $self->_checkType($key, $value, $type, 1, \$s)
                or return undef ;

            $value = $$value ;
            if ($type & Parse_multiple) {
                $got->{$canonkey}[OFF_PARSED] = 1;
                push @{ $got->{$canonkey}[OFF_FIXED] }, $s ;
            }
            else {
                $got->{$canonkey} = [1, $type, $value, $s] ;
            }
        }
        else
          { push (@Bad, $key) }
    }
 
    if (@Bad) {
        my ($bad) = join(", ", @Bad) ;
        return $self->setError("unknown key value(s) $bad") ;
    }

    return 1;
}

sub IO::Compress::Base::Parameters::_checkType
{
    my $self = shift ;

    my $key   = shift ;
    my $value = shift ;
    my $type  = shift ;
    my $validate  = shift ;
    my $output  = shift;

    #local $Carp::CarpLevel = $level ;
    #print "PARSE $type $key $value $validate $sub\n" ;

    if ($type & Parse_writable_scalar)
    {
        return $self->setError("Parameter '$key' not writable")
            if $validate &&  readonly $$value ;

        if (ref $$value) 
        {
            return $self->setError("Parameter '$key' not a scalar reference")
                if $validate &&  ref $$value ne 'SCALAR' ;

            $$output = $$value ;
        }
        else  
        {
            return $self->setError("Parameter '$key' not a scalar")
                if $validate &&  ref $value ne 'SCALAR' ;

            $$output = $value ;
        }

        return 1;
    }

#    if ($type & Parse_store_ref)
#    {
#        #$value = $$value
#        #    if ref ${ $value } ;
#
#        $$output = $value ;
#        return 1;
#    }

    $value = $$value ;

    if ($type & Parse_any)
    {
        $$output = $value ;
        return 1;
    }
    elsif ($type & Parse_unsigned)
    {
        return $self->setError("Parameter '$key' must be an unsigned int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be an unsigned int, got '$value'")
            if $validate && $value !~ /^\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1;
    }
    elsif ($type & Parse_signed)
    {
        return $self->setError("Parameter '$key' must be a signed int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be a signed int, got '$value'")
            if $validate && $value !~ /^-?\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1 ;
    }
    elsif ($type & Parse_boolean)
    {
        return $self->setError("Parameter '$key' must be an int, got '$value'")
            if $validate && defined $value && $value !~ /^\d*$/;
        $$output =  defined $value ? $value != 0 : 0 ;    
        return 1;
    }
    elsif ($type & Parse_code)
    {
        return $self->setError("Parameter '$key' must be a code reference, got '$value'")
            if $validate && (! defined $value || ref $value ne 'CODE') ;
        $$output = defined $value ? $value : "" ;    
        return 1;
    }
    elsif ($type & Parse_string)
    {
        $$output = defined $value ? $value : "" ;    
        return 1;
    }

    $$output = $value ;
    return 1;
}



sub IO::Compress::Base::Parameters::parsed
{
    my $self = shift ;
    my $name = shift ;

    return $self->{Got}{lc $name}[OFF_PARSED] ;
}

sub IO::Compress::Base::Parameters::value
{
    my $self = shift ;
    my $name = shift ;

    if (@_)
    {
        $self->{Got}{lc $name}[OFF_PARSED]  = 1;
        $self->{Got}{lc $name}[OFF_DEFAULT] = $_[0] ;
        $self->{Got}{lc $name}[OFF_FIXED]   = $_[0] ;
    }

    return $self->{Got}{lc $name}[OFF_FIXED] ;
}

sub IO::Compress::Base::Parameters::valueOrDefault
{
    my $self = shift ;
    my $name = shift ;
    my $default = shift ;

    my $value = $self->{Got}{lc $name}[OFF_DEFAULT] ;

    return $value if defined $value ;
    return $default ;
}

sub IO::Compress::Base::Parameters::wantValue
{
    my $self = shift ;
    my $name = shift ;

    return defined $self->{Got}{lc $name}[OFF_DEFAULT] ;

}

sub IO::Compress::Base::Parameters::clone
{
    my $self = shift ;
    my $obj = { };
    my %got ;

    while (my ($k, $v) = each %{ $self->{Got} }) {
        $got{$k} = [ @$v ];
    }

    $obj->{Error} = $self->{Error};
    $obj->{Got} = \%got ;

    return bless $obj, 'IO::Compress::Base::Parameters' ;
}

package U64;

use constant MAX32 => 0xFFFFFFFF ;
use constant HI_1 => MAX32 + 1 ;
use constant LOW   => 0 ;
use constant HIGH  => 1;

sub new
{
    my $class = shift ;

    my $high = 0 ;
    my $low  = 0 ;

    if (@_ == 2) {
        $high = shift ;
        $low  = shift ;
    }
    elsif (@_ == 1) {
        $low  = shift ;
    }

    bless [$low, $high], $class;
}

sub newUnpack_V64
{
    my $string = shift;

    my ($low, $hi) = unpack "V V", $string ;
    bless [ $low, $hi ], "U64";
}

sub newUnpack_V32
{
    my $string = shift;

    my $low = unpack "V", $string ;
    bless [ $low, 0 ], "U64";
}

sub reset
{
    my $self = shift;
    $self->[HIGH] = $self->[LOW] = 0;
}

sub clone
{
    my $self = shift;
    bless [ @$self ], ref $self ;
}

sub getHigh
{
    my $self = shift;
    return $self->[HIGH];
}

sub getLow
{
    my $self = shift;
    return $self->[LOW];
}

sub get32bit
{
    my $self = shift;
    return $self->[LOW];
}

sub get64bit
{
    my $self = shift;
    # Not using << here because the result will still be
    # a 32-bit value on systems where int size is 32-bits
    return $self->[HIGH] * HI_1 + $self->[LOW];
}

sub add
{
    my $self = shift;
    my $value = shift;

    if (ref $value eq 'U64') {
        $self->[HIGH] += $value->[HIGH] ;
        $value = $value->[LOW];
    }
    elsif ($value > MAX32) {      
        $self->[HIGH] += int($value / HI_1) ;
        $value = $value % HI_1;
    }
     
    my $available = MAX32 - $self->[LOW] ;
 
    if ($value > $available) {
       ++ $self->[HIGH] ;
       $self->[LOW] = $value - $available - 1;
    }
    else {
       $self->[LOW] += $value ;
    }
}

sub subtract
{
    my $self = shift;
    my $value = shift;

    if (ref $value eq 'U64') {

        if ($value->[HIGH]) {
            die "bad"
                if $self->[HIGH] == 0 ||
                   $value->[HIGH] > $self->[HIGH] ;

           $self->[HIGH] -= $value->[HIGH] ;
        }

        $value = $value->[LOW] ;
    }

    if ($value > $self->[LOW]) {
       -- $self->[HIGH] ;
       $self->[LOW] = MAX32 - $value + $self->[LOW] + 1 ;
    }
    else {
       $self->[LOW] -= $value;
    }
}

sub equal
{
    my $self = shift;
    my $other = shift;

    return $self->[LOW]  == $other->[LOW] &&
           $self->[HIGH] == $other->[HIGH] ;
}

sub gt
{
    my $self = shift;
    my $other = shift;

    return $self->cmp($other) > 0 ;
}

sub cmp
{
    my $self = shift;
    my $other = shift ;

    if ($self->[LOW] == $other->[LOW]) {
        return $self->[HIGH] - $other->[HIGH] ;
    }
    else {
        return $self->[LOW] - $other->[LOW] ;
    }
}
    

sub is64bit
{
    my $self = shift;
    return $self->[HIGH] > 0 ;
}

sub isAlmost64bit
{
    my $self = shift;
    return $self->[HIGH] > 0 ||  $self->[LOW] == MAX32 ;
}

sub getPacked_V64
{
    my $self = shift;

    return pack "V V", @$self ;
}

sub getPacked_V32
{
    my $self = shift;

    return pack "V", $self->[LOW] ;
}

sub pack_V64
{
    my $low  = shift;

    return pack "V V", $low, 0;
}


sub full32 
{
    return $_[0] == MAX32 ;
}

sub Value_VV64
{
    my $buffer = shift;

    my ($lo, $hi) = unpack ("V V" , $buffer);
    no warnings 'uninitialized';
    return $hi * HI_1 + $lo;
}


package IO::Compress::Base::Common;

1;
FILE   f2b6e8b6/IO/Compress/Gzip.pm  5#line 1 "/home/danny/perl5/lib/perl5/IO/Compress/Gzip.pm"
package IO::Compress::Gzip ;

require 5.006 ;

use strict ;
use warnings;
use bytes;

require Exporter ;

use IO::Compress::RawDeflate 2.055 () ; 
use IO::Compress::Adapter::Deflate 2.055 ;

use IO::Compress::Base::Common  2.055 qw(:Status :Parse isaScalar createSelfTiedObject);
use IO::Compress::Gzip::Constants 2.055 ;
use IO::Compress::Zlib::Extra 2.055 ;

BEGIN
{
    if (defined &utf8::downgrade ) 
      { *noUTF8 = \&utf8::downgrade }
    else
      { *noUTF8 = sub {} }  
}

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, %DEFLATE_CONSTANTS, $GzipError);

$VERSION = '2.055';
$GzipError = '' ;

@ISA    = qw(Exporter IO::Compress::RawDeflate);
@EXPORT_OK = qw( $GzipError gzip ) ;
%EXPORT_TAGS = %IO::Compress::RawDeflate::DEFLATE_CONSTANTS ;

push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
Exporter::export_ok_tags('all');

sub new
{
    my $class = shift ;

    my $obj = createSelfTiedObject($class, \$GzipError);

    $obj->_create(undef, @_);
}


sub gzip
{
    my $obj = createSelfTiedObject(undef, \$GzipError);
    return $obj->_def(@_);
}

#sub newHeader
#{
#    my $self = shift ;
#    #return GZIP_MINIMUM_HEADER ;
#    return $self->mkHeader(*$self->{Got});
#}

sub getExtraParams
{
    my $self = shift ;

    return (
            # zlib behaviour
            $self->getZlibParams(),

            # Gzip header fields
            'Minimal'   => [0, 1, Parse_boolean,   0],
            'Comment'   => [0, 1, Parse_any,       undef],
            'Name'      => [0, 1, Parse_any,       undef],
            'Time'      => [0, 1, Parse_any,       undef],
            'TextFlag'  => [0, 1, Parse_boolean,   0],
            'HeaderCRC' => [0, 1, Parse_boolean,   0],
            'OS_Code'   => [0, 1, Parse_unsigned,  $Compress::Raw::Zlib::gzip_os_code],
            'ExtraField'=> [0, 1, Parse_any,       undef],
            'ExtraFlags'=> [0, 1, Parse_any,       undef],

        );
}


sub ckParams
{
    my $self = shift ;
    my $got = shift ;

    # gzip always needs crc32
    $got->value('CRC32' => 1);

    return 1
        if $got->value('Merge') ;

    my $strict = $got->value('Strict') ;


    {
        if (! $got->parsed('Time') ) {
            # Modification time defaults to now.
            $got->value('Time' => time) ;
        }

        # Check that the Name & Comment don't have embedded NULLs
        # Also check that they only contain ISO 8859-1 chars.
        if ($got->parsed('Name') && defined $got->value('Name')) {
            my $name = $got->value('Name');
                
            return $self->saveErrorString(undef, "Null Character found in Name",
                                                Z_DATA_ERROR)
                if $strict && $name =~ /\x00/ ;

            return $self->saveErrorString(undef, "Non ISO 8859-1 Character found in Name",
                                                Z_DATA_ERROR)
                if $strict && $name =~ /$GZIP_FNAME_INVALID_CHAR_RE/o ;
        }

        if ($got->parsed('Comment') && defined $got->value('Comment')) {
            my $comment = $got->value('Comment');

            return $self->saveErrorString(undef, "Null Character found in Comment",
                                                Z_DATA_ERROR)
                if $strict && $comment =~ /\x00/ ;

            return $self->saveErrorString(undef, "Non ISO 8859-1 Character found in Comment",
                                                Z_DATA_ERROR)
                if $strict && $comment =~ /$GZIP_FCOMMENT_INVALID_CHAR_RE/o;
        }

        if ($got->parsed('OS_Code') ) {
            my $value = $got->value('OS_Code');

            return $self->saveErrorString(undef, "OS_Code must be between 0 and 255, got '$value'")
                if $value < 0 || $value > 255 ;
            
        }

        # gzip only supports Deflate at present
        $got->value('Method' => Z_DEFLATED) ;

        if ( ! $got->parsed('ExtraFlags')) {
            $got->value('ExtraFlags' => 2) 
                if $got->value('Level') == Z_BEST_COMPRESSION ;
            $got->value('ExtraFlags' => 4) 
                if $got->value('Level') == Z_BEST_SPEED ;
        }

        my $data = $got->value('ExtraField') ;
        if (defined $data) {
            my $bad = IO::Compress::Zlib::Extra::parseExtraField($data, $strict, 1) ;
            return $self->saveErrorString(undef, "Error with ExtraField Parameter: $bad", Z_DATA_ERROR)
                if $bad ;

            $got->value('ExtraField', $data) ;
        }
    }

    return 1;
}

sub mkTrailer
{
    my $self = shift ;
    return pack("V V", *$self->{Compress}->crc32(), 
                       *$self->{UnCompSize}->get32bit());
}

sub getInverseClass
{
    return ('IO::Uncompress::Gunzip',
                \$IO::Uncompress::Gunzip::GunzipError);
}

sub getFileInfo
{
    my $self = shift ;
    my $params = shift;
    my $filename = shift ;

    return if isaScalar($filename);

    my $defaultTime = (stat($filename))[9] ;

    $params->value('Name' => $filename)
        if ! $params->parsed('Name') ;

    $params->value('Time' => $defaultTime) 
        if ! $params->parsed('Time') ;
}


sub mkHeader
{
    my $self = shift ;
    my $param = shift ;

    # stort-circuit if a minimal header is requested.
    return GZIP_MINIMUM_HEADER if $param->value('Minimal') ;

    # METHOD
    my $method = $param->valueOrDefault('Method', GZIP_CM_DEFLATED) ;

    # FLAGS
    my $flags       = GZIP_FLG_DEFAULT ;
    $flags |= GZIP_FLG_FTEXT    if $param->value('TextFlag') ;
    $flags |= GZIP_FLG_FHCRC    if $param->value('HeaderCRC') ;
    $flags |= GZIP_FLG_FEXTRA   if $param->wantValue('ExtraField') ;
    $flags |= GZIP_FLG_FNAME    if $param->wantValue('Name') ;
    $flags |= GZIP_FLG_FCOMMENT if $param->wantValue('Comment') ;
    
    # MTIME
    my $time = $param->valueOrDefault('Time', GZIP_MTIME_DEFAULT) ;

    # EXTRA FLAGS
    my $extra_flags = $param->valueOrDefault('ExtraFlags', GZIP_XFL_DEFAULT);

    # OS CODE
    my $os_code = $param->valueOrDefault('OS_Code', GZIP_OS_DEFAULT) ;


    my $out = pack("C4 V C C", 
            GZIP_ID1,   # ID1
            GZIP_ID2,   # ID2
            $method,    # Compression Method
            $flags,     # Flags
            $time,      # Modification Time
            $extra_flags, # Extra Flags
            $os_code,   # Operating System Code
            ) ;

    # EXTRA
    if ($flags & GZIP_FLG_FEXTRA) {
        my $extra = $param->value('ExtraField') ;
        $out .= pack("v", length $extra) . $extra ;
    }

    # NAME
    if ($flags & GZIP_FLG_FNAME) {
        my $name .= $param->value('Name') ;
        $name =~ s/\x00.*$//;
        $out .= $name ;
        # Terminate the filename with NULL unless it already is
        $out .= GZIP_NULL_BYTE 
            if !length $name or
               substr($name, 1, -1) ne GZIP_NULL_BYTE ;
    }

    # COMMENT
    if ($flags & GZIP_FLG_FCOMMENT) {
        my $comment .= $param->value('Comment') ;
        $comment =~ s/\x00.*$//;
        $out .= $comment ;
        # Terminate the comment with NULL unless it already is
        $out .= GZIP_NULL_BYTE
            if ! length $comment or
               substr($comment, 1, -1) ne GZIP_NULL_BYTE;
    }

    # HEADER CRC
    $out .= pack("v", Compress::Raw::Zlib::crc32($out) & 0x00FF ) if $param->value('HeaderCRC') ;

    noUTF8($out);

    return $out ;
}

sub mkFinalTrailer
{
    return '';
}

1; 

__END__

#line 1242
FILE   &61af58d9/IO/Compress/Gzip/Constants.pm  �#line 1 "/home/danny/perl5/lib/perl5/IO/Compress/Gzip/Constants.pm"
package IO::Compress::Gzip::Constants;

use strict ;
use warnings;
use bytes;

require Exporter;

our ($VERSION, @ISA, @EXPORT, %GZIP_OS_Names);
our ($GZIP_FNAME_INVALID_CHAR_RE, $GZIP_FCOMMENT_INVALID_CHAR_RE);

$VERSION = '2.055';

@ISA = qw(Exporter);

@EXPORT= qw(

    GZIP_ID_SIZE
    GZIP_ID1
    GZIP_ID2

    GZIP_FLG_DEFAULT
    GZIP_FLG_FTEXT
    GZIP_FLG_FHCRC
    GZIP_FLG_FEXTRA
    GZIP_FLG_FNAME
    GZIP_FLG_FCOMMENT
    GZIP_FLG_RESERVED

    GZIP_CM_DEFLATED

    GZIP_MIN_HEADER_SIZE
    GZIP_TRAILER_SIZE

    GZIP_MTIME_DEFAULT
    GZIP_XFL_DEFAULT
    GZIP_FEXTRA_HEADER_SIZE
    GZIP_FEXTRA_MAX_SIZE
    GZIP_FEXTRA_SUBFIELD_HEADER_SIZE
    GZIP_FEXTRA_SUBFIELD_ID_SIZE
    GZIP_FEXTRA_SUBFIELD_LEN_SIZE
    GZIP_FEXTRA_SUBFIELD_MAX_SIZE

    $GZIP_FNAME_INVALID_CHAR_RE
    $GZIP_FCOMMENT_INVALID_CHAR_RE

    GZIP_FHCRC_SIZE

    GZIP_ISIZE_MAX
    GZIP_ISIZE_MOD_VALUE


    GZIP_NULL_BYTE

    GZIP_OS_DEFAULT

    %GZIP_OS_Names

    GZIP_MINIMUM_HEADER

    );

# Constant names derived from RFC 1952

use constant GZIP_ID_SIZE                     => 2 ;
use constant GZIP_ID1                         => 0x1F;
use constant GZIP_ID2                         => 0x8B;

use constant GZIP_MIN_HEADER_SIZE             => 10 ;# minimum gzip header size
use constant GZIP_TRAILER_SIZE                => 8 ;


use constant GZIP_FLG_DEFAULT                 => 0x00 ;
use constant GZIP_FLG_FTEXT                   => 0x01 ;
use constant GZIP_FLG_FHCRC                   => 0x02 ; # called CONTINUATION in gzip
use constant GZIP_FLG_FEXTRA                  => 0x04 ;
use constant GZIP_FLG_FNAME                   => 0x08 ;
use constant GZIP_FLG_FCOMMENT                => 0x10 ;
#use constant GZIP_FLG_ENCRYPTED              => 0x20 ; # documented in gzip sources
use constant GZIP_FLG_RESERVED                => (0x20 | 0x40 | 0x80) ;

use constant GZIP_XFL_DEFAULT                 => 0x00 ;

use constant GZIP_MTIME_DEFAULT               => 0x00 ;

use constant GZIP_FEXTRA_HEADER_SIZE          => 2 ;
use constant GZIP_FEXTRA_MAX_SIZE             => 0xFFFF ;
use constant GZIP_FEXTRA_SUBFIELD_ID_SIZE     => 2 ;
use constant GZIP_FEXTRA_SUBFIELD_LEN_SIZE    => 2 ;
use constant GZIP_FEXTRA_SUBFIELD_HEADER_SIZE => GZIP_FEXTRA_SUBFIELD_ID_SIZE +
                                                 GZIP_FEXTRA_SUBFIELD_LEN_SIZE;
use constant GZIP_FEXTRA_SUBFIELD_MAX_SIZE    => GZIP_FEXTRA_MAX_SIZE - 
                                                 GZIP_FEXTRA_SUBFIELD_HEADER_SIZE ;


if (ord('A') == 193)
{
    # EBCDIC 
    $GZIP_FNAME_INVALID_CHAR_RE = '[\x00-\x3f\xff]';
    $GZIP_FCOMMENT_INVALID_CHAR_RE = '[\x00-\x0a\x11-\x14\x16-\x3f\xff]';
    
}
else
{
    $GZIP_FNAME_INVALID_CHAR_RE       =  '[\x00-\x1F\x7F-\x9F]';
    $GZIP_FCOMMENT_INVALID_CHAR_RE    =  '[\x00-\x09\x11-\x1F\x7F-\x9F]';
}            

use constant GZIP_FHCRC_SIZE        => 2 ; # aka CONTINUATION in gzip

use constant GZIP_CM_DEFLATED       => 8 ;

use constant GZIP_NULL_BYTE         => "\x00";
use constant GZIP_ISIZE_MAX         => 0xFFFFFFFF ;
use constant GZIP_ISIZE_MOD_VALUE   => GZIP_ISIZE_MAX + 1 ;

# OS Names sourced from http://www.gzip.org/format.txt

use constant GZIP_OS_DEFAULT=> 0xFF ;
%GZIP_OS_Names = (
    0   => 'MS-DOS',
    1   => 'Amiga',
    2   => 'VMS',
    3   => 'Unix',
    4   => 'VM/CMS',
    5   => 'Atari TOS',
    6   => 'HPFS (OS/2, NT)',
    7   => 'Macintosh',
    8   => 'Z-System',
    9   => 'CP/M',
    10  => 'TOPS-20',
    11  => 'NTFS (NT)',
    12  => 'SMS QDOS',
    13  => 'Acorn RISCOS',
    14  => 'VFAT file system (Win95, NT)',
    15  => 'MVS',
    16  => 'BeOS',
    17  => 'Tandem/NSK',
    18  => 'THEOS',
    GZIP_OS_DEFAULT()   => 'Unknown',
    ) ;

use constant GZIP_MINIMUM_HEADER =>   pack("C4 V C C",  
        GZIP_ID1, GZIP_ID2, GZIP_CM_DEFLATED, GZIP_FLG_DEFAULT,
        GZIP_MTIME_DEFAULT, GZIP_XFL_DEFAULT, GZIP_OS_DEFAULT) ;


1;
FILE   "8f777c2a/IO/Compress/RawDeflate.pm  .#line 1 "/home/danny/perl5/lib/perl5/IO/Compress/RawDeflate.pm"
package IO::Compress::RawDeflate ;

# create RFC1951
#
use strict ;
use warnings;
use bytes;


use IO::Compress::Base 2.055 ;
use IO::Compress::Base::Common  2.055 qw(:Status createSelfTiedObject);
use IO::Compress::Adapter::Deflate 2.055 ;

require Exporter ;

our ($VERSION, @ISA, @EXPORT_OK, %DEFLATE_CONSTANTS, %EXPORT_TAGS, $RawDeflateError);

$VERSION = '2.055';
$RawDeflateError = '';

@ISA = qw(Exporter IO::Compress::Base);
@EXPORT_OK = qw( $RawDeflateError rawdeflate ) ;
push @EXPORT_OK, @IO::Compress::Adapter::Deflate::EXPORT_OK ;

%EXPORT_TAGS = %IO::Compress::Adapter::Deflate::DEFLATE_CONSTANTS;


{
    my %seen;
    foreach (keys %EXPORT_TAGS )
    {
        push @{$EXPORT_TAGS{constants}}, 
                 grep { !$seen{$_}++ } 
                 @{ $EXPORT_TAGS{$_} }
    }
    $EXPORT_TAGS{all} = $EXPORT_TAGS{constants} ;
}


%DEFLATE_CONSTANTS = %EXPORT_TAGS;

#push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;

Exporter::export_ok_tags('all');
              


sub new
{
    my $class = shift ;

    my $obj = createSelfTiedObject($class, \$RawDeflateError);

    return $obj->_create(undef, @_);
}

sub rawdeflate
{
    my $obj = createSelfTiedObject(undef, \$RawDeflateError);
    return $obj->_def(@_);
}

sub ckParams
{
    my $self = shift ;
    my $got = shift;

    return 1 ;
}

sub mkComp
{
    my $self = shift ;
    my $got = shift ;

    my ($obj, $errstr, $errno) = IO::Compress::Adapter::Deflate::mkCompObject(
                                                 $got->value('CRC32'),
                                                 $got->value('Adler32'),
                                                 $got->value('Level'),
                                                 $got->value('Strategy')
                                                 );

   return $self->saveErrorString(undef, $errstr, $errno)
       if ! defined $obj;

   return $obj;    
}


sub mkHeader
{
    my $self = shift ;
    return '';
}

sub mkTrailer
{
    my $self = shift ;
    return '';
}

sub mkFinalTrailer
{
    return '';
}


#sub newHeader
#{
#    my $self = shift ;
#    return '';
#}

sub getExtraParams
{
    my $self = shift ;
    return $self->getZlibParams();
}

sub getZlibParams
{
    my $self = shift ;

    use IO::Compress::Base::Common  2.055 qw(:Parse);
    use Compress::Raw::Zlib  2.055 qw(Z_DEFLATED Z_DEFAULT_COMPRESSION Z_DEFAULT_STRATEGY);

    
    return (
        
            # zlib behaviour
            #'Method'   => [0, 1, Parse_unsigned,  Z_DEFLATED],
            'Level'     => [0, 1, Parse_signed,    Z_DEFAULT_COMPRESSION],
            'Strategy'  => [0, 1, Parse_signed,    Z_DEFAULT_STRATEGY],

            'CRC32'     => [0, 1, Parse_boolean,   0],
            'ADLER32'   => [0, 1, Parse_boolean,   0],
            'Merge'     => [1, 1, Parse_boolean,   0],
        );
    
    
}

sub getInverseClass
{
    return ('IO::Uncompress::RawInflate', 
                \$IO::Uncompress::RawInflate::RawInflateError);
}

sub getFileInfo
{
    my $self = shift ;
    my $params = shift;
    my $file = shift ;
    
}

use IO::Seekable qw(SEEK_SET);

sub createMerge
{
    my $self = shift ;
    my $outValue = shift ;
    my $outType = shift ;

    my ($invClass, $error_ref) = $self->getInverseClass();
    eval "require $invClass" 
        or die "aaaahhhh" ;

    my $inf = $invClass->new( $outValue, 
                             Transparent => 0, 
                             #Strict     => 1,
                             AutoClose   => 0,
                             Scan        => 1)
       or return $self->saveErrorString(undef, "Cannot create InflateScan object: $$error_ref" ) ;

    my $end_offset = 0;
    $inf->scan() 
        or return $self->saveErrorString(undef, "Error Scanning: $$error_ref", $inf->errorNo) ;
    $inf->zap($end_offset) 
        or return $self->saveErrorString(undef, "Error Zapping: $$error_ref", $inf->errorNo) ;

    my $def = *$self->{Compress} = $inf->createDeflate();

    *$self->{Header} = *$inf->{Info}{Header};
    *$self->{UnCompSize} = *$inf->{UnCompSize}->clone();
    *$self->{CompSize} = *$inf->{CompSize}->clone();
    # TODO -- fix this
    #*$self->{CompSize} = new U64(0, *$self->{UnCompSize_32bit});


    if ( $outType eq 'buffer') 
      { substr( ${ *$self->{Buffer} }, $end_offset) = '' }
    elsif ($outType eq 'handle' || $outType eq 'filename') {
        *$self->{FH} = *$inf->{FH} ;
        delete *$inf->{FH};
        *$self->{FH}->flush() ;
        *$self->{Handle} = 1 if $outType eq 'handle';

        #seek(*$self->{FH}, $end_offset, SEEK_SET) 
        *$self->{FH}->seek($end_offset, SEEK_SET) 
            or return $self->saveErrorString(undef, $!, $!) ;
    }

    return $def ;
}

#### zlib specific methods

sub deflateParams 
{
    my $self = shift ;

    my $level = shift ;
    my $strategy = shift ;

    my $status = *$self->{Compress}->deflateParams(Level => $level, Strategy => $strategy) ;
    return $self->saveErrorString(0, *$self->{Compress}{Error}, *$self->{Compress}{ErrorNo})
        if $status == STATUS_ERROR;

    return 1;    
}




1;

__END__

#line 995
FILE   "c9a11868/IO/Compress/Zlib/Extra.pm  �#line 1 "/home/danny/perl5/lib/perl5/IO/Compress/Zlib/Extra.pm"
package IO::Compress::Zlib::Extra;

require 5.006 ;

use strict ;
use warnings;
use bytes;

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS);

$VERSION = '2.055';

use IO::Compress::Gzip::Constants 2.055 ;

sub ExtraFieldError
{
    return $_[0];
    return "Error with ExtraField Parameter: $_[0]" ;
}

sub validateExtraFieldPair
{
    my $pair = shift ;
    my $strict = shift;
    my $gzipMode = shift ;

    return ExtraFieldError("Not an array ref")
        unless ref $pair &&  ref $pair eq 'ARRAY';

    return ExtraFieldError("SubField must have two parts")
        unless @$pair == 2 ;

    return ExtraFieldError("SubField ID is a reference")
        if ref $pair->[0] ;

    return ExtraFieldError("SubField Data is a reference")
        if ref $pair->[1] ;

    # ID is exactly two chars   
    return ExtraFieldError("SubField ID not two chars long")
        unless length $pair->[0] == GZIP_FEXTRA_SUBFIELD_ID_SIZE ;

    # Check that the 2nd byte of the ID isn't 0    
    return ExtraFieldError("SubField ID 2nd byte is 0x00")
        if $strict && $gzipMode && substr($pair->[0], 1, 1) eq "\x00" ;

    return ExtraFieldError("SubField Data too long")
        if length $pair->[1] > GZIP_FEXTRA_SUBFIELD_MAX_SIZE ;


    return undef ;
}

sub parseRawExtra
{
    my $data     = shift ;
    my $extraRef = shift;
    my $strict   = shift;
    my $gzipMode = shift ;

    #my $lax = shift ;

    #return undef
    #    if $lax ;

    my $XLEN = length $data ;

    return ExtraFieldError("Too Large")
        if $XLEN > GZIP_FEXTRA_MAX_SIZE;

    my $offset = 0 ;
    while ($offset < $XLEN) {

        return ExtraFieldError("Truncated in FEXTRA Body Section")
            if $offset + GZIP_FEXTRA_SUBFIELD_HEADER_SIZE  > $XLEN ;

        my $id = substr($data, $offset, GZIP_FEXTRA_SUBFIELD_ID_SIZE);    
        $offset += GZIP_FEXTRA_SUBFIELD_ID_SIZE;

        my $subLen =  unpack("v", substr($data, $offset,
                                            GZIP_FEXTRA_SUBFIELD_LEN_SIZE));
        $offset += GZIP_FEXTRA_SUBFIELD_LEN_SIZE ;

        return ExtraFieldError("Truncated in FEXTRA Body Section")
            if $offset + $subLen > $XLEN ;

        my $bad = validateExtraFieldPair( [$id, 
                                           substr($data, $offset, $subLen)], 
                                           $strict, $gzipMode );
        return $bad if $bad ;
        push @$extraRef, [$id => substr($data, $offset, $subLen)]
            if defined $extraRef;;

        $offset += $subLen ;
    }

        
    return undef ;
}

sub findID
{
    my $id_want = shift ;
    my $data    = shift;

    my $XLEN = length $data ;

    my $offset = 0 ;
    while ($offset < $XLEN) {

        return undef
            if $offset + GZIP_FEXTRA_SUBFIELD_HEADER_SIZE  > $XLEN ;

        my $id = substr($data, $offset, GZIP_FEXTRA_SUBFIELD_ID_SIZE);    
        $offset += GZIP_FEXTRA_SUBFIELD_ID_SIZE;

        my $subLen =  unpack("v", substr($data, $offset,
                                            GZIP_FEXTRA_SUBFIELD_LEN_SIZE));
        $offset += GZIP_FEXTRA_SUBFIELD_LEN_SIZE ;

        return undef
            if $offset + $subLen > $XLEN ;

        return substr($data, $offset, $subLen)
            if $id eq $id_want ;

        $offset += $subLen ;
    }
        
    return undef ;
}


sub mkSubField
{
    my $id = shift ;
    my $data = shift ;

    return $id . pack("v", length $data) . $data ;
}

sub parseExtraField
{
    my $dataRef  = $_[0];
    my $strict   = $_[1];
    my $gzipMode = $_[2];
    #my $lax     = @_ == 2 ? $_[1] : 1;


    # ExtraField can be any of
    #
    #    -ExtraField => $data
    #
    #    -ExtraField => [$id1, $data1,
    #                    $id2, $data2]
    #                     ...
    #                   ]
    #
    #    -ExtraField => [ [$id1 => $data1],
    #                     [$id2 => $data2],
    #                     ...
    #                   ]
    #
    #    -ExtraField => { $id1 => $data1,
    #                     $id2 => $data2,
    #                     ...
    #                   }
    
    if ( ! ref $dataRef ) {

        return undef
            if ! $strict;

        return parseRawExtra($dataRef, undef, 1, $gzipMode);
    }

    my $data = $dataRef;
    my $out = '' ;

    if (ref $data eq 'ARRAY') {    
        if (ref $data->[0]) {

            foreach my $pair (@$data) {
                return ExtraFieldError("Not list of lists")
                    unless ref $pair eq 'ARRAY' ;

                my $bad = validateExtraFieldPair($pair, $strict, $gzipMode) ;
                return $bad if $bad ;

                $out .= mkSubField(@$pair);
            }   
        }   
        else {
            return ExtraFieldError("Not even number of elements")
                unless @$data % 2  == 0;

            for (my $ix = 0; $ix <= @$data -1 ; $ix += 2) {
                my $bad = validateExtraFieldPair([$data->[$ix],
                                                  $data->[$ix+1]], 
                                                 $strict, $gzipMode) ;
                return $bad if $bad ;

                $out .= mkSubField($data->[$ix], $data->[$ix+1]);
            }   
        }
    }   
    elsif (ref $data eq 'HASH') {    
        while (my ($id, $info) = each %$data) {
            my $bad = validateExtraFieldPair([$id, $info], $strict, $gzipMode);
            return $bad if $bad ;

            $out .= mkSubField($id, $info);
        }   
    }   
    else {
        return ExtraFieldError("Not a scalar, array ref or hash ref") ;
    }

    return ExtraFieldError("Too Large")
        if length $out > GZIP_FEXTRA_MAX_SIZE;

    $_[0] = $out ;

    return undef;
}

1;

__END__
FILE   )d0577e8d/IO/Uncompress/Adapter/Inflate.pm  
package IO::Uncompress::Adapter::Inflate;

use strict;
use warnings;
use bytes;

use IO::Compress::Base::Common  2.055 qw(:Status);
use Compress::Raw::Zlib  2.055 qw(Z_OK Z_BUF_ERROR Z_STREAM_END Z_FINISH MAX_WBITS);

our ($VERSION);
$VERSION = '2.055';



sub mkUncompObject
{
    my $crc32   = shift || 1;
    my $adler32 = shift || 1;
    my $scan    = shift || 0;

    my $inflate ;
    my $status ;

    if ($scan)
    {
        ($inflate, $status) = new Compress::Raw::Zlib::InflateScan
                                    #LimitOutput  => 1,
                                    CRC32        => $crc32,
                                    ADLER32      => $adler32,
                                    WindowBits   => - MAX_WBITS ;
    }
    else
    {
        ($inflate, $status) = new Compress::Raw::Zlib::Inflate
                                    AppendOutput => 1,
                                    LimitOutput  => 1,
                                    CRC32        => $crc32,
                                    ADLER32      => $adler32,
                                    WindowBits   => - MAX_WBITS ;
    }

    return (undef, "Could not create Inflation object: $status", $status) 
        if $status != Z_OK ;

    return bless {'Inf'        => $inflate,
                  'CompSize'   => 0,
                  'UnCompSize' => 0,
                  'Error'      => '',
                  'ConsumesInput' => 1,
                 } ;     
    
}

sub uncompr
{
    my $self = shift ;
    my $from = shift ;
    my $to   = shift ;
    my $eof  = shift ;

    my $inf   = $self->{Inf};

    my $status = $inf->inflate($from, $to, $eof);
    $self->{ErrorNo} = $status;

    if ($status != Z_OK && $status != Z_STREAM_END && $status != Z_BUF_ERROR)
    {
        $self->{Error} = "Inflation Error: $status";
        return STATUS_ERROR;
    }
            
    return STATUS_OK        if $status == Z_BUF_ERROR ; # ???
    return STATUS_OK        if $status == Z_OK ;
    return STATUS_ENDSTREAM if $status == Z_STREAM_END ;
    return STATUS_ERROR ;
}

sub reset
{
    my $self = shift ;
    $self->{Inf}->inflateReset();

    return STATUS_OK ;
}

#sub count
#{
#    my $self = shift ;
#    $self->{Inf}->inflateCount();
#}

sub crc32
{
    my $self = shift ;
    $self->{Inf}->crc32();
}

sub compressedBytes
{
    my $self = shift ;
    $self->{Inf}->compressedBytes();
}

sub uncompressedBytes
{
    my $self = shift ;
    $self->{Inf}->uncompressedBytes();
}

sub adler32
{
    my $self = shift ;
    $self->{Inf}->adler32();
}

sub sync
{
    my $self = shift ;
    ( $self->{Inf}->inflateSync(@_) == Z_OK) 
            ? STATUS_OK 
            : STATUS_ERROR ;
}


sub getLastBlockOffset
{
    my $self = shift ;
    $self->{Inf}->getLastBlockOffset();
}

sub getEndOffset
{
    my $self = shift ;
    $self->{Inf}->getEndOffset();
}

sub resetLastBlockByte
{
    my $self = shift ;
    $self->{Inf}->resetLastBlockByte(@_);
}

sub createDeflateStream
{
    my $self = shift ;
    my $deflate = $self->{Inf}->createDeflateStream(@_);
    return bless {'Def'        => $deflate,
                  'CompSize'   => 0,
                  'UnCompSize' => 0,
                  'Error'      => '',
                 }, 'IO::Compress::Adapter::Deflate';
}

1;


__END__

FILE   b651a16e/IO/Uncompress/Base.pm  �L#line 1 "/home/danny/perl5/lib/perl5/IO/Uncompress/Base.pm"

package IO::Uncompress::Base ;

use strict ;
use warnings;
use bytes;

our (@ISA, $VERSION, @EXPORT_OK, %EXPORT_TAGS);
@ISA    = qw(Exporter IO::File);


$VERSION = '2.055';

use constant G_EOF => 0 ;
use constant G_ERR => -1 ;

use IO::Compress::Base::Common 2.055 ;

use IO::File ;
use Symbol;
use Scalar::Util qw(readonly);
use List::Util qw(min);
use Carp ;

%EXPORT_TAGS = ( );
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;

sub smartRead
{
    my $self = $_[0];
    my $out = $_[1];
    my $size = $_[2];
    $$out = "" ;

    my $offset = 0 ;
    my $status = 1;


    if (defined *$self->{InputLength}) {
        return 0
            if *$self->{InputLengthRemaining} <= 0 ;
        $size = min($size, *$self->{InputLengthRemaining});
    }

    if ( length *$self->{Prime} ) {
        $$out = substr(*$self->{Prime}, 0, $size) ;
        substr(*$self->{Prime}, 0, $size) =  '' ;
        if (length $$out == $size) {
            *$self->{InputLengthRemaining} -= length $$out
                if defined *$self->{InputLength};

            return length $$out ;
        }
        $offset = length $$out ;
    }

    my $get_size = $size - $offset ;

    if (defined *$self->{FH}) {
        if ($offset) {
            # Not using this 
            #
            #  *$self->{FH}->read($$out, $get_size, $offset);
            #
            # because the filehandle may not support the offset parameter
            # An example is Net::FTP
            my $tmp = '';
            $status = *$self->{FH}->read($tmp, $get_size) ;
            substr($$out, $offset) = $tmp
                if defined $status && $status > 0 ;
        }
        else
          { $status = *$self->{FH}->read($$out, $get_size) }
    }
    elsif (defined *$self->{InputEvent}) {
        my $got = 1 ;
        while (length $$out < $size) {
            last 
                if ($got = *$self->{InputEvent}->($$out, $get_size)) <= 0;
        }

        if (length $$out > $size ) {
            *$self->{Prime} = substr($$out, $size, length($$out));
            substr($$out, $size, length($$out)) =  '';
        }

       *$self->{EventEof} = 1 if $got <= 0 ;
    }
    else {
       no warnings 'uninitialized';
       my $buf = *$self->{Buffer} ;
       $$buf = '' unless defined $$buf ;
       substr($$out, $offset) = substr($$buf, *$self->{BufferOffset}, $get_size);
       if (*$self->{ConsumeInput})
         { substr($$buf, 0, $get_size) = '' }
       else  
         { *$self->{BufferOffset} += length($$out) - $offset }
    }

    *$self->{InputLengthRemaining} -= length($$out) #- $offset 
        if defined *$self->{InputLength};
        
    if (! defined $status) {
        $self->saveStatus($!) ;
        return STATUS_ERROR;
    }

    $self->saveStatus(length $$out < 0 ? STATUS_ERROR : STATUS_OK) ;

    return length $$out;
}

sub pushBack
{
    my $self = shift ;

    return if ! defined $_[0] || length $_[0] == 0 ;

    if (defined *$self->{FH} || defined *$self->{InputEvent} ) {
        *$self->{Prime} = $_[0] . *$self->{Prime} ;
        *$self->{InputLengthRemaining} += length($_[0]);
    }
    else {
        my $len = length $_[0];

        if($len > *$self->{BufferOffset}) {
            *$self->{Prime} = substr($_[0], 0, $len - *$self->{BufferOffset}) . *$self->{Prime} ;
            *$self->{InputLengthRemaining} = *$self->{InputLength};
            *$self->{BufferOffset} = 0
        }
        else {
            *$self->{InputLengthRemaining} += length($_[0]);
            *$self->{BufferOffset} -= length($_[0]) ;
        }
    }
}

sub smartSeek
{
    my $self   = shift ;
    my $offset = shift ;
    my $truncate = shift;
    my $position = shift || SEEK_SET;

    # TODO -- need to take prime into account
    if (defined *$self->{FH})
      { *$self->{FH}->seek($offset, $position) }
    else {
        if ($position == SEEK_END) {
            *$self->{BufferOffset} = length ${ *$self->{Buffer} } + $offset ;
        }
        elsif ($position == SEEK_CUR) {
            *$self->{BufferOffset} += $offset ;
        }
        else {
            *$self->{BufferOffset} = $offset ;
        }

        substr(${ *$self->{Buffer} }, *$self->{BufferOffset}) = ''
            if $truncate;
        return 1;
    }
}

sub smartTell
{
    my $self   = shift ;

    if (defined *$self->{FH})
      { return *$self->{FH}->tell() }
    else 
      { return *$self->{BufferOffset} }
}

sub smartWrite
{
    my $self   = shift ;
    my $out_data = shift ;

    if (defined *$self->{FH}) {
        # flush needed for 5.8.0 
        defined *$self->{FH}->write($out_data, length $out_data) &&
        defined *$self->{FH}->flush() ;
    }
    else {
       my $buf = *$self->{Buffer} ;
       substr($$buf, *$self->{BufferOffset}, length $out_data) = $out_data ;
       *$self->{BufferOffset} += length($out_data) ;
       return 1;
    }
}

sub smartReadExact
{
    return $_[0]->smartRead($_[1], $_[2]) == $_[2];
}

sub smartEof
{
    my ($self) = $_[0];
    local $.; 

    return 0 if length *$self->{Prime} || *$self->{PushMode};

    if (defined *$self->{FH})
    {
        # Could use
        #
        #  *$self->{FH}->eof() 
        #
        # here, but this can cause trouble if
        # the filehandle is itself a tied handle, but it uses sysread.
        # Then we get into mixing buffered & non-buffered IO, 
        # which will cause trouble

        my $info = $self->getErrInfo();
        
        my $buffer = '';
        my $status = $self->smartRead(\$buffer, 1);
        $self->pushBack($buffer) if length $buffer;
        $self->setErrInfo($info);

        return $status == 0 ;
    }
    elsif (defined *$self->{InputEvent})
     { *$self->{EventEof} }
    else 
     { *$self->{BufferOffset} >= length(${ *$self->{Buffer} }) }
}

sub clearError
{
    my $self   = shift ;

    *$self->{ErrorNo}  =  0 ;
    ${ *$self->{Error} } = '' ;
}

sub getErrInfo
{
    my $self   = shift ;

    return [ *$self->{ErrorNo}, ${ *$self->{Error} } ] ;
}

sub setErrInfo
{
    my $self   = shift ;
    my $ref    = shift;

    *$self->{ErrorNo}  =  $ref->[0] ;
    ${ *$self->{Error} } = $ref->[1] ;
}

sub saveStatus
{
    my $self   = shift ;
    my $errno = shift() + 0 ;

    *$self->{ErrorNo}  = $errno;
    ${ *$self->{Error} } = '' ;

    return *$self->{ErrorNo} ;
}


sub saveErrorString
{
    my $self   = shift ;
    my $retval = shift ;

    ${ *$self->{Error} } = shift ;
    *$self->{ErrorNo} = @_ ? shift() + 0 : STATUS_ERROR ;

    return $retval;
}

sub croakError
{
    my $self   = shift ;
    $self->saveErrorString(0, $_[0]);
    croak $_[0];
}


sub closeError
{
    my $self = shift ;
    my $retval = shift ;

    my $errno = *$self->{ErrorNo};
    my $error = ${ *$self->{Error} };

    $self->close();

    *$self->{ErrorNo} = $errno ;
    ${ *$self->{Error} } = $error ;

    return $retval;
}

sub error
{
    my $self   = shift ;
    return ${ *$self->{Error} } ;
}

sub errorNo
{
    my $self   = shift ;
    return *$self->{ErrorNo};
}

sub HeaderError
{
    my ($self) = shift;
    return $self->saveErrorString(undef, "Header Error: $_[0]", STATUS_ERROR);
}

sub TrailerError
{
    my ($self) = shift;
    return $self->saveErrorString(G_ERR, "Trailer Error: $_[0]", STATUS_ERROR);
}

sub TruncatedHeader
{
    my ($self) = shift;
    return $self->HeaderError("Truncated in $_[0] Section");
}

sub TruncatedTrailer
{
    my ($self) = shift;
    return $self->TrailerError("Truncated in $_[0] Section");
}

sub postCheckParams
{
    return 1;
}

sub checkParams
{
    my $self = shift ;
    my $class = shift ;

    my $got = shift || IO::Compress::Base::Parameters::new();
    
    my $Valid = {
                    'BlockSize'     => [1, 1, Parse_unsigned, 16 * 1024],
                    'AutoClose'     => [1, 1, Parse_boolean,  0],
                    'Strict'        => [1, 1, Parse_boolean,  0],
                    'Append'        => [1, 1, Parse_boolean,  0],
                    'Prime'         => [1, 1, Parse_any,      undef],
                    'MultiStream'   => [1, 1, Parse_boolean,  0],
                    'Transparent'   => [1, 1, Parse_any,      1],
                    'Scan'          => [1, 1, Parse_boolean,  0],
                    'InputLength'   => [1, 1, Parse_unsigned, undef],
                    'BinModeOut'    => [1, 1, Parse_boolean,  0],
                    #'Encode'        => [1, 1, Parse_any,       undef],

                   #'ConsumeInput'  => [1, 1, Parse_boolean,  0],

                    $self->getExtraParams(),

                    #'Todo - Revert to ordinary file on end Z_STREAM_END'=> 0,
                    # ContinueAfterEof
                } ;

    $Valid->{TrailingData} = [1, 1, Parse_writable_scalar, undef]
        if  *$self->{OneShot} ;
        
    $got->parse($Valid, @_ ) 
        or $self->croakError("${class}: $got->{Error}")  ;

    $self->postCheckParams($got) 
        or $self->croakError("${class}: " . $self->error())  ;

    return $got;
}

sub _create
{
    my $obj = shift;
    my $got = shift;
    my $append_mode = shift ;

    my $class = ref $obj;
    $obj->croakError("$class: Missing Input parameter")
        if ! @_ && ! $got ;

    my $inValue = shift ;

    *$obj->{OneShot}           = 0 ;

    if (! $got)
    {
        $got = $obj->checkParams($class, undef, @_)
            or return undef ;
    }

    my $inType  = whatIsInput($inValue, 1);

    $obj->ckInputParam($class, $inValue, 1) 
        or return undef ;

    *$obj->{InNew} = 1;

    $obj->ckParams($got)
        or $obj->croakError("${class}: " . *$obj->{Error});

    if ($inType eq 'buffer' || $inType eq 'code') {
        *$obj->{Buffer} = $inValue ;        
        *$obj->{InputEvent} = $inValue 
           if $inType eq 'code' ;
    }
    else {
        if ($inType eq 'handle') {
            *$obj->{FH} = $inValue ;
            *$obj->{Handle} = 1 ;

            # Need to rewind for Scan
            *$obj->{FH}->seek(0, SEEK_SET) 
                if $got->value('Scan');
        }  
        else {    
            no warnings ;
            my $mode = '<';
            $mode = '+<' if $got->value('Scan');
            *$obj->{StdIO} = ($inValue eq '-');
            *$obj->{FH} = new IO::File "$mode $inValue"
                or return $obj->saveErrorString(undef, "cannot open file '$inValue': $!", $!) ;
        }
        
        *$obj->{LineNo} = $. = 0;
        setBinModeInput(*$obj->{FH}) ;

        my $buff = "" ;
        *$obj->{Buffer} = \$buff ;
    }

    if ($got->parsed('Encode')) { 
        my $want_encoding = $got->value('Encode');
        *$obj->{Encoding} = getEncoding($obj, $class, $want_encoding);
    }


    *$obj->{InputLength}       = $got->parsed('InputLength') 
                                    ? $got->value('InputLength')
                                    : undef ;
    *$obj->{InputLengthRemaining} = $got->value('InputLength');
    *$obj->{BufferOffset}      = 0 ;
    *$obj->{AutoClose}         = $got->value('AutoClose');
    *$obj->{Strict}            = $got->value('Strict');
    *$obj->{BlockSize}         = $got->value('BlockSize');
    *$obj->{Append}            = $got->value('Append');
    *$obj->{AppendOutput}      = $append_mode || $got->value('Append');
    *$obj->{ConsumeInput}      = $got->value('ConsumeInput');
    *$obj->{Transparent}       = $got->value('Transparent');
    *$obj->{MultiStream}       = $got->value('MultiStream');

    # TODO - move these two into RawDeflate
    *$obj->{Scan}              = $got->value('Scan');
    *$obj->{ParseExtra}        = $got->value('ParseExtra') 
                                  || $got->value('Strict')  ;
    *$obj->{Type}              = '';
    *$obj->{Prime}             = $got->value('Prime') || '' ;
    *$obj->{Pending}           = '';
    *$obj->{Plain}             = 0;
    *$obj->{PlainBytesRead}    = 0;
    *$obj->{InflatedBytesRead} = 0;
    *$obj->{UnCompSize}        = new U64;
    *$obj->{CompSize}          = new U64;
    *$obj->{TotalInflatedBytesRead} = 0;
    *$obj->{NewStream}         = 0 ;
    *$obj->{EventEof}          = 0 ;
    *$obj->{ClassName}         = $class ;
    *$obj->{Params}            = $got ;

    if (*$obj->{ConsumeInput}) {
        *$obj->{InNew} = 0;
        *$obj->{Closed} = 0;
        return $obj
    }

    my $status = $obj->mkUncomp($got);

    return undef
        unless defined $status;

    *$obj->{InNew} = 0;
    *$obj->{Closed} = 0;

    if ($status) {
        # Need to try uncompressing to catch the case
        # where the compressed file uncompresses to an
        # empty string - so eof is set immediately.
        
        my $out_buffer = '';

        $status = $obj->read(\$out_buffer);
    
        if ($status < 0) {
            *$obj->{ReadStatus} = [ $status, $obj->error(), $obj->errorNo() ];
        }

        $obj->ungetc($out_buffer)
            if length $out_buffer;
    }
    else {
        return undef 
            unless *$obj->{Transparent};

        $obj->clearError();
        *$obj->{Type} = 'plain';
        *$obj->{Plain} = 1;
        $obj->pushBack(*$obj->{HeaderPending})  ;
    }

    push @{ *$obj->{InfoList} }, *$obj->{Info} ;

    $obj->saveStatus(STATUS_OK) ;
    *$obj->{InNew} = 0;
    *$obj->{Closed} = 0;

    return $obj;
}

sub ckInputParam
{
    my $self = shift ;
    my $from = shift ;
    my $inType = whatIsInput($_[0], $_[1]);

    $self->croakError("$from: input parameter not a filename, filehandle, array ref or scalar ref")
        if ! $inType ;

#    if ($inType  eq 'filename' )
#    {
#        return $self->saveErrorString(1, "$from: input filename is undef or null string", STATUS_ERROR)
#            if ! defined $_[0] || $_[0] eq ''  ;
#
#        if ($_[0] ne '-' && ! -e $_[0] )
#        {
#            return $self->saveErrorString(1, 
#                            "input file '$_[0]' does not exist", STATUS_ERROR);
#        }
#    }

    return 1;
}


sub _inf
{
    my $obj = shift ;

    my $class = (caller)[0] ;
    my $name = (caller(1))[3] ;

    $obj->croakError("$name: expected at least 1 parameters\n")
        unless @_ >= 1 ;

    my $input = shift ;
    my $haveOut = @_ ;
    my $output = shift ;


    my $x = new IO::Compress::Base::Validator($class, *$obj->{Error}, $name, $input, $output)
        or return undef ;
    
    push @_, $output if $haveOut && $x->{Hash};

    *$obj->{OneShot} = 1 ;
    
    my $got = $obj->checkParams($name, undef, @_)
        or return undef ;

    if ($got->parsed('TrailingData'))
    {
        *$obj->{TrailingData} = $got->value('TrailingData');
    }

    *$obj->{MultiStream} = $got->value('MultiStream');
    $got->value('MultiStream', 0);

    $x->{Got} = $got ;

#    if ($x->{Hash})
#    {
#        while (my($k, $v) = each %$input)
#        {
#            $v = \$input->{$k} 
#                unless defined $v ;
#
#            $obj->_singleTarget($x, $k, $v, @_)
#                or return undef ;
#        }
#
#        return keys %$input ;
#    }
    
    if ($x->{GlobMap})
    {
        $x->{oneInput} = 1 ;
        foreach my $pair (@{ $x->{Pairs} })
        {
            my ($from, $to) = @$pair ;
            $obj->_singleTarget($x, $from, $to, @_)
                or return undef ;
        }

        return scalar @{ $x->{Pairs} } ;
    }

    if (! $x->{oneOutput} )
    {
        my $inFile = ($x->{inType} eq 'filenames' 
                        || $x->{inType} eq 'filename');

        $x->{inType} = $inFile ? 'filename' : 'buffer';
        
        foreach my $in ($x->{oneInput} ? $input : @$input)
        {
            my $out ;
            $x->{oneInput} = 1 ;

            $obj->_singleTarget($x, $in, $output, @_)
                or return undef ;
        }

        return 1 ;
    }

    # finally the 1 to 1 and n to 1
    return $obj->_singleTarget($x, $input, $output, @_);

    croak "should not be here" ;
}

sub retErr
{
    my $x = shift ;
    my $string = shift ;

    ${ $x->{Error} } = $string ;

    return undef ;
}

sub _singleTarget
{
    my $self      = shift ;
    my $x         = shift ;
    my $input     = shift;
    my $output    = shift;
    
    my $buff = '';
    $x->{buff} = \$buff ;

    my $fh ;
    if ($x->{outType} eq 'filename') {
        my $mode = '>' ;
        $mode = '>>'
            if $x->{Got}->value('Append') ;
        $x->{fh} = new IO::File "$mode $output" 
            or return retErr($x, "cannot open file '$output': $!") ;
        binmode $x->{fh} if $x->{Got}->valueOrDefault('BinModeOut');

    }

    elsif ($x->{outType} eq 'handle') {
        $x->{fh} = $output;
        binmode $x->{fh} if $x->{Got}->valueOrDefault('BinModeOut');
        if ($x->{Got}->value('Append')) {
                seek($x->{fh}, 0, SEEK_END)
                    or return retErr($x, "Cannot seek to end of output filehandle: $!") ;
            }
    }

    
    elsif ($x->{outType} eq 'buffer' )
    {
        $$output = '' 
            unless $x->{Got}->value('Append');
        $x->{buff} = $output ;
    }

    if ($x->{oneInput})
    {
        defined $self->_rd2($x, $input, $output)
            or return undef; 
    }
    else
    {
        for my $element ( ($x->{inType} eq 'hash') ? keys %$input : @$input)
        {
            defined $self->_rd2($x, $element, $output) 
                or return undef ;
        }
    }


    if ( ($x->{outType} eq 'filename' && $output ne '-') || 
         ($x->{outType} eq 'handle' && $x->{Got}->value('AutoClose'))) {
        $x->{fh}->close() 
            or return retErr($x, $!); 
        delete $x->{fh};
    }

    return 1 ;
}

sub _rd2
{
    my $self      = shift ;
    my $x         = shift ;
    my $input     = shift;
    my $output    = shift;
        
    my $z = createSelfTiedObject($x->{Class}, *$self->{Error});
    
    $z->_create($x->{Got}, 1, $input, @_)
        or return undef ;

    my $status ;
    my $fh = $x->{fh};
    
    while (1) {

        while (($status = $z->read($x->{buff})) > 0) {
            if ($fh) {
                syswrite $fh, ${ $x->{buff} }
                    or return $z->saveErrorString(undef, "Error writing to output file: $!", $!);
                ${ $x->{buff} } = '' ;
            }
        }

        if (! $x->{oneOutput} ) {
            my $ot = $x->{outType} ;

            if ($ot eq 'array') 
              { push @$output, $x->{buff} }
            elsif ($ot eq 'hash') 
              { $output->{$input} = $x->{buff} }

            my $buff = '';
            $x->{buff} = \$buff;
        }

        last if $status < 0 || $z->smartEof();

        last 
            unless *$self->{MultiStream};

        $status = $z->nextStream();

        last 
            unless $status == 1 ;
    }

    return $z->closeError(undef)
        if $status < 0 ;

    ${ *$self->{TrailingData} } = $z->trailingData()
        if defined *$self->{TrailingData} ;

    $z->close() 
        or return undef ;

    return 1 ;
}

sub TIEHANDLE
{
    return $_[0] if ref($_[0]);
    die "OOPS\n" ;

}
  
sub UNTIE
{
    my $self = shift ;
}


sub getHeaderInfo
{
    my $self = shift ;
    wantarray ? @{ *$self->{InfoList} } : *$self->{Info};
}

sub readBlock
{
    my $self = shift ;
    my $buff = shift ;
    my $size = shift ;

    if (defined *$self->{CompressedInputLength}) {
        if (*$self->{CompressedInputLengthRemaining} == 0) {
            delete *$self->{CompressedInputLength};
            *$self->{CompressedInputLengthDone} = 1;
            return STATUS_OK ;
        }
        $size = min($size, *$self->{CompressedInputLengthRemaining} );
        *$self->{CompressedInputLengthRemaining} -= $size ;
    }
    
    my $status = $self->smartRead($buff, $size) ;
    return $self->saveErrorString(STATUS_ERROR, "Error Reading Data: $!", $!)
        if $status == STATUS_ERROR  ;

    if ($status == 0 ) {
        *$self->{Closed} = 1 ;
        *$self->{EndStream} = 1 ;
        return $self->saveErrorString(STATUS_ERROR, "unexpected end of file", STATUS_ERROR);
    }

    return STATUS_OK;
}

sub postBlockChk
{
    return STATUS_OK;
}

sub _raw_read
{
    # return codes
    # >0 - ok, number of bytes read
    # =0 - ok, eof
    # <0 - not ok
    
    my $self = shift ;

    return G_EOF if *$self->{Closed} ;
    return G_EOF if *$self->{EndStream} ;

    my $buffer = shift ;
    my $scan_mode = shift ;

    if (*$self->{Plain}) {
        my $tmp_buff ;
        my $len = $self->smartRead(\$tmp_buff, *$self->{BlockSize}) ;
        
        return $self->saveErrorString(G_ERR, "Error reading data: $!", $!) 
                if $len == STATUS_ERROR ;

        if ($len == 0 ) {
            *$self->{EndStream} = 1 ;
        }
        else {
            *$self->{PlainBytesRead} += $len ;
            $$buffer .= $tmp_buff;
        }

        return $len ;
    }

    if (*$self->{NewStream}) {

        $self->gotoNextStream() > 0
            or return G_ERR;

        # For the headers that actually uncompressed data, put the
        # uncompressed data into the output buffer.
        $$buffer .=  *$self->{Pending} ;
        my $len = length  *$self->{Pending} ;
        *$self->{Pending} = '';
        return $len; 
    }

    my $temp_buf = '';
    my $outSize = 0;
    my $status = $self->readBlock(\$temp_buf, *$self->{BlockSize}, $outSize) ;
    
    return G_ERR
        if $status == STATUS_ERROR  ;

    my $buf_len = 0;
    if ($status == STATUS_OK) {
        my $beforeC_len = length $temp_buf;
        my $before_len = defined $$buffer ? length $$buffer : 0 ;
        $status = *$self->{Uncomp}->uncompr(\$temp_buf, $buffer,
                                    defined *$self->{CompressedInputLengthDone} ||
                                                $self->smartEof(), $outSize);
                                                
        # Remember the input buffer if it wasn't consumed completely
        $self->pushBack($temp_buf) if *$self->{Uncomp}{ConsumesInput};

        return $self->saveErrorString(G_ERR, *$self->{Uncomp}{Error}, *$self->{Uncomp}{ErrorNo})
            if $self->saveStatus($status) == STATUS_ERROR;    

        $self->postBlockChk($buffer, $before_len) == STATUS_OK
            or return G_ERR;

        $buf_len = defined $$buffer ? length($$buffer) - $before_len : 0;
    
        *$self->{CompSize}->add($beforeC_len - length $temp_buf) ;

        *$self->{InflatedBytesRead} += $buf_len ;
        *$self->{TotalInflatedBytesRead} += $buf_len ;
        *$self->{UnCompSize}->add($buf_len) ;

        $self->filterUncompressed($buffer, $before_len);

        if (*$self->{Encoding}) {
            $$buffer = *$self->{Encoding}->decode($$buffer);
        }
    }

    if ($status == STATUS_ENDSTREAM) {

        *$self->{EndStream} = 1 ;

        my $trailer;
        my $trailer_size = *$self->{Info}{TrailerLength} ;
        my $got = 0;
        if (*$self->{Info}{TrailerLength})
        {
            $got = $self->smartRead(\$trailer, $trailer_size) ;
        }

        if ($got == $trailer_size) {
            $self->chkTrailer($trailer) == STATUS_OK
                or return G_ERR;
        }
        else {
            return $self->TrailerError("trailer truncated. Expected " . 
                                      "$trailer_size bytes, got $got")
                if *$self->{Strict};
            $self->pushBack($trailer)  ;
        }

        # TODO - if want to file file pointer, do it here

        if (! $self->smartEof()) {
            *$self->{NewStream} = 1 ;

            if (*$self->{MultiStream}) {
                *$self->{EndStream} = 0 ;
                return $buf_len ;
            }
        }

    }
    

    # return the number of uncompressed bytes read
    return $buf_len ;
}

sub reset
{
    my $self = shift ;

    return *$self->{Uncomp}->reset();
}

sub filterUncompressed
{
}

#sub isEndStream
#{
#    my $self = shift ;
#    return *$self->{NewStream} ||
#           *$self->{EndStream} ;
#}

sub nextStream
{
    my $self = shift ;

    my $status = $self->gotoNextStream();
    $status == 1
        or return $status ;

    *$self->{TotalInflatedBytesRead} = 0 ;
    *$self->{LineNo} = $. = 0;

    return 1;
}

sub gotoNextStream
{
    my $self = shift ;

    if (! *$self->{NewStream}) {
        my $status = 1;
        my $buffer ;

        # TODO - make this more efficient if know the offset for the end of
        # the stream and seekable
        $status = $self->read($buffer) 
            while $status > 0 ;

        return $status
            if $status < 0;
    }

    *$self->{NewStream} = 0 ;
    *$self->{EndStream} = 0 ;
    *$self->{CompressedInputLengthDone} = undef ;
    *$self->{CompressedInputLength} = undef ;
    $self->reset();
    *$self->{UnCompSize}->reset();
    *$self->{CompSize}->reset();

    my $magic = $self->ckMagic();

    if ( ! defined $magic) {
        if (! *$self->{Transparent} || $self->eof())
        {
            *$self->{EndStream} = 1 ;
            return 0;
        }

        $self->clearError();
        *$self->{Type} = 'plain';
        *$self->{Plain} = 1;
        $self->pushBack(*$self->{HeaderPending})  ;
    }
    else
    {
        *$self->{Info} = $self->readHeader($magic);

        if ( ! defined *$self->{Info} ) {
            *$self->{EndStream} = 1 ;
            return -1;
        }
    }

    push @{ *$self->{InfoList} }, *$self->{Info} ;

    return 1; 
}

sub streamCount
{
    my $self = shift ;
    return 1 if ! defined *$self->{InfoList};
    return scalar @{ *$self->{InfoList} }  ;
}

#sub read
#{
#    my $status = myRead(@_);
#    return undef if $status < 0;
#    return $status;
#}

sub read
{
    # return codes
    # >0 - ok, number of bytes read
    # =0 - ok, eof
    # <0 - not ok
    
    my $self = shift ;

    if (defined *$self->{ReadStatus} ) {
        my $status = *$self->{ReadStatus}[0];
        $self->saveErrorString( @{ *$self->{ReadStatus} } );
        delete  *$self->{ReadStatus} ;
        return $status ;
    }

    return G_EOF if *$self->{Closed} ;

    my $buffer ;

    if (ref $_[0] ) {
        $self->croakError(*$self->{ClassName} . "::read: buffer parameter is read-only")
            if readonly(${ $_[0] });

        $self->croakError(*$self->{ClassName} . "::read: not a scalar reference $_[0]" )
            unless ref $_[0] eq 'SCALAR' ;
        $buffer = $_[0] ;
    }
    else {
        $self->croakError(*$self->{ClassName} . "::read: buffer parameter is read-only")
            if readonly($_[0]);

        $buffer = \$_[0] ;
    }

    my $length = $_[1] ;
    my $offset = $_[2] || 0;

    if (! *$self->{AppendOutput}) {
        if (! $offset) {    
            $$buffer = '' ;
        }
        else {
            if ($offset > length($$buffer)) {
                $$buffer .= "\x00" x ($offset - length($$buffer));
            }
            else {
                substr($$buffer, $offset) = '';
            }
        }
    }
    elsif (! defined $$buffer) {
        $$buffer = '' ;
    }

    return G_EOF if !length *$self->{Pending} && *$self->{EndStream} ;

    # the core read will return 0 if asked for 0 bytes
    return 0 if defined $length && $length == 0 ;

    $length = $length || 0;

    $self->croakError(*$self->{ClassName} . "::read: length parameter is negative")
        if $length < 0 ;

    # Short-circuit if this is a simple read, with no length
    # or offset specified.
    unless ( $length || $offset) {
        if (length *$self->{Pending}) {
            $$buffer .= *$self->{Pending} ;
            my $len = length *$self->{Pending};
            *$self->{Pending} = '' ;
            return $len ;
        }
        else {
            my $len = 0;
            $len = $self->_raw_read($buffer) 
                while ! *$self->{EndStream} && $len == 0 ;
            return $len ;
        }
    }

    # Need to jump through more hoops - either length or offset 
    # or both are specified.
    my $out_buffer = *$self->{Pending} ;
    *$self->{Pending} = '';


    while (! *$self->{EndStream} && length($out_buffer) < $length)
    {
        my $buf_len = $self->_raw_read(\$out_buffer);
        return $buf_len 
            if $buf_len < 0 ;
    }

    $length = length $out_buffer 
        if length($out_buffer) < $length ;

    return 0 
        if $length == 0 ;

    $$buffer = '' 
        if ! defined $$buffer;

    $offset = length $$buffer
        if *$self->{AppendOutput} ;

    *$self->{Pending} = $out_buffer;
    $out_buffer = \*$self->{Pending} ;

    substr($$buffer, $offset) = substr($$out_buffer, 0, $length) ;
    substr($$out_buffer, 0, $length) =  '' ;

    return $length ;
}

sub _getline
{
    my $self = shift ;
    my $status = 0 ;

    # Slurp Mode
    if ( ! defined $/ ) {
        my $data ;
        1 while ($status = $self->read($data)) > 0 ;
        return ($status, \$data);
    }

    # Record Mode
    if ( ref $/ eq 'SCALAR' && ${$/} =~ /^\d+$/ && ${$/} > 0) {
        my $reclen = ${$/} ;
        my $data ;
        $status = $self->read($data, $reclen) ;
        return ($status, \$data);
    }

    # Paragraph Mode
    if ( ! length $/ ) {
        my $paragraph ;    
        while (($status = $self->read($paragraph)) > 0 ) {
            if ($paragraph =~ s/^(.*?\n\n+)//s) {
                *$self->{Pending}  = $paragraph ;
                my $par = $1 ;
                return (1, \$par);
            }
        }
        return ($status, \$paragraph);
    }

    # $/ isn't empty, or a reference, so it's Line Mode.
    {
        my $line ;    
        my $p = \*$self->{Pending}  ;
        while (($status = $self->read($line)) > 0 ) {
            my $offset = index($line, $/);
            if ($offset >= 0) {
                my $l = substr($line, 0, $offset + length $/ );
                substr($line, 0, $offset + length $/) = '';    
                $$p = $line;
                return (1, \$l);
            }
        }

        return ($status, \$line);
    }
}

sub getline
{
    my $self = shift;

    if (defined *$self->{ReadStatus} ) {
        $self->saveErrorString( @{ *$self->{ReadStatus} } );
        delete  *$self->{ReadStatus} ;
        return undef;
    }

    return undef 
        if *$self->{Closed} || (!length *$self->{Pending} && *$self->{EndStream}) ;

    my $current_append = *$self->{AppendOutput} ;
    *$self->{AppendOutput} = 1;

    my ($status, $lineref) = $self->_getline();
    *$self->{AppendOutput} = $current_append;

    return undef 
        if $status < 0 || length $$lineref == 0 ;

    $. = ++ *$self->{LineNo} ;

    return $$lineref ;
}

sub getlines
{
    my $self = shift;
    $self->croakError(*$self->{ClassName} . 
            "::getlines: called in scalar context\n") unless wantarray;
    my($line, @lines);
    push(@lines, $line) 
        while defined($line = $self->getline);
    return @lines;
}

sub READLINE
{
    goto &getlines if wantarray;
    goto &getline;
}

sub getc
{
    my $self = shift;
    my $buf;
    return $buf if $self->read($buf, 1);
    return undef;
}

sub ungetc
{
    my $self = shift;
    *$self->{Pending} = ""  unless defined *$self->{Pending} ;    
    *$self->{Pending} = $_[0] . *$self->{Pending} ;    
}


sub trailingData
{
    my $self = shift ;

    if (defined *$self->{FH} || defined *$self->{InputEvent} ) {
        return *$self->{Prime} ;
    }
    else {
        my $buf = *$self->{Buffer} ;
        my $offset = *$self->{BufferOffset} ;
        return substr($$buf, $offset) ;
    }
}


sub eof
{
    my $self = shift ;

    return (*$self->{Closed} ||
              (!length *$self->{Pending} 
                && ( $self->smartEof() || *$self->{EndStream}))) ;
}

sub tell
{
    my $self = shift ;

    my $in ;
    if (*$self->{Plain}) {
        $in = *$self->{PlainBytesRead} ;
    }
    else {
        $in = *$self->{TotalInflatedBytesRead} ;
    }

    my $pending = length *$self->{Pending} ;

    return 0 if $pending > $in ;
    return $in - $pending ;
}

sub close
{
    # todo - what to do if close is called before the end of the gzip file
    #        do we remember any trailing data?
    my $self = shift ;

    return 1 if *$self->{Closed} ;

    untie *$self 
        if $] >= 5.008 ;

    my $status = 1 ;

    if (defined *$self->{FH}) {
        if ((! *$self->{Handle} || *$self->{AutoClose}) && ! *$self->{StdIO}) {
            local $.; 
            $! = 0 ;
            $status = *$self->{FH}->close();
            return $self->saveErrorString(0, $!, $!)
                if !*$self->{InNew} && $self->saveStatus($!) != 0 ;
        }
        delete *$self->{FH} ;
        $! = 0 ;
    }
    *$self->{Closed} = 1 ;

    return 1;
}

sub DESTROY
{
    my $self = shift ;
    local ($., $@, $!, $^E, $?);

    $self->close() ;
}

sub seek
{
    my $self     = shift ;
    my $position = shift;
    my $whence   = shift ;

    my $here = $self->tell() ;
    my $target = 0 ;


    if ($whence == SEEK_SET) {
        $target = $position ;
    }
    elsif ($whence == SEEK_CUR) {
        $target = $here + $position ;
    }
    elsif ($whence == SEEK_END) {
        $target = $position ;
        $self->croakError(*$self->{ClassName} . "::seek: SEEK_END not allowed") ;
    }
    else {
        $self->croakError(*$self->{ClassName} ."::seek: unknown value, $whence, for whence parameter");
    }

    # short circuit if seeking to current offset
    if ($target == $here) {
        # On ordinary filehandles, seeking to the current
        # position also clears the EOF condition, so we
        # emulate this behavior locally while simultaneously
        # cascading it to the underlying filehandle
        if (*$self->{Plain}) {
            *$self->{EndStream} = 0;
            seek(*$self->{FH},0,1) if *$self->{FH};
        }
        return 1;
    }

    # Outlaw any attempt to seek backwards
    $self->croakError( *$self->{ClassName} ."::seek: cannot seek backwards")
        if $target < $here ;

    # Walk the file to the new offset
    my $offset = $target - $here ;

    my $got;
    while (($got = $self->read(my $buffer, min($offset, *$self->{BlockSize})) ) > 0)
    {
        $offset -= $got;
        last if $offset == 0 ;
    }

    $here = $self->tell() ;
    return $offset == 0 ? 1 : 0 ;
}

sub fileno
{
    my $self = shift ;
    return defined *$self->{FH} 
           ? fileno *$self->{FH} 
           : undef ;
}

sub binmode
{
    1;
#    my $self     = shift ;
#    return defined *$self->{FH} 
#            ? binmode *$self->{FH} 
#            : 1 ;
}

sub opened
{
    my $self     = shift ;
    return ! *$self->{Closed} ;
}

sub autoflush
{
    my $self     = shift ;
    return defined *$self->{FH} 
            ? *$self->{FH}->autoflush(@_) 
            : undef ;
}

sub input_line_number
{
    my $self = shift ;
    my $last = *$self->{LineNo};
    $. = *$self->{LineNo} = $_[1] if @_ ;
    return $last;
}


*BINMODE  = \&binmode;
*SEEK     = \&seek; 
*READ     = \&read;
*sysread  = \&read;
*TELL     = \&tell;
*EOF      = \&eof;

*FILENO   = \&fileno;
*CLOSE    = \&close;

sub _notAvailable
{
    my $name = shift ;
    return sub { croak "$name Not Available: File opened only for intput" ; } ;
}


*print    = _notAvailable('print');
*PRINT    = _notAvailable('print');
*printf   = _notAvailable('printf');
*PRINTF   = _notAvailable('printf');
*write    = _notAvailable('write');
*WRITE    = _notAvailable('write');

#*sysread  = \&read;
#*syswrite = \&_notAvailable;



package IO::Uncompress::Base ;


1 ;
__END__

#line 1528
FILE    98c09980/IO/Uncompress/Gunzip.pm  6#line 1 "/home/danny/perl5/lib/perl5/IO/Uncompress/Gunzip.pm"

package IO::Uncompress::Gunzip ;

require 5.006 ;

# for RFC1952

use strict ;
use warnings;
use bytes;

use IO::Uncompress::RawInflate 2.055 ;

use Compress::Raw::Zlib 2.055 () ;
use IO::Compress::Base::Common 2.055 qw(:Status createSelfTiedObject);
use IO::Compress::Gzip::Constants 2.055 ;
use IO::Compress::Zlib::Extra 2.055 ;

require Exporter ;

our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, $GunzipError);

@ISA = qw( Exporter IO::Uncompress::RawInflate );
@EXPORT_OK = qw( $GunzipError gunzip );
%EXPORT_TAGS = %IO::Uncompress::RawInflate::DEFLATE_CONSTANTS ;
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
Exporter::export_ok_tags('all');

$GunzipError = '';

$VERSION = '2.055';

sub new
{
    my $class = shift ;
    $GunzipError = '';
    my $obj = createSelfTiedObject($class, \$GunzipError);

    $obj->_create(undef, 0, @_);
}

sub gunzip
{
    my $obj = createSelfTiedObject(undef, \$GunzipError);
    return $obj->_inf(@_) ;
}

sub getExtraParams
{
    use IO::Compress::Base::Common  2.055 qw(:Parse);
    return ( 'ParseExtra' => [1, 1, Parse_boolean,  0] ) ;
}

sub ckParams
{
    my $self = shift ;
    my $got = shift ;

    # gunzip always needs crc32
    $got->value('CRC32' => 1);

    return 1;
}

sub ckMagic
{
    my $self = shift;

    my $magic ;
    $self->smartReadExact(\$magic, GZIP_ID_SIZE);

    *$self->{HeaderPending} = $magic ;

    return $self->HeaderError("Minimum header size is " . 
                              GZIP_MIN_HEADER_SIZE . " bytes") 
        if length $magic != GZIP_ID_SIZE ;                                    

    return $self->HeaderError("Bad Magic")
        if ! isGzipMagic($magic) ;

    *$self->{Type} = 'rfc1952';

    return $magic ;
}

sub readHeader
{
    my $self = shift;
    my $magic = shift;

    return $self->_readGzipHeader($magic);
}

sub chkTrailer
{
    my $self = shift;
    my $trailer = shift;

    # Check CRC & ISIZE 
    my ($CRC32, $ISIZE) = unpack("V V", $trailer) ;
    *$self->{Info}{CRC32} = $CRC32;    
    *$self->{Info}{ISIZE} = $ISIZE;    

    if (*$self->{Strict}) {
        return $self->TrailerError("CRC mismatch")
            if $CRC32 != *$self->{Uncomp}->crc32() ;

        my $exp_isize = *$self->{UnCompSize}->get32bit();
        return $self->TrailerError("ISIZE mismatch. Got $ISIZE"
                                  . ", expected $exp_isize")
            if $ISIZE != $exp_isize ;
    }

    return STATUS_OK;
}

sub isGzipMagic
{
    my $buffer = shift ;
    return 0 if length $buffer < GZIP_ID_SIZE ;
    my ($id1, $id2) = unpack("C C", $buffer) ;
    return $id1 == GZIP_ID1 && $id2 == GZIP_ID2 ;
}

sub _readFullGzipHeader($)
{
    my ($self) = @_ ;
    my $magic = '' ;

    $self->smartReadExact(\$magic, GZIP_ID_SIZE);

    *$self->{HeaderPending} = $magic ;

    return $self->HeaderError("Minimum header size is " . 
                              GZIP_MIN_HEADER_SIZE . " bytes") 
        if length $magic != GZIP_ID_SIZE ;                                    


    return $self->HeaderError("Bad Magic")
        if ! isGzipMagic($magic) ;

    my $status = $self->_readGzipHeader($magic);
    delete *$self->{Transparent} if ! defined $status ;
    return $status ;
}

sub _readGzipHeader($)
{
    my ($self, $magic) = @_ ;
    my ($HeaderCRC) ;
    my ($buffer) = '' ;

    $self->smartReadExact(\$buffer, GZIP_MIN_HEADER_SIZE - GZIP_ID_SIZE)
        or return $self->HeaderError("Minimum header size is " . 
                                     GZIP_MIN_HEADER_SIZE . " bytes") ;

    my $keep = $magic . $buffer ;
    *$self->{HeaderPending} = $keep ;

    # now split out the various parts
    my ($cm, $flag, $mtime, $xfl, $os) = unpack("C C V C C", $buffer) ;

    $cm == GZIP_CM_DEFLATED 
        or return $self->HeaderError("Not Deflate (CM is $cm)") ;

    # check for use of reserved bits
    return $self->HeaderError("Use of Reserved Bits in FLG field.")
        if $flag & GZIP_FLG_RESERVED ; 

    my $EXTRA ;
    my @EXTRA = () ;
    if ($flag & GZIP_FLG_FEXTRA) {
        $EXTRA = "" ;
        $self->smartReadExact(\$buffer, GZIP_FEXTRA_HEADER_SIZE) 
            or return $self->TruncatedHeader("FEXTRA Length") ;

        my ($XLEN) = unpack("v", $buffer) ;
        $self->smartReadExact(\$EXTRA, $XLEN) 
            or return $self->TruncatedHeader("FEXTRA Body");
        $keep .= $buffer . $EXTRA ;

        if ($XLEN && *$self->{'ParseExtra'}) {
            my $bad = IO::Compress::Zlib::Extra::parseRawExtra($EXTRA,
                                                \@EXTRA, 1, 1);
            return $self->HeaderError($bad)
                if defined $bad;
        }
    }

    my $origname ;
    if ($flag & GZIP_FLG_FNAME) {
        $origname = "" ;
        while (1) {
            $self->smartReadExact(\$buffer, 1) 
                or return $self->TruncatedHeader("FNAME");
            last if $buffer eq GZIP_NULL_BYTE ;
            $origname .= $buffer 
        }
        $keep .= $origname . GZIP_NULL_BYTE ;

        return $self->HeaderError("Non ISO 8859-1 Character found in Name")
            if *$self->{Strict} && $origname =~ /$GZIP_FNAME_INVALID_CHAR_RE/o ;
    }

    my $comment ;
    if ($flag & GZIP_FLG_FCOMMENT) {
        $comment = "";
        while (1) {
            $self->smartReadExact(\$buffer, 1) 
                or return $self->TruncatedHeader("FCOMMENT");
            last if $buffer eq GZIP_NULL_BYTE ;
            $comment .= $buffer 
        }
        $keep .= $comment . GZIP_NULL_BYTE ;

        return $self->HeaderError("Non ISO 8859-1 Character found in Comment")
            if *$self->{Strict} && $comment =~ /$GZIP_FCOMMENT_INVALID_CHAR_RE/o ;
    }

    if ($flag & GZIP_FLG_FHCRC) {
        $self->smartReadExact(\$buffer, GZIP_FHCRC_SIZE) 
            or return $self->TruncatedHeader("FHCRC");

        $HeaderCRC = unpack("v", $buffer) ;
        my $crc16 = Compress::Raw::Zlib::crc32($keep) & 0xFF ;

        return $self->HeaderError("CRC16 mismatch.")
            if *$self->{Strict} && $crc16 != $HeaderCRC;

        $keep .= $buffer ;
    }

    # Assume compression method is deflated for xfl tests
    #if ($xfl) {
    #}

    *$self->{Type} = 'rfc1952';

    return {
        'Type'          => 'rfc1952',
        'FingerprintLength'  => 2,
        'HeaderLength'  => length $keep,
        'TrailerLength' => GZIP_TRAILER_SIZE,
        'Header'        => $keep,
        'isMinimalHeader' => $keep eq GZIP_MINIMUM_HEADER ? 1 : 0,

        'MethodID'      => $cm,
        'MethodName'    => $cm == GZIP_CM_DEFLATED ? "Deflated" : "Unknown" ,
        'TextFlag'      => $flag & GZIP_FLG_FTEXT ? 1 : 0,
        'HeaderCRCFlag' => $flag & GZIP_FLG_FHCRC ? 1 : 0,
        'NameFlag'      => $flag & GZIP_FLG_FNAME ? 1 : 0,
        'CommentFlag'   => $flag & GZIP_FLG_FCOMMENT ? 1 : 0,
        'ExtraFlag'     => $flag & GZIP_FLG_FEXTRA ? 1 : 0,
        'Name'          => $origname,
        'Comment'       => $comment,
        'Time'          => $mtime,
        'OsID'          => $os,
        'OsName'        => defined $GZIP_OS_Names{$os} 
                                 ? $GZIP_OS_Names{$os} : "Unknown",
        'HeaderCRC'     => $HeaderCRC,
        'Flags'         => $flag,
        'ExtraFlags'    => $xfl,
        'ExtraFieldRaw' => $EXTRA,
        'ExtraField'    => [ @EXTRA ],


        #'CompSize'=> $compsize,
        #'CRC32'=> $CRC32,
        #'OrigSize'=> $ISIZE,
      }
}


1;

__END__


#line 1112
FILE   $f2e0fadd/IO/Uncompress/RawInflate.pm  "#line 1 "/home/danny/perl5/lib/perl5/IO/Uncompress/RawInflate.pm"
package IO::Uncompress::RawInflate ;
# for RFC1951

use strict ;
use warnings;
use bytes;

use Compress::Raw::Zlib  2.055 ;
use IO::Compress::Base::Common  2.055 qw(:Status createSelfTiedObject);

use IO::Uncompress::Base  2.055 ;
use IO::Uncompress::Adapter::Inflate  2.055 ;

require Exporter ;
our ($VERSION, @ISA, @EXPORT_OK, %EXPORT_TAGS, %DEFLATE_CONSTANTS, $RawInflateError);

$VERSION = '2.055';
$RawInflateError = '';

@ISA    = qw( Exporter IO::Uncompress::Base );
@EXPORT_OK = qw( $RawInflateError rawinflate ) ;
%DEFLATE_CONSTANTS = ();
%EXPORT_TAGS = %IO::Uncompress::Base::EXPORT_TAGS ;
push @{ $EXPORT_TAGS{all} }, @EXPORT_OK ;
Exporter::export_ok_tags('all');

#{
#    # Execute at runtime  
#    my %bad;
#    for my $module (qw(Compress::Raw::Zlib IO::Compress::Base::Common IO::Uncompress::Base IO::Uncompress::Adapter::Inflate))
#    {
#        my $ver = ${ $module . "::VERSION"} ;
#        
#        $bad{$module} = $ver
#            if $ver ne $VERSION;
#    }
#    
#    if (keys %bad)
#    {
#        my $string = join "\n", map { "$_ $bad{$_}" } keys %bad;
#        die caller(0)[0] . "needs version $VERSION mismatch\n$string\n";
#    }
#}

sub new
{
    my $class = shift ;
    my $obj = createSelfTiedObject($class, \$RawInflateError);
    $obj->_create(undef, 0, @_);
}

sub rawinflate
{
    my $obj = createSelfTiedObject(undef, \$RawInflateError);
    return $obj->_inf(@_);
}

sub getExtraParams
{
    return ();
}

sub ckParams
{
    my $self = shift ;
    my $got = shift ;

    return 1;
}

sub mkUncomp
{
    my $self = shift ;
    my $got = shift ;

    my ($obj, $errstr, $errno) = IO::Uncompress::Adapter::Inflate::mkUncompObject(
                                                                $got->value('CRC32'),
                                                                $got->value('ADLER32'),
                                                                $got->value('Scan'),
                                                            );

    return $self->saveErrorString(undef, $errstr, $errno)
        if ! defined $obj;

    *$self->{Uncomp} = $obj;

     my $magic = $self->ckMagic()
        or return 0;

    *$self->{Info} = $self->readHeader($magic)
        or return undef ;

    return 1;

}


sub ckMagic
{
    my $self = shift;

    return $self->_isRaw() ;
}

sub readHeader
{
    my $self = shift;
    my $magic = shift ;

    return {
        'Type'          => 'rfc1951',
        'FingerprintLength'  => 0,
        'HeaderLength'  => 0,
        'TrailerLength' => 0,
        'Header'        => ''
        };
}

sub chkTrailer
{
    return STATUS_OK ;
}

sub _isRaw
{
    my $self   = shift ;

    my $got = $self->_isRawx(@_);

    if ($got) {
        *$self->{Pending} = *$self->{HeaderPending} ;
    }
    else {
        $self->pushBack(*$self->{HeaderPending});
        *$self->{Uncomp}->reset();
    }
    *$self->{HeaderPending} = '';

    return $got ;
}

sub _isRawx
{
    my $self   = shift ;
    my $magic = shift ;

    $magic = '' unless defined $magic ;

    my $buffer = '';

    $self->smartRead(\$buffer, *$self->{BlockSize}) >= 0  
        or return $self->saveErrorString(undef, "No data to read");

    my $temp_buf = $magic . $buffer ;
    *$self->{HeaderPending} = $temp_buf ;    
    $buffer = '';
    my $status = *$self->{Uncomp}->uncompr(\$temp_buf, \$buffer, $self->smartEof()) ;
    
    return $self->saveErrorString(undef, *$self->{Uncomp}{Error}, STATUS_ERROR)
        if $status == STATUS_ERROR;

    $self->pushBack($temp_buf)  ;

    return $self->saveErrorString(undef, "unexpected end of file", STATUS_ERROR)
        if $self->smartEof() && $status != STATUS_ENDSTREAM;
            
    #my $buf_len = *$self->{Uncomp}->uncompressedBytes();
    my $buf_len = length $buffer;

    if ($status == STATUS_ENDSTREAM) {
        if (*$self->{MultiStream} 
                    && (length $temp_buf || ! $self->smartEof())){
            *$self->{NewStream} = 1 ;
            *$self->{EndStream} = 0 ;
        }
        else {
            *$self->{EndStream} = 1 ;
        }
    }
    *$self->{HeaderPending} = $buffer ;    
    *$self->{InflatedBytesRead} = $buf_len ;    
    *$self->{TotalInflatedBytesRead} += $buf_len ;    
    *$self->{Type} = 'rfc1951';

    $self->saveStatus(STATUS_OK);

    return {
        'Type'          => 'rfc1951',
        'HeaderLength'  => 0,
        'TrailerLength' => 0,
        'Header'        => ''
        };
}


sub inflateSync
{
    my $self = shift ;

    # inflateSync is a no-op in Plain mode
    return 1
        if *$self->{Plain} ;

    return 0 if *$self->{Closed} ;
    #return G_EOF if !length *$self->{Pending} && *$self->{EndStream} ;
    return 0 if ! length *$self->{Pending} && *$self->{EndStream} ;

    # Disable CRC check
    *$self->{Strict} = 0 ;

    my $status ;
    while (1)
    {
        my $temp_buf ;

        if (length *$self->{Pending} )
        {
            $temp_buf = *$self->{Pending} ;
            *$self->{Pending} = '';
        }
        else
        {
            $status = $self->smartRead(\$temp_buf, *$self->{BlockSize}) ;
            return $self->saveErrorString(0, "Error Reading Data")
                if $status < 0  ;

            if ($status == 0 ) {
                *$self->{EndStream} = 1 ;
                return $self->saveErrorString(0, "unexpected end of file", STATUS_ERROR);
            }
        }
        
        $status = *$self->{Uncomp}->sync($temp_buf) ;

        if ($status == STATUS_OK)
        {
            *$self->{Pending} .= $temp_buf ;
            return 1 ;
        }

        last unless $status == STATUS_ERROR ;
    }

    return 0;
}

#sub performScan
#{
#    my $self = shift ;
#
#    my $status ;
#    my $end_offset = 0;
#
#    $status = $self->scan() 
#    #or return $self->saveErrorString(undef, "Error Scanning: $$error_ref", $self->errorNo) ;
#        or return $self->saveErrorString(G_ERR, "Error Scanning: $status")
#
#    $status = $self->zap($end_offset) 
#        or return $self->saveErrorString(G_ERR, "Error Zapping: $status");
#    #or return $self->saveErrorString(undef, "Error Zapping: $$error_ref", $self->errorNo) ;
#
#    #(*$obj->{Deflate}, $status) = $inf->createDeflate();
#
##    *$obj->{Header} = *$inf->{Info}{Header};
##    *$obj->{UnCompSize_32bit} = 
##        *$obj->{BytesWritten} = *$inf->{UnCompSize_32bit} ;
##    *$obj->{CompSize_32bit} = *$inf->{CompSize_32bit} ;
#
#
##    if ( $outType eq 'buffer') 
##      { substr( ${ *$self->{Buffer} }, $end_offset) = '' }
##    elsif ($outType eq 'handle' || $outType eq 'filename') {
##        *$self->{FH} = *$inf->{FH} ;
##        delete *$inf->{FH};
##        *$obj->{FH}->flush() ;
##        *$obj->{Handle} = 1 if $outType eq 'handle';
##
##        #seek(*$obj->{FH}, $end_offset, SEEK_SET) 
##        *$obj->{FH}->seek($end_offset, SEEK_SET) 
##            or return $obj->saveErrorString(undef, $!, $!) ;
##    }
#    
#}

sub scan
{
    my $self = shift ;

    return 1 if *$self->{Closed} ;
    return 1 if !length *$self->{Pending} && *$self->{EndStream} ;

    my $buffer = '' ;
    my $len = 0;

    $len = $self->_raw_read(\$buffer, 1) 
        while ! *$self->{EndStream} && $len >= 0 ;

    #return $len if $len < 0 ? $len : 0 ;
    return $len < 0 ? 0 : 1 ;
}

sub zap
{
    my $self  = shift ;

    my $headerLength = *$self->{Info}{HeaderLength};
    my $block_offset =  $headerLength + *$self->{Uncomp}->getLastBlockOffset();
    $_[0] = $headerLength + *$self->{Uncomp}->getEndOffset();
    #printf "# End $_[0], headerlen $headerLength \n";;
    #printf "# block_offset $block_offset %x\n", $block_offset;
    my $byte ;
    ( $self->smartSeek($block_offset) &&
      $self->smartRead(\$byte, 1) ) 
        or return $self->saveErrorString(0, $!, $!); 

    #printf "#byte is %x\n", unpack('C*',$byte);
    *$self->{Uncomp}->resetLastBlockByte($byte);
    #printf "#to byte is %x\n", unpack('C*',$byte);

    ( $self->smartSeek($block_offset) && 
      $self->smartWrite($byte) )
        or return $self->saveErrorString(0, $!, $!); 

    #$self->smartSeek($end_offset, 1);

    return 1 ;
}

sub createDeflate
{
    my $self  = shift ;
    my ($def, $status) = *$self->{Uncomp}->createDeflateStream(
                                    -AppendOutput   => 1,
                                    -WindowBits => - MAX_WBITS,
                                    -CRC32      => *$self->{Params}->value('CRC32'),
                                    -ADLER32    => *$self->{Params}->value('ADLER32'),
                                );
    
    return wantarray ? ($status, $def) : $def ;                                
}


1; 

__END__


#line 1111
FILE   ec338265/Compress/Raw/Zlib.pm  Cd#line 1 "/home/danny/perl5/lib/perl5/x86_64-linux-gnu-thread-multi/Compress/Raw/Zlib.pm"

package Compress::Raw::Zlib;

require 5.006 ;
require Exporter;
use AutoLoader;
use Carp ;

use strict ;
use warnings ;
use bytes ;
our ($VERSION, $XS_VERSION, @ISA, @EXPORT, %EXPORT_TAGS, @EXPORT_OK, $AUTOLOAD, %DEFLATE_CONSTANTS, @DEFLATE_CONSTANTS );

$VERSION = '2.056';
$XS_VERSION = $VERSION; 
$VERSION = eval $VERSION;

@ISA = qw(Exporter);
%EXPORT_TAGS = ( flush     => [qw{  
                                    Z_NO_FLUSH
                                    Z_PARTIAL_FLUSH
                                    Z_SYNC_FLUSH
                                    Z_FULL_FLUSH
                                    Z_FINISH
                                    Z_BLOCK
                              }],
                 level     => [qw{  
                                    Z_NO_COMPRESSION
                                    Z_BEST_SPEED
                                    Z_BEST_COMPRESSION
                                    Z_DEFAULT_COMPRESSION
                              }],
                 strategy  => [qw{  
                                    Z_FILTERED
                                    Z_HUFFMAN_ONLY
                                    Z_RLE
                                    Z_FIXED
                                    Z_DEFAULT_STRATEGY
                              }],
                 status   => [qw{  
                                    Z_OK
                                    Z_STREAM_END
                                    Z_NEED_DICT
                                    Z_ERRNO
                                    Z_STREAM_ERROR
                                    Z_DATA_ERROR  
                                    Z_MEM_ERROR   
                                    Z_BUF_ERROR 
                                    Z_VERSION_ERROR 
                              }],                              
              );

%DEFLATE_CONSTANTS = %EXPORT_TAGS;

# Items to export into callers namespace by default. Note: do not export
# names by default without a very good reason. Use EXPORT_OK instead.
# Do not simply export all your public functions/methods/constants.
@DEFLATE_CONSTANTS = 
@EXPORT = qw(
        ZLIB_VERSION
        ZLIB_VERNUM

        
        OS_CODE

        MAX_MEM_LEVEL
        MAX_WBITS

        Z_ASCII
        Z_BEST_COMPRESSION
        Z_BEST_SPEED
        Z_BINARY
        Z_BLOCK
        Z_BUF_ERROR
        Z_DATA_ERROR
        Z_DEFAULT_COMPRESSION
        Z_DEFAULT_STRATEGY
        Z_DEFLATED
        Z_ERRNO
        Z_FILTERED
        Z_FIXED
        Z_FINISH
        Z_FULL_FLUSH
        Z_HUFFMAN_ONLY
        Z_MEM_ERROR
        Z_NEED_DICT
        Z_NO_COMPRESSION
        Z_NO_FLUSH
        Z_NULL
        Z_OK
        Z_PARTIAL_FLUSH
        Z_RLE
        Z_STREAM_END
        Z_STREAM_ERROR
        Z_SYNC_FLUSH
        Z_TREES
        Z_UNKNOWN
        Z_VERSION_ERROR

        WANT_GZIP
        WANT_GZIP_OR_ZLIB
);

push @EXPORT, qw(crc32 adler32 DEF_WBITS);

use constant WANT_GZIP           => 16;
use constant WANT_GZIP_OR_ZLIB   => 32;

sub AUTOLOAD {
    my($constname);
    ($constname = $AUTOLOAD) =~ s/.*:://;
    my ($error, $val) = constant($constname);
    Carp::croak $error if $error;
    no strict 'refs';
    *{$AUTOLOAD} = sub { $val };
    goto &{$AUTOLOAD};
}

use constant FLAG_APPEND             => 1 ;
use constant FLAG_CRC                => 2 ;
use constant FLAG_ADLER              => 4 ;
use constant FLAG_CONSUME_INPUT      => 8 ;
use constant FLAG_LIMIT_OUTPUT       => 16 ;

eval {
    require XSLoader;
    XSLoader::load('Compress::Raw::Zlib', $XS_VERSION);
    1;
} 
or do {
    require DynaLoader;
    local @ISA = qw(DynaLoader);
    bootstrap Compress::Raw::Zlib $XS_VERSION ; 
};
 

use constant Parse_any      => 0x01;
use constant Parse_unsigned => 0x02;
use constant Parse_signed   => 0x04;
use constant Parse_boolean  => 0x08;
use constant Parse_string   => 0x10;
use constant Parse_custom   => 0x12;

use constant Parse_store_ref => 0x100 ;

use constant OFF_PARSED     => 0 ;
use constant OFF_TYPE       => 1 ;
use constant OFF_DEFAULT    => 2 ;
use constant OFF_FIXED      => 3 ;
use constant OFF_FIRST_ONLY => 4 ;
use constant OFF_STICKY     => 5 ;



sub ParseParameters
{
    my $level = shift || 0 ; 

    my $sub = (caller($level + 1))[3] ;
    #local $Carp::CarpLevel = 1 ;
    my $p = new Compress::Raw::Zlib::Parameters() ;
    $p->parse(@_)
        or croak "$sub: $p->{Error}" ;

    return $p;
}


sub Compress::Raw::Zlib::Parameters::new
{
    my $class = shift ;

    my $obj = { Error => '',
                Got   => {},
              } ;

    #return bless $obj, ref($class) || $class || __PACKAGE__ ;
    return bless $obj, 'Compress::Raw::Zlib::Parameters' ;
}

sub Compress::Raw::Zlib::Parameters::setError
{
    my $self = shift ;
    my $error = shift ;
    my $retval = @_ ? shift : undef ;

    $self->{Error} = $error ;
    return $retval;
}
          
#sub getError
#{
#    my $self = shift ;
#    return $self->{Error} ;
#}
          
sub Compress::Raw::Zlib::Parameters::parse
{
    my $self = shift ;

    my $default = shift ;

    my $got = $self->{Got} ;
    my $firstTime = keys %{ $got } == 0 ;

    my (@Bad) ;
    my @entered = () ;

    # Allow the options to be passed as a hash reference or
    # as the complete hash.
    if (@_ == 0) {
        @entered = () ;
    }
    elsif (@_ == 1) {
        my $href = $_[0] ;    
        return $self->setError("Expected even number of parameters, got 1")
            if ! defined $href or ! ref $href or ref $href ne "HASH" ;
 
        foreach my $key (keys %$href) {
            push @entered, $key ;
            push @entered, \$href->{$key} ;
        }
    }
    else {
        my $count = @_;
        return $self->setError("Expected even number of parameters, got $count")
            if $count % 2 != 0 ;
        
        for my $i (0.. $count / 2 - 1) {
            push @entered, $_[2* $i] ;
            push @entered, \$_[2* $i+1] ;
        }
    }


    while (my ($key, $v) = each %$default)
    {
        croak "need 4 params [@$v]"
            if @$v != 4 ;

        my ($first_only, $sticky, $type, $value) = @$v ;
        my $x ;
        $self->_checkType($key, \$value, $type, 0, \$x) 
            or return undef ;

        $key = lc $key;

        if ($firstTime || ! $sticky) {
            $got->{$key} = [0, $type, $value, $x, $first_only, $sticky] ;
        }

        $got->{$key}[OFF_PARSED] = 0 ;
    }

    for my $i (0.. @entered / 2 - 1) {
        my $key = $entered[2* $i] ;
        my $value = $entered[2* $i+1] ;

        #print "Key [$key] Value [$value]" ;
        #print defined $$value ? "[$$value]\n" : "[undef]\n";

        $key =~ s/^-// ;
        my $canonkey = lc $key;
 
        if ($got->{$canonkey} && ($firstTime ||
                                  ! $got->{$canonkey}[OFF_FIRST_ONLY]  ))
        {
            my $type = $got->{$canonkey}[OFF_TYPE] ;
            my $s ;
            $self->_checkType($key, $value, $type, 1, \$s)
                or return undef ;
            #$value = $$value unless $type & Parse_store_ref ;
            $value = $$value ;
            $got->{$canonkey} = [1, $type, $value, $s] ;
        }
        else
          { push (@Bad, $key) }
    }
 
    if (@Bad) {
        my ($bad) = join(", ", @Bad) ;
        return $self->setError("unknown key value(s) @Bad") ;
    }

    return 1;
}

sub Compress::Raw::Zlib::Parameters::_checkType
{
    my $self = shift ;

    my $key   = shift ;
    my $value = shift ;
    my $type  = shift ;
    my $validate  = shift ;
    my $output  = shift;

    #local $Carp::CarpLevel = $level ;
    #print "PARSE $type $key $value $validate $sub\n" ;
    if ( $type & Parse_store_ref)
    {
        #$value = $$value
        #    if ref ${ $value } ;

        $$output = $value ;
        return 1;
    }

    $value = $$value ;

    if ($type & Parse_any)
    {
        $$output = $value ;
        return 1;
    }
    elsif ($type & Parse_unsigned)
    {
        return $self->setError("Parameter '$key' must be an unsigned int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be an unsigned int, got '$value'")
            if $validate && $value !~ /^\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1;
    }
    elsif ($type & Parse_signed)
    {
        return $self->setError("Parameter '$key' must be a signed int, got 'undef'")
            if $validate && ! defined $value ;
        return $self->setError("Parameter '$key' must be a signed int, got '$value'")
            if $validate && $value !~ /^-?\d+$/;

        $$output = defined $value ? $value : 0 ;    
        return 1 ;
    }
    elsif ($type & Parse_boolean)
    {
        return $self->setError("Parameter '$key' must be an int, got '$value'")
            if $validate && defined $value && $value !~ /^\d*$/;
        $$output =  defined $value ? $value != 0 : 0 ;    
        return 1;
    }
    elsif ($type & Parse_string)
    {
        $$output = defined $value ? $value : "" ;    
        return 1;
    }

    $$output = $value ;
    return 1;
}



sub Compress::Raw::Zlib::Parameters::parsed
{
    my $self = shift ;
    my $name = shift ;

    return $self->{Got}{lc $name}[OFF_PARSED] ;
}

sub Compress::Raw::Zlib::Parameters::value
{
    my $self = shift ;
    my $name = shift ;

    if (@_)
    {
        $self->{Got}{lc $name}[OFF_PARSED]  = 1;
        $self->{Got}{lc $name}[OFF_DEFAULT] = $_[0] ;
        $self->{Got}{lc $name}[OFF_FIXED]   = $_[0] ;
    }

    return $self->{Got}{lc $name}[OFF_FIXED] ;
}

sub Compress::Raw::Zlib::Deflate::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
            {
                'AppendOutput'  => [1, 1, Parse_boolean,  0],
                'CRC32'         => [1, 1, Parse_boolean,  0],
                'ADLER32'       => [1, 1, Parse_boolean,  0],
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
 
                'Level'         => [1, 1, Parse_signed,   Z_DEFAULT_COMPRESSION()],
                'Method'        => [1, 1, Parse_unsigned, Z_DEFLATED()],
                'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                'MemLevel'      => [1, 1, Parse_unsigned, MAX_MEM_LEVEL()],
                'Strategy'      => [1, 1, Parse_unsigned, Z_DEFAULT_STRATEGY()],
                'Dictionary'    => [1, 1, Parse_any,      ""],
            }, @_) ;


    croak "Compress::Raw::Zlib::Deflate::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;

    my $windowBits =  $got->value('WindowBits');
    $windowBits += MAX_WBITS()
        if ($windowBits & MAX_WBITS()) == 0 ;

    _deflateInit($flags,
                $got->value('Level'), 
                $got->value('Method'), 
                $windowBits, 
                $got->value('MemLevel'), 
                $got->value('Strategy'), 
                $got->value('Bufsize'),
                $got->value('Dictionary')) ;

}

sub Compress::Raw::Zlib::deflateStream::STORABLE_freeze
{
    my $type = ref shift;
    croak "Cannot freeze $type object\n";
}

sub Compress::Raw::Zlib::deflateStream::STORABLE_thaw
{
    my $type = ref shift;
    croak "Cannot thaw $type object\n";
}


sub Compress::Raw::Zlib::Inflate::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
                    {
                        'AppendOutput'  => [1, 1, Parse_boolean,  0],
                        'LimitOutput'   => [1, 1, Parse_boolean,  0],
                        'CRC32'         => [1, 1, Parse_boolean,  0],
                        'ADLER32'       => [1, 1, Parse_boolean,  0],
                        'ConsumeInput'  => [1, 1, Parse_boolean,  1],
                        'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                 
                        'WindowBits'    => [1, 1, Parse_signed,   MAX_WBITS()],
                        'Dictionary'    => [1, 1, Parse_any,      ""],
            }, @_) ;


    croak "Compress::Raw::Zlib::Inflate::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;
    $flags |= FLAG_CONSUME_INPUT if $got->value('ConsumeInput') ;
    $flags |= FLAG_LIMIT_OUTPUT if $got->value('LimitOutput') ;


    my $windowBits =  $got->value('WindowBits');
    $windowBits += MAX_WBITS()
        if ($windowBits & MAX_WBITS()) == 0 ;

    _inflateInit($flags, $windowBits, $got->value('Bufsize'), 
                 $got->value('Dictionary')) ;
}

sub Compress::Raw::Zlib::inflateStream::STORABLE_freeze
{
    my $type = ref shift;
    croak "Cannot freeze $type object\n";
}

sub Compress::Raw::Zlib::inflateStream::STORABLE_thaw
{
    my $type = ref shift;
    croak "Cannot thaw $type object\n";
}

sub Compress::Raw::Zlib::InflateScan::new
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
                    {
                        'CRC32'         => [1, 1, Parse_boolean,  0],
                        'ADLER32'       => [1, 1, Parse_boolean,  0],
                        'Bufsize'       => [1, 1, Parse_unsigned, 4096],
                 
                        'WindowBits'    => [1, 1, Parse_signed,   -MAX_WBITS()],
                        'Dictionary'    => [1, 1, Parse_any,      ""],
            }, @_) ;


    croak "Compress::Raw::Zlib::InflateScan::new: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    #$flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;
    #$flags |= FLAG_CONSUME_INPUT if $got->value('ConsumeInput') ;

    _inflateScanInit($flags, $got->value('WindowBits'), $got->value('Bufsize'), 
                 '') ;
}

sub Compress::Raw::Zlib::inflateScanStream::createDeflateStream
{
    my $pkg = shift ;
    my ($got) = ParseParameters(0,
            {
                'AppendOutput'  => [1, 1, Parse_boolean,  0],
                'CRC32'         => [1, 1, Parse_boolean,  0],
                'ADLER32'       => [1, 1, Parse_boolean,  0],
                'Bufsize'       => [1, 1, Parse_unsigned, 4096],
 
                'Level'         => [1, 1, Parse_signed,   Z_DEFAULT_COMPRESSION()],
                'Method'        => [1, 1, Parse_unsigned, Z_DEFLATED()],
                'WindowBits'    => [1, 1, Parse_signed,   - MAX_WBITS()],
                'MemLevel'      => [1, 1, Parse_unsigned, MAX_MEM_LEVEL()],
                'Strategy'      => [1, 1, Parse_unsigned, Z_DEFAULT_STRATEGY()],
            }, @_) ;

    croak "Compress::Raw::Zlib::InflateScan::createDeflateStream: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        unless $got->value('Bufsize') >= 1;

    my $flags = 0 ;
    $flags |= FLAG_APPEND if $got->value('AppendOutput') ;
    $flags |= FLAG_CRC    if $got->value('CRC32') ;
    $flags |= FLAG_ADLER  if $got->value('ADLER32') ;

    $pkg->_createDeflateStream($flags,
                $got->value('Level'), 
                $got->value('Method'), 
                $got->value('WindowBits'), 
                $got->value('MemLevel'), 
                $got->value('Strategy'), 
                $got->value('Bufsize'),
                ) ;

}

sub Compress::Raw::Zlib::inflateScanStream::inflate
{
    my $self = shift ;
    my $buffer = $_[1];
    my $eof = $_[2];

    my $status = $self->scan(@_);

    if ($status == Z_OK() && $_[2]) {
        my $byte = ' ';
        
        $status = $self->scan(\$byte, $_[1]) ;
    }
    
    return $status ;
}

sub Compress::Raw::Zlib::deflateStream::deflateParams
{
    my $self = shift ;
    my ($got) = ParseParameters(0, {
                'Level'      => [1, 1, Parse_signed,   undef],
                'Strategy'   => [1, 1, Parse_unsigned, undef],
                'Bufsize'    => [1, 1, Parse_unsigned, undef],
                }, 
                @_) ;

    croak "Compress::Raw::Zlib::deflateParams needs Level and/or Strategy"
        unless $got->parsed('Level') + $got->parsed('Strategy') +
            $got->parsed('Bufsize');

    croak "Compress::Raw::Zlib::Inflate::deflateParams: Bufsize must be >= 1, you specified " . 
            $got->value('Bufsize')
        if $got->parsed('Bufsize') && $got->value('Bufsize') <= 1;

    my $flags = 0;
    $flags |= 1 if $got->parsed('Level') ;
    $flags |= 2 if $got->parsed('Strategy') ;
    $flags |= 4 if $got->parsed('Bufsize') ;

    $self->_deflateParams($flags, $got->value('Level'), 
                          $got->value('Strategy'), $got->value('Bufsize'));

}


# Autoload methods go after __END__, and are processed by the autosplit program.

1;
__END__


#line 1597
FILE   6414b4f2/Digest/SHA.pm  �#line 1 "/home/danny/perl5/lib/perl5/x86_64-linux-gnu-thread-multi/Digest/SHA.pm"
package Digest::SHA;

require 5.003000;

use strict;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK);
use Fcntl;
use integer;

$VERSION = '5.71';

require Exporter;
require DynaLoader;
@ISA = qw(Exporter DynaLoader);
@EXPORT_OK = qw(
	hmac_sha1	hmac_sha1_base64	hmac_sha1_hex
	hmac_sha224	hmac_sha224_base64	hmac_sha224_hex
	hmac_sha256	hmac_sha256_base64	hmac_sha256_hex
	hmac_sha384	hmac_sha384_base64	hmac_sha384_hex
	hmac_sha512	hmac_sha512_base64	hmac_sha512_hex
	hmac_sha512224	hmac_sha512224_base64	hmac_sha512224_hex
	hmac_sha512256	hmac_sha512256_base64	hmac_sha512256_hex
	sha1		sha1_base64		sha1_hex
	sha224		sha224_base64		sha224_hex
	sha256		sha256_base64		sha256_hex
	sha384		sha384_base64		sha384_hex
	sha512		sha512_base64		sha512_hex
	sha512224	sha512224_base64	sha512224_hex
	sha512256	sha512256_base64	sha512256_hex);

# If possible, inherit from Digest::base

eval {
	require Digest::base;
	push(@ISA, 'Digest::base');
};

*addfile   = \&Addfile;
*hexdigest = \&Hexdigest;
*b64digest = \&B64digest;

# The following routines aren't time-critical, so they can be left in Perl

sub new {
	my($class, $alg) = @_;
	$alg =~ s/\D+//g if defined $alg;
	if (ref($class)) {	# instance method
		unless (defined($alg) && ($alg != $class->algorithm)) {
			sharewind($$class);
			return($class);
		}
		shaclose($$class) if $$class;
		$$class = shaopen($alg) || return;
		return($class);
	}
	$alg = 1 unless defined $alg;
	my $state = shaopen($alg) || return;
	my $self = \$state;
	bless($self, $class);
	return($self);
}

sub DESTROY {
	my $self = shift;
	shaclose($$self) if $$self;
}

sub clone {
	my $self = shift;
	my $state = shadup($$self) || return;
	my $copy = \$state;
	bless($copy, ref($self));
	return($copy);
}

*reset = \&new;

sub add_bits {
	my($self, $data, $nbits) = @_;
	unless (defined $nbits) {
		$nbits = length($data);
		$data = pack("B*", $data);
	}
	$nbits = length($data) * 8 if $nbits > length($data) * 8;
	shawrite($data, $nbits, $$self);
	return($self);
}

sub _bail {
	my $msg = shift;

	$msg .= ": $!";
        require Carp;
        Carp::croak($msg);
}

sub _addfile {  # this is "addfile" from Digest::base 1.00
    my ($self, $handle) = @_;

    my $n;
    my $buf = "";

    while (($n = read($handle, $buf, 4096))) {
        $self->add($buf);
    }
    _bail("Read failed") unless defined $n;

    $self;
}

sub Addfile {
	my ($self, $file, $mode) = @_;

	return(_addfile($self, $file)) unless ref(\$file) eq 'SCALAR';

	$mode = defined($mode) ? $mode : "";
	my ($binary, $portable, $BITS) = map { $_ eq $mode } ("b", "p", "0");

		## Always interpret "-" to mean STDIN; otherwise use
		## sysopen to handle full range of POSIX file names
	local *FH;
	$file eq '-' and open(FH, '< -')
		or sysopen(FH, $file, O_RDONLY)
			or _bail('Open failed');

	if ($BITS) {
		my ($n, $buf) = (0, "");
		while (($n = read(FH, $buf, 4096))) {
			$buf =~ s/[^01]//g;
			$self->add_bits($buf);
		}
		_bail("Read failed") unless defined $n;
		close(FH);
		return($self);
	}

	binmode(FH) if $binary || $portable;
	unless ($portable && -T $file) {
		$self->_addfile(*FH);
		close(FH);
		return($self);
	}

	my ($n1, $n2);
	my ($buf1, $buf2) = ("", "");

	while (($n1 = read(FH, $buf1, 4096))) {
		while (substr($buf1, -1) eq "\015") {
			$n2 = read(FH, $buf2, 4096);
			_bail("Read failed") unless defined $n2;
			last unless $n2;
			$buf1 .= $buf2;
		}
		$buf1 =~ s/\015?\015\012/\012/g;	# DOS/Windows
		$buf1 =~ s/\015/\012/g;			# early MacOS
		$self->add($buf1);
	}
	_bail("Read failed") unless defined $n1;
	close(FH);

	$self;
}

sub dump {
	my $self = shift;
	my $file = shift || "";

	shadump($file, $$self) || return;
	return($self);
}

sub load {
	my $class = shift;
	my $file = shift || "";
	if (ref($class)) {	# instance method
		shaclose($$class) if $$class;
		$$class = shaload($file) || return;
		return($class);
	}
	my $state = shaload($file) || return;
	my $self = \$state;
	bless($self, $class);
	return($self);
}

Digest::SHA->bootstrap($VERSION);

1;
__END__

#line 718
FILE   '1cdee209/auto/Compress/Raw/Zlib/Zlib.so �jELF          >     B      @       h[         @ 8  @ $ !                               �     �                          "      "     @      P                    0     0"     0"     �      �                   �      �      �      $       $              P�td    �      �      �     �      �             Q�td                                                  R�td          "      "                                   GNU ��%y�g9�NP��M�]�c    �   7      
    ��  @

@�,        7               8       9   :       ;   =       ?       @   A       C   E   G   I   K       L   N   O   P       Q   S   T       U   V       W   X       Z           \   ]   ^   `   a   b   d   g   h   i       k   l       m       o           p   s   u       v   x       y   |              �   �   �       �       �   �   �           �   �       �   �   �   �           �       �   �   �   �   �           �   �       �   �   �       �       �   �   �   �               �       �           �   �       �               ����s�F�e�¥��Ҿ����*ĸ������=Ɵ9k��J4Q�9��J ������6�g/�PWN�%�*���)��	����U^݆N1+LA����t��+�B�-��]�wq�-#���U-/}�"j�����+��'�q�cE��a�D�}�q)X���+��o�;�����ln�Hؼ���UL��)s�)�şv=vc�oU��[X�8e��;epئ	0���UE�ƥ��{o���qX�9@���u���)��s���)%�¯�1���u#k(���1�����P'��8�%�P��Y[�}�f�{�(7N��ܽ��BhF;s��,����l���1�ߴ0�{�T�Qʉ�hC���_@f_�JR�W��[l��qD6��|K�������N�u]��9��!�E7��� �CE���z"a��z�2e����^�j�	��J��"�>L�Q-�ח_A�=��Pȇ#t�B��-�L�n�q��+��bd���--=�qݼΒ��$Qf��                             	 �<              �                     *                     �                     �                                           �
                     �
                     x                     Z                     �
                     F	                     %                       �
	                     M                     \
                     �                        "                   �                      R    @�             m    P�      
       "     �      9      �    �$     p       k    @�     L       :
    �            �   	 �<              �	    �b     6       B    �q            u     i            q    �K                0w     �      �	    p�      �      �
    0E     y      Z     �     �       �     �     1      [     
            �     �D            �    `�      �      &    �G     �      {    �^            M
    ��            :    @|            �    ��      =
      u    u     '      k    0
            �           7       #
     �      Y      j    �]           �	    0�      �      �    `m            �    �b            
    @�      �	      �    �u            ,    G            
    
    ��      }      �    �!     �        __gmon_start__ _fini __cxa_finalize _Jv_RegisterClasses XS_Compress__Raw__Zlib__inflateScanStream_adler32 PL_thr_key pthread_getspecific Perl_sv_newmortal Perl_sv_derived_from Perl_sv_setuv Perl_mg_set Perl_sv_2iv_flags Perl_croak Perl_croak_xs_usage XS_Compress__Raw__Zlib__inflateScanStream_crc32 XS_Compress__Raw__Zlib__inflateScanStream_getLastBufferOffset XS_Compress__Raw__Zlib__inflateScanStream_getLastBlockOffset XS_Compress__Raw__Zlib__inflateScanStream_uncompressedBytes XS_Compress__Raw__Zlib__inflateScanStream_compressedBytes XS_Compress__Raw__Zlib__inflateScanStream_inflateCount XS_Compress__Raw__Zlib__inflateScanStream_getEndOffset XS_Compress__Raw__Zlib__inflateStream_get_Bufsize XS_Compress__Raw__Zlib__inflateStream_total_out XS_Compress__Raw__Zlib__inflateStream_adler32 XS_Compress__Raw__Zlib__inflateStream_total_in XS_Compress__Raw__Zlib__inflateStream_dict_adler XS_Compress__Raw__Zlib__inflateStream_crc32 XS_Compress__Raw__Zlib__inflateStream_status XS_Compress__Raw__Zlib__inflateStream_uncompressedBytes XS_Compress__Raw__Zlib__inflateStream_compressedBytes XS_Compress__Raw__Zlib__inflateStream_inflateCount XS_Compress__Raw__Zlib__deflateStream_total_out XS_Compress__Raw__Zlib__deflateStream_total_in XS_Compress__Raw__Zlib__deflateStream_uncompressedBytes XS_Compress__Raw__Zlib__deflateStream_compressedBytes XS_Compress__Raw__Zlib__deflateStream_adler32 XS_Compress__Raw__Zlib__deflateStream_dict_adler XS_Compress__Raw__Zlib__deflateStream_crc32 XS_Compress__Raw__Zlib__deflateStream_status Perl_sv_setiv XS_Compress__Raw__Zlib__deflateStream_get_Bufsize XS_Compress__Raw__Zlib__deflateStream_get_Strategy XS_Compress__Raw__Zlib__deflateStream_get_Level XS_Compress__Raw__Zlib_ZLIB_VERNUM XS_Compress__Raw__Zlib__inflateStream_msg Perl_sv_setpv XS_Compress__Raw__Zlib__deflateStream_msg XS_Compress__Raw__Zlib_zlib_version zlibVersion my_zcfree Perl_safesysfree my_zcalloc Perl_safesysmalloc XS_Compress__Raw__Zlib__inflateScanStream_resetLastBlockByte Perl_sv_2pvbyte XS_Compress__Raw__Zlib__inflateStream_set_Append Perl_sv_2mortal Perl_sv_2bool_flags Perl_newSVpv Perl_mg_get Perl_croak_nocontext XS_Compress__Raw__Zlib_crc32 Perl_sv_2uv_flags Perl_sv_utf8_downgrade XS_Compress__Raw__Zlib_adler32 XS_Compress__Raw__Zlib__inflateScanStream_DESTROY inflateEnd Perl_sv_free Perl_sv_free2 XS_Compress__Raw__Zlib__inflateStream_DESTROY Perl_sv_pvbyten_force Perl_sv_upgrade XS_Compress__Raw__Zlib__deflateStream_deflateTune XS_Compress__Raw__Zlib__deflateStream_DESTROY deflateEnd XS_Compress__Raw__Zlib_adler32_combine XS_Compress__Raw__Zlib_crc32_combine XS_Compress__Raw__Zlib_zlibCompileFlags __errno_location strerror XS_Compress__Raw__Zlib__inflateScanStream_status Perl_sv_setnv XS_Compress__Raw__Zlib__inflateStream_inflateSync memmove XS_Compress__Raw__Zlib__inflateStream_inflate Perl_sv_grow inflateSetDictionary Perl_sv_utf8_upgrade_flags_grow XS_Compress__Raw__Zlib__deflateStream__deflateParams XS_Compress__Raw__Zlib__deflateStream_flush XS_Compress__Raw__Zlib__deflateStream_deflate XS_Compress__Raw__Zlib__inflateScanStream__createDeflateStream deflateInit2_ Perl_sv_setref_pv Perl_dowantarray Perl_newSViv Perl_stack_grow deflateSetDictionary deflatePrime XS_Compress__Raw__Zlib__deflateInit XS_Compress__Raw__Zlib__inflateScanStream_inflateReset XS_Compress__Raw__Zlib__inflateStream_inflateReset XS_Compress__Raw__Zlib__deflateStream_deflateReset XS_Compress__Raw__Zlib__inflateInit inflateInit2_ Perl_newSVsv XS_Compress__Raw__Zlib_constant Perl_newSVpvf_nocontext Perl_sv_2pv_flags Perl_sv_setpvn __printf_chk putchar puts XS_Compress__Raw__Zlib__inflateScanStream_DispStream XS_Compress__Raw__Zlib__inflateStream_DispStream XS_Compress__Raw__Zlib__deflateStream_DispStream XS_Compress__Raw__Zlib__inflateScanStream_scan boot_Compress__Raw__Zlib Perl_xs_apiversion_bootcheck Perl_xs_version_bootcheck Perl_newXS Perl_get_sv Perl_call_list adler32_combine64 get_crc_table crc32_combine64 inflateBackInit_ inflateBack inflate_table inflate_fast zmemcpy inflateBackEnd inflateResetKeep inflateReset2 inflateInit_ inflatePrime __stack_chk_fail inflateGetHeader inflateSyncPoint inflateCopy inflateUndermine inflateMark uncompress compress2 deflateInit_ compressBound zmemzero _tr_flush_bits _length_code _dist_code _tr_flush_block deflateResetKeep _tr_init deflateSetHeader deflatePending deflateBound z_errmsg _tr_stored_block _tr_align deflateCopy deflate_copyright inflate_copyright _tr_tally zError zmemcmp libc.so.6 _edata __bss_start _end GLIBC_2.3.4 GLIBC_2.14 GLIBC_2.4 GLIBC_2.2.5                                                                                                                                                                                                                                            s         ti	   �     ���   �     ii
           P "                   X "        �           ` "                   h "        
  �%i H����5J�! �%L�! @ �%J�! h    ������%B�! h   ������%:�! h   ������%2�! h   �����%*�! h   �����%"�! h   �����%�! h   �����%�! h   �p����%
�! h   �`����%�! h	   �P����%��! h
   �@����%��! h   �0����%��! h   � ����%��! h
�! h(   �`����%�! h)   �P����%��! h*   �@����%��! h+   �0����%��! h,   � ����%��! h-   �����%��! h.   � ����%��! h/   ������%��! h0   ������%��! h1   ������%��! h2   ������%��! h3   �����%��! h4   �����%��! h5   �����%��! h6   �����%��! h7   �p����%��! h8   �`����%��! h9   �P����%z�! h:   �@����%r�! h;   �0����%j�! h<   � ����%b�! h=   �����%Z�! h>   � ����%R�! h?   ������%J�! h@   ������%B�! hA   ������%:�! hB   ������%2�! hC   �����%*�! hD   �����%"�! hE   �����%�! hF   �����%�! hG   �p����%
�! hH   �`����%�! hI   �P����%��! hJ   �@����%��! hK   �0����%��! hL   � ����%��! hM   �����%��! hN   � ����%��! hO   ������%��! hP   ������%��! hQ   ������%��! hR   ������%��! hS   �����%��! hT   ����H��H���! H��t��H��Ð��������U�=�!  H��ATSubH�=��!  tH�=�! ����H���! L�%��! H���! L)�H��H��H9�s D  H��H���! A��H���! H9�r����! [A\]�f�     H�=x�!  UH��tH���! H��t]H�=^�! ��@ ]Ð�����AVAUATI��USH�^�! �;�����;L�(�����H�Pp�;�*H��H�Pp�����H�HHcՋ;H��I)�I��A����  �����H�@�;�@# �
���H�@H��H�@H� H�@ �;L�pH�,�����������;Hh�����L��L��H�������A�D$@t�;����L��H��������;L�e�����;H������LhL�m []A\A]A^� �����;L�`�x���H�@H�@M�$�������    �[���H�@�;H��L�p�H����   H��L���(����<����;�,���L��e H�
�    H��@��t	f�  H����t� H���! H�BXH��! H�B`H��H����     H�x�  @�@��t�f�  H����@��t�fD  �    ��H���o���fD  AUATI��USH��H��! �;赵���;L�(諵��H�Pp�;�*H��H�Pp薵��L�PHcՋ;I��I)�I��A����  �s���H�@��Hc�H���@
���H�$H�@H��H� �@ �D$������    1�1�1�荬��H��Hct$H�T$H�,�����+T$L��l����;I��責���;Hh觬��L��H��L��虭��A�D$@t�;芬��L��H��蟮���;L�e�t����;H���j���LxL�} H��([]A\A]A^A_� �;�I���H�T$L��H��蹬��I���T�����;�)���H��P  �@8��   A�F�����    ����H�@J��H�@�@ �  ���K����     �۫��H�@�;N�,��̫���   H��L������H�������@ 諫��H�$H�@�;H�4�H�4$蔫��H�4$�   H���s����D$�]���f.�     �;�i����   L��H���������9���H�=Z! 1������>���H�� L��H���L���fff.�     AWAVAUATI��USH��H�X�! �;�����;L�0�����H�Pp�;�*H��H�Pp����L�xHcՋ;I��I)�I��A�F����z  輪���;H�@��Hc�L�<�    L�,�蟪��H�@�;�@# ��   芪��H��肮��I��H�5� L���P���I�ŋ@�    �  %   =   �G  I�E M�mH�@H�D$A����   �;L�u�)���H�@�;J���x�U  ����H�@J���@ �  ����tb�;����H�@�;J���@
  �ϓ���;H�@��Hc�L�<�    L�d�豓��H�@H���@
  腏��H�T$H�@A��H��H�@H� H�h �  H�5X�  L��L���   �-����E H�D$��   �@�   ��  �    ��   %  )=   ��   A�<$����H�t$H�T$8H���ʑ��H�L$H�EH�5��  H��H�H�@�E �(����@ I���D$/ �  �E uI�E H�@    �E8    I�U H�BH����   �E �R�T$(��  �T$(��H9��+  �E8�D$    �}    H�L$�A�    �0���A�<$�L���H��P  �@8�?  H�T$�B%  )=   ����H�T$H�H�@H�D$8H�B����f�     1��D$    �D$(    �T$(Hǅ�       L�}�T$�qD  �   L���3���������   �E t�������  ���~  �����  ���f���  ����  �����  �����   ���C  �E8��u�I�E A�<$H�@I�\�J���H��L��H���l����L$L$�T$D�t$D�u8M�H�H�E0�H����     H���   H���H���H�UxL��H���   H�H�pH�R�r��������q������� �E8����t�} ���  ǅ�   �����ЋU �L$+L$(L$D�t$()�H��   H���   H�L$H�H�@H��   H)�L��H���   A�E%� �_��DA�EH��   I�E �|$/ H�PI�E I�UH�@� �B  A�E@�]  �E ��q  ���  �E t:H�T$�E H�
����H�Q��  H�T$H�H��H�RH�@� �A@��  A�<$�ˋ��H�l$ A�<$Hh蹋��H��豏��H�E A�<$褋��H�T$H�@A�<$H�,�莋���*�H��H��H�-��  舊����t
�������H��A�<$�a���H�L$H�@A�<$H���K���H��H��H��荋��A�<$�4���H�T$H�@A�<$H�ЁH "  ����A�<$H������H�@HD$ H�H��H[]A\A]A^A_Ã������	҉��   ��  ���������E8�U ������H�P�H)�I9��#���A�<$I�\蠊��H��L��H�����I�E H�@�����D  �{���H�L$H�@A�<$H��H�h�a����   H��H���A���A��H�������A�<$�;���L�t$H�@I��J�<� �����A�<$����H�@A�<$J���@
����U8����H�=��  1����������7���f�     AWAVAUATI��USH��H�Hg! �;�����;L�(����H�Pp�;�*H��H�Pp�҆��L�PHcՋ;I��I)�I��A����  ��謆��Hc�H�@�;L�eJ���@
������I�ċ} ����H�@�} J������L��H��H���C����} ����H�@�} J���H "  �����} H������H�@HD$(H�H��8[]A\A]A^A_�fD  ���H�@A��J���D$   H�@H� H�X ������} M�n�r��H�@�} J���@
������I�ŋ} �Cz��H�@�} J���3z��L��H��H���uz���} �z��H�@�} J���H "  �z���} H����y��H�@HD$(H�H��8[]A\A]A^A_���y��H�@�} J��H�X��y���   H��H���x��H�������    H�t$H�F�S���f.�     �} �y��H��P  �@8��   H�T$�B�����f.�     �} �Xy��H��P  �@8�C����} �?y���   L��H���x�����#���H�=��  ��z�� �S H�sH�{�z��H�C������    H�{H���x���H�C�����1�1������    �} �L$��x��L��H����z���L$������} �x��H�t$�   H���&x����tRH�L$�A�����x��H���  H��H���y���} �fx��L���  H�
o��H�@�;J���@
�  1���k���j��H���  L��H���,k��fff.�     AVAUATI��USH�>J! �;��i���;L�(��i��H�Pp�;�*H��H�Pp��i��L�@HcՋ;I��I)�I��A����  �i��H�@��Hc�L�4�    H���@
   H�5��  �,���L��A�   ��Z������������D  �;�Z��A�G<U�|  <X��  <F�����H�5��  �	   L���Z���������L��H�=��  ������A�G<R��  <S�����H�5��  �   L��A�   �aZ�����q�������@ �;�Y��A�G��D<�e���H�:�  ��Hc�H���fD  �   H�5��  �����    H�5��  �   L��A�   ��Y����������
   L��A�   �X�����.����=���H�5��  �   L��A�   ��W�������������   H�5��  �����H�5�  �   L��A�   �W���������������   H�5L�  �����   H�54�  �����   H�5�  ����H�5��  �   L��I�������dW�����t��������   H�5��  �F����   H�5��  �5����   H�5d�  ������   H�5F�  ���� H�5�  �	   L��A�   ��V������������f�     �
   H�5ӿ  �{����    H�5�  �   L��I�������V���������������;��U��H��  L��H����V���    UH��S1�H��D  �T H�5��  1��   H���X��H��u�H��[]��    ATH��1�UH��H�5w�  SH���   ��W��H��tH�5m�  H��   1��W���
   �[T��H���  H�SH�5b�  �   1��W��H�SXH�5f�  �   1��tW��H�S`H�5j�  �   1��]W��H�ShH�5n�  1��   �FW��H�SHH����  H�5i�  �   1��&W��H�SH�5��  1��   �W��H�{ tH�5��  �   1���V��H�{�����
   �S��H�S0H�5[�  1��   ��V��H�{0 tH�5=�  �   1��V��H�{0�x����
   H�-$�  L�%%�  �@S���S H�5$�  �   1��zV���S8H�5(�  �   1��dV��H�S(H�5+�  �   1��MV��H�S@H�5.�  �   1��6V��H�SxH�51�  �   1��V��H���   H�51�  �   1��V��H���   H�51�  �   1���U��H���   H�52�  �   1���U�����   H�54�  �   1��U��H�SH�56�  �   1��U��H�SH�5:�  �   1��U���H�5@�  �   1��tU���H��H�5B�  �   ID�1��WU���H��H�5>�  �   ID�1��:U���H��H�5:�  �   ID�1��U���H��H�56�  �   ID�1�� U���H��H�52�  �   ID�1���T��H���   H�5-�  �   1���T��[]A\�
   �kQ�� H�=�  �Q�������    []A\H�=E�  �Q��AUI��ATUSH��H�\2! �;�R���;L� ��Q��H�Pp�;�*H��H�Pp��Q��H�HHcՋ;H��I)�I��A�D$�����  �Q��H�@��Hc�H���@
���q���I��A�<$��E��H�@A�<$J����E��L��H��H���&F��A�<$��E��H�@A�<$J��H "  �E��A�<$H���E��H�@HD$H�H��([]A\A]A^A_�fD  A�<$�E��H�T$L��H���?H������f.�     A�<$�WE��H��P  �@8��  A�F����D  �3E��H�@A�<$H���@
H��J�H�� ���H9�HB�H9�u�A��D�u�ǃ�    �  ����f�     A�<$�D��L��H���F�������    1�H�S(���   H���   I�H�RH��   H)�H���   �^���H�S(���   �K H���   I�H�@H)�H��   ���0�������D  �C � A�<$�wC���   L��H����B��������H�=��  1��!E����KC��H�@A�<$H�,��:C���   H��H���*B������D�} H�u��  H���_D��D���  ����� ��)�9�w��fD  ���)�9�v����s���D���  H�}��  H���fE��D�} ����A�<$�B��L�5�  H�
�  H���A���;�?��H��! H�
�  H���R>���;�[<��H�,! H�
>���;�<��H��! H�
�  H�5
�  H����=���;��;��H��! H�
I�H��VI�H��VI�H��V
I�H��HI�H��HI�H��H
H��H��u�J�I��I��   u���ffff.�     ATI��UH��SH��H��   H����   � ���H��$   �   H��$   H��$  �H�H��H�H9�u�H��$   H���Q���H��$   H���A����H��$   H���0���A��tH��t1�H����tH3H��H��u�H��I��t@H��$   H�������A��t%H��t H��$   1�f���tH3H��H��u�H��I��u�H1�H��   H��[]A\�D  H�Y�  ��     1�H��S�	  A�����I1�����   D�R�H�
D�J@��9��r  ��u�H�t$xH��A�ׅ��Q  A�}p�D  ��
  ��������I����=  A�E|A���   A�Mx�C  ���:  Aǅ�       �؉�D��H�l$M��L�l$ ��w+���~  fD  H�t$x���H��H�t$xH���I�A���   H��  E��A��I���������<zfE���   A9wxA���   w���M����A�߉É�w'�    �����J��fAǄM�     v�A���   H�L$@I���   L�L$HL�D$P1�A�Ep   �   H��H�D$`I���   I�M`I���   H�L$X�-�����v  H�p�  I�V0A�E    �   ����f.�     H��  I�V0A�E    �   �Z��� I�͉݉�L��A��H��H����  H9���  H��  �   I�F0A�E    �����H�D$(E�~ A�^I�FH�D$xI�A�u4A9u8M�eHA�mPs	��D)�A�E8L���+��I�VI�E�~ A�^M�eHA�mPH�T$(H�D$xA�U ����f.�     I�͉݉�D��I���A�ED�������F  ���Q  ����  A�E 
D�R@��B�?9��K  ��u�H�t$xH�|$ �T$��u���L�t$X1Ҹ�����`����    ����A�ET�[  L�t$XL�d$(L�t$8�L�E��ts9�D��H�t$xF�L��D9�FŉD$�:)���D$A�mT��)�)�HT$xA)�Iԅ�A�mT��   ��u�H�t$xH�|$ �T$����u�L�t$X1Ҹ���������@ E�}4M�e@L��E�}8D��L���T$0���l���L�t$XH�T$x��������� @�Ɖ�E��I��)�E�MTE���y  H�T$(A�ETA���H��A�E    H�T$(�   �1�����<���H�
��E)���   �C<�S4D�9ЉC<�}   �K81�9�vA�D�k8H�\$H�l$L�d$L�l$ H��(�@ �K0��C<    �C8    ��S4D+e A9��l���H�uH�{@��H)�����C4�C<    �C81���     �K81��C<    9��x����z����    H�uH�{@D��D��H)��:���C4D�c<�C81��L���f�     �K0�   �   H�P���U@H��H�C@�   H�����������H����   H�G8H����   H�@     H�G(    H�G    H�G0    �P��t��H�W`H��P  �     �@    �@    �@ �  H�@(    H�@H    �@P    H���   H�PhH�P`ǀ�     ǀ�  ����1�ø����ø����ÐH��t+H�G8H��t"�@4    �@8    �@<    �����     ������f.�     H�\$�L�d$���H�l$�L�l$�H��(H��I����   H�o8H����   ��xiA����A����A����/N؍C���w[H�u@H��t;]0tI�|$PA�T$HH�E@    D�m�]0L��H�\$H�l$L�d$L�l$ H��(���@ ��E1��f�     ��t�@ �����H�\$H�l$L�d$L�l$ H��(�f.�     H�\$�H�l$�H��L�d$�H��(H�҉���   ��p��   �:1��   H����   H�G@H�G0    H��tsH�H tlH�P��  �   ��H��I��tdH�C8��H�@@    H�������t�D$H�{PL���SH�D$H�C8    H�\$H�l$L�d$ H��(�@ ������ᐸ������f�     �������f�     ��H��   �1���H��teH�8H��t=��xF�������4D�OPF�A�� w&��   D�GPH��D�Ƀ�!���H�HGH1�ø������fD  H�GH    �GP    1�ø�����AWI��AVAUATUSH��   dH�%(   H�D$x1�H���t$4tfL�o8M��t]L�WM��tTH�/H���E  A�E ����  �L$4A�WI��P  E�_ M�uHE1�A�]PH�t$@���T$0A��D�\$,�L$X��v=A������    H�L$xdH3%(   D���W  H�Ĉ   []A\A]A^A_��    I��  H�T$8H�
   E�ME����  1�1�1�D�$L�T$D�\$����I�EI�G`A�E    D�\$L�T$D�$�|$X�{
  L�T$HD�D$P�T$lD�\$hD�D$`D�T$d�T$\�f.�     E���a  �E �ك�A��H��H����I�D��D!���D�I���A�1D�Y���9�w�L�T$H�T$lfD�\$HD�\$hD�D$P�L$P�L$\)�I��f�����)ËD$PI��@��A���  �D$HA�ET��  A�E    �   �����    A�U\����  A�ETA���  A�E    A�Mt�   I�uh�����D$HD!�H���B�:D�J��9�sOE����	  �ًD$H�	E���'
  ��������I����=  A�E|A���   A�ux�  ����
  f������  f���	  �w9�s8E����  ����    E���/  �U A��H��H���I�9�rމˉ������I��)�1�D���I������D�9T$H��  f.�     D��A��A9�fA��E�   u�E���   ������    ��w8E���  ���fD  E����  �E A��H��H����Iƃ�v݉�A��D��E�u�
  A�E    1�E1�� A�E���k  ��w9E���%  �� �fD  E����  �U A��H��H���Iփ�v�I�U(E�uTH��tD�r A�E���R  ��1�E1���   A�E    �A�E��   ��t!A�UTA9ԉ�AF̅���  ����  A�EA�ET    A�E    ���  E���m  1� �ȃ��T I�E(H��D��tH�x(H��tA�uT;p0s�����A�uTE��tD9�r�A�E�	  A)�H�E���  A�EA�ET    A�E    ���b  E����   1��    �ȃ��T I�E(H��D��tH�x8H��tA�uT;p@s�����A�uTE��tD9�r�A�E��  A)�H�E����   A�EA�E    ���Z  ��w2E��th���
  ��w:E���������f��fD  E���  �E A��H��H����Iƃ�v݉ˋT$,D)ډ�IG(IE ��t?L��I�}H)�A�ED�$L�T$D�\$����
  ���D�$L�T$D�\$I�EI�G`E�ML��E��u5L��H��H��% �  ���   H�L��% �  H��H�L��H�����H�I;E�  H�v�  D�\$,I�G0A�E    �   �N���f�A�E���w	  A�}���k	  ��w8E����������fD  E���  �E A��H��H����Iƃ�v݉�A�E L9��	  H��  I�W0A�E    �   ������A�   �%���D  �ك����I���w5E��������� E����   �E A��H��H����Iƃ�v݉�L��A��H��H5��  H9���  H�5��  �   I�w0A�E    �@���@ A�E�����    A�E�����    A�E������    ���i���f�     ��1��9���fD  I�}H)Ɖ�D�$�~��D�$�����D  ������1�����1�E1� I�U(H��t��	���BDI�E(�@H   1�1�1�D�$L�T$D�\$�2��I�EI�G`�   A�E    D�$L�T$D�\$�V���f.�     D�_A�����E�������������     I�U(H��� ���H�B8    �����fD  I�U(H���X���H�B(    �G���@���� �2  Aǅ�  ����fD  A�E    �   �����fD  L��H)�A�ET��D9�AG�)�A)Ã�H�pA�UT1� �A�H��H9�u�A�MTI�� ���A�E �����    I�M(1�H�������H�A    A�E��   �����I�u(H��tTH�~H��tK�F )ЋV$�L$D�D�$L�T$D�\$��)�A9щ�G�H�H������A�ED�\$L�T$D�$�L$����  A�UT��A)�H�)�A�UT���� 9�s8E�������ِ�fD  E��������E A��H��H����I�9�rމˉѸ   )���A��  ��D!�AETI��A�ET�����A�ED�\$,1�E1�fD  A�E    ����� A�E    �   �"���fD  A���  ���D���H�5!�  �   I�w0A�E    �����@ A���  �ȉL$P�L$P��T$P)�I���D$H@A���  ��  H�5��  �   I�w0A�E    ����f�)�D��A��fA��E�   I��E���   �y���A�E    �   �����D  I�}��H��L$D�$D�L$ L�T$D�\$����I�ED�\$L�T$D�L$ D�$�L$����� A��  ������t$,M�WL��E�_ I�/E�gM�uHA�]PD�$�\��A�E M�WE�_ I�/E�gM�uH��A�]PD�$�r���Aǅ�  ��������@ ���|$P�����@ I�}��H��L$D�$D�L$ L�T$D�\$�+��I�ED�\$L�T$D�L$ D�$�L$���� H���  I�G0A�E    �   �7��� )�IM@�x���D  E�Ƀ�A�E    E�MXA�}\����I�}H�t$pD�t$p�   I��D�$L�T$D�\$D�t$q� ��I�EA�ED�\$L�T$D�$�����L�T$PD�\$dD�D$h�����|$4H�5r�  H�k�  A�Ep	   A�Et   I�u`I�EhA�E    �b  �   ����H�
tkD��L�sD�{ I��C     D��L�kH��������D�{ L�sup�E   1�H�\$H�l$L�d$L�l$ L�t$(L�|$0H��8�@ �} 
�����u�1�1�1������D��L��H�������H��H9U������j�����     �E    ������f�������f�     H��t-H�W8�����H��t�BtH�r(1��FH    �f�     �ø������     AUATUSH��H��dH�%(   H�D$1�H���D  H�o8H���7  �����  �} ��  �UPH�EH�E    �у�����UPH����H�EH��  �z�H�L$H��I����A��I��
H����t1���tH��D  �rTH��f�     ���  +rTH��H��  ���H��  ��Ð��U�Ƚ����SH��H��xH9�H�$�L$u?H�H�|$�D$ H9�u,H�5�\  �p   H��H�D$@    H�D$H    ���������tH��x��[]� �   H����������t$H��������t+���u΋D$�������D��f�H�D$(H��H��p�����먽����롐����U�����SH��H��xH�H�$�L$H�|$�D$ H9�u8H�
��ATUS�_D������A9�v
E��  A)�Lc�D���   O��
  C�\�L�g`�oLL�L$��\$�C�A��A��;��   �\$�AC�E9�EG��"f�     !�A�4tA9��P  ���G  ��Lc�L�F�D:L$�u�F�D�D:D$�u�A�8u�A�_8Yu�I��H���D$��AI�_A8G�  �AI�_A8G��   �AI�_A8G��   �AI�_A8G��   �AI�_A8G��   �AI�_A8G��   �AI�_A8G��   H��I���A8uL9|$��g����D$�H�L$��  D�L$�D�D$�L)�L�|$�)�I��  9������A9މ��   ~'L�L$�Hc�E�D�A������D�D$��D$���������f.�     []A\D9�AG�A]A^A_ËD$�I���w���f�AWAVAUATUSH��H��(�oD���   �E�A��D������O�t- ��H�H�D$f.�     H�CX���   D�)�)�9��g  L�;A�O���  1�9�H�{PD���   ���   �-  L�A�wI�7H��L$H�T$H�|$���+���I�G8�L$�@,���o  ����  ��IIG���   ��  щ��   �����   ���   H�KP)��<1�r�{p�41���   ��1�#s|�spf�     ����  H�KP�B�sp����   ��H�Kh1�#C|�Cp�4A��#KLH�C`f�4H�KpH�Chf�H��  �����   ���4��  ��w���  ��   H��@����   �sD�����     ����  1������H�{P��D$J�4/������KtH�sh)��   )��   �D$��L)��   ��H�VH�I��I)�I��f�     H��1��2��f)�9�F�L9�f�
u�L��HS`I��L+D$I��f�H��1��2��f)�9�F�L9�f�
u�L�;�A�O�������@ H��(  H�CXH9�s@���   ���   H�H9�sLH)�A�  H��H=  LF�H{PD��L��g���H��(  H��([]A\A]A^A_Ð���   ����D  H��  H9�s�H)�H)�H��  H9�HG�H{P������H�(  H��([]A\A]A^A_��    I�`H�t$���X���I�G`�L$�}��� I�`H�t$�ʉL$�D���I�G`�L$�Y����Ή�)�����fff.�     H�\$�L�d$�H��H�l$�H��H�o8H������D�e(D9c DFc E��uH�$H�l$L�d$H���f�     H�u H�{D�������D��HCHE HC(D)c �E(D)����E(u�H�EH�E �fD  U��SH��H�����   �    =  �  ���   H�SP���   �G#{L��Sp��1�#C|H�Sh�Cp�4BH�C`f�4x�Sp��H�Ch���   f�P���   ���   ǃ�      ���   ���   t!;��   s���   �KD)��  9���  ����  ;��   ��  ���   ���   �����  H��   �f+��   ��D�B���fD�qD���  H���  D��A���H�
���   ��H�Kh1�#S|�Sp�QH�S`f�B�SpH�Ch���   f�P���   ���҉��   u����   ǃ�       ǃ�      ��E9ȉ��   ��  ���   =  �����H��������틃�   �  ���  ����������   ���   ǃ�      �����   ���   �D���D���   E����   ���   H�SP���  ���H��   f�H  ���  H���  ��������  f����   ���  ��9���   ���   H����   �����   D�R E������1�H��[]Ð���   ǃ�      ���   �����   ����� f��H��   H�V�  %�  �������     ���   H���   1�H)�H��x��HsPH��1��y������   H�;H���   ������?����    H��� ��������   w���   tp��tX���   �����@ H���   1�H)�H��x��HsP1�H���������   H�;H���   �b���H��@ ���������������   +��   =   v�ǃ�      �=  ������������D���   E��u���   �   ��F���  ��   D���  �   E���t���H���   1�H)�H��x��HsP1�H���K������   H�;H���   ����H��x 1�����H��[]Ë��   H�SP���  ���H��   f�J  ���  H���  �у�����  f����   ǃ�       �*���H���   1�H)�H��x��HsP�   H���������   H�;H���   ����H��x ��������U��SH��H��D  ���     �`  ���   H�SP���   �G#{L��Sp��1�#C|H�Sh�Cp�4BH�C`f�4x�Sp��H�Ch���   f�P�7  ���   �CD-  ��)�9���  ���   ����  f+��   ���  ��H��   f�q���  ��H���  �΃��7H�5-�  �����  �f����  f��� �  H�%�  ���H�1�f����	  ���  ���   ��9����   @��)�;��   ���   ��  ���y  �����   ���   H�SP���   �p�����   ��Sp#sL��1�#C|H�Sh�Cp�BH�C`f�p�SpH�Ch���   f�P���   �������   u����   ���M������   H���   1�H)�H��x��HsP1�H���������   H�;H���   �����H��p ������1�H��[]�f.�     H�CP���  1��H��   f�H  ���  H���  ��������  f����   ���  ��9�@�ǃ��   �8���@ H��������틃�   ��   ����   ���y������   ���   ������     ���   H�KPǃ�       Љ��   ����Sp����   ��1�#C|�Cp�����    f��H��   H��  %�  �������     H���������   ���   �G���=  ��������B������   �   ��F���  t^���  �   �������H���   1�H)�H��x��HsP1�H����������   H�;H���   �/���H��@ ����H��[��]�H���   1�H)�H��x��HsPH�߹   �������   H�;H���   �����H��x �H��[��]�fffff.�     AT���  A��USH�oH��H��H����  HC�fD  ���   ����   ��   H���   ǃ�       H�L �҉��   t��H9�wX)�1����   ���   ��H)�H��x��HsP1�H����������   H�;H���   ����H�D�H E��ta���   H���   �KD��)Ɓ�  9��W���H)�1�H��x��HsP1�H���e������   H�;H���   �����H�D�@ E������1�[]A\�f�     H���������   ����E��tp�������A��ǃ      te���   H���   �   H9�~�H)�1�H��x��HsP1�H����������   H�;H���   �*���H��x 1������j�����������[������   H���   1�H)�H��x��HsP�   H���q������   H�;H���   �����H��x ����
�  ǃ�       Hǃ�       ǃ�       ǃ      ǃ�      ǃ�      ǃ�       H���Cp    H��J���   �
���   �J�R���   ���   �D$H��[�D  H��tH�W8�����H��t
ø�����    �ø�����AVH��AUA��ATUS���~   L�g8M��tuI�T$ �����H��I9�$   rTA�    A��$$  D���   L��)�9�N��������A��$$  D!���fA	�$   � �����A��)�u�1�[]A\A]A^ø������D  H��t%H�G8H��t"���   ���   ���   D���   1�ø����ø�����f.�     L�FH�F?L��H��H��H�H�H����   H�O8H����   �y,����   ��t ��H�H�҃��yHtH�D��     H�y0�   H��t�H� t
�W ��H��L�O(M��tI)�D  H��A�|� u�L�O8M��tI)��     H��A�|� u�D�_DL�JE��IEуyHu��yx�w���H��H��H��H��H��L�H�H�H��fD  ���   H�H���H��
�5���f�     H���ff.�     AWAVAUATA��UH��SH��H���3  ��H�_8�&  H���  ���  H� ��
  H�? �p
  A���CA���E  D�E E���  ��*D�s@H�+D�c@�  ��E��  ��I�S(��  ��[��	  ��g��
  ����  �E����   �S���  ��  ����  ���   ���  ���=  Hc��   H�'�  D��H��H���T���H���@��	����  ����  D�} 1�E��u�C@����H��[]A\A]A^A_�fD  1�A��C�4$��C�6��)�1�A����)�9��@���E���7���H��  H�@8H�E0������D  H���   1�H)�H��x��HsP1�H���/������   H�;H���   ����H��@ ���E������   �   ����   H�SP���  ǃ�       �H��   f�J  ���  H���  �ʃ�����  f����   ���  ���   ���   ������9񉃤   ���   �2������z���H���b������   ���d���E�������A��ǃ      �=
����'���1�E��f��U����S,����H������	  H�U`�C(H�sH��������@�<H�s�H��HH�s�K(�U`����@�<H�s�H����C(H�������C,��~�؉C,�[(1�����H��[]A\A]A^A_�@ H��������u ��������E�)���D  �{,�&	  �KH1����� x  ���   �i  ���   	�H�s���Cq   �� �Һ�BEȉ���)����������)ЍP�C(�׉���@�<H�s�H����   �P�S(��tFH�M`H�sH������@�<H�s�P��HH�s�K(�U`����@�<H�s�H����C(1�1�1�����H�E`�C��E����H�{0D�K(H��H� �+  �W 9S8�[  D���@f�     �K8H�w���4H�K@�4�K8H�C0�S(���K8D�@ H��A9��  ��H;Cu��GD��t	A9���  H���Y���D�K(D��H;CD����  D��H�{0�@ A�  �   D  ǃ�       ���   E1�H�KP��tA��J�t���>8V��   fD  B����  H��   f�H  ���  H���  ��������  f����   ���  ��9������   ���   ������  ���   =  �T���H�������E�䋃�   ��  ����  ��ǃ�       �,���H�KPD���   �J������   ����������@�}���������   E��k���fD  D�FD9��
���D�FD9������H��N��  �lfD  D�FL�VD9�ufD�FL�VD9�uXD�FL�VD9�uJD�FL�VD9�u<D�FL�VD9�u.D�FL�VD9�u H��D�D9�uI9�vD�FL�VD9�t�L��I)�D��D)�9Ɖ��   ��  ���   �Ƌ��  H��   �V�f�H ���  H���  �����H�
�C(�v@�4H�{0D�K(H� H��t3�O H�CB��BH�sD�J�C(��H�C0�@ ���H�{0D�K(H���wD����   �C8    �CE   �'���)�HsH�}`����H�E`�S(����D��HsH�}`D)������H�E`H�C0�S(�q���)�HsH�}`�����H�E`�S(�l������Y�������fD  A�   �8���A�   �-������   H���   1�H)�H��x��HsP�   H����������   H���   �����H�������A���H�CH�}`D��H���>���H�E`H�{0D�K(H�����������������H�C�0 H�K�B� H�K�B� H�K�B� H�K�B� ���   �B�   �C(HC��	t���   �   ~�H�K�B	��
��S(�Cq   �������������fD  ATUS��H��H���
  H��x  1�H��[]A\A]Ð�������f�     H������������Ր������͐��������AW�GL�_8L�OAV��AUL�/I��L��ATI��UL�SE�C8A�KtA�[4H�D$��G D�D$�A�   E�{<�\$�M�S`)�-  M�shH)�D��L���A�KpH�D$�I�C@��H�T$�H�t$�A�SP�   A��D��H�D$�D�D$ă�H�\$�I�CHH�L$�A�O�E�H��H��D�D$�H�\$�H�L$��w"A�]E�E��I��H��J��I��I�L�H�L$�H!�M��A�HE�`H��)�A���uH�  D  ��@��  ��E����ك�H!�I�O��A�HE�`��H��A�)څ��R  ��t�A��E��A��t1A9�vA�]��I����H��H�D����D)���K�!�A�D��H����F  H�L$�H!�M��A�HA�XH��)�A���tB�m  D  A����A��D����H!�H�M��A�HA�X��H��A�)����0  ��@t�H�
A�H�L���A9�}A��D��9�fA�H|PLc�fB��S�  E1�A9�
D)�Hc�E��A�8D�Hc�H��H�  M��tC�LA�Mc�L��L�  ����=  �j���E��D�$$�=  �  E�S�Mc�Mc�M��B��s�  D��M��f��u�    ��Lc�B��C�  f��t����A��Hc�fB��C�  f��s�  I���  �<s��E��f�<s�E����   E1�f.�     ����tWM��M)� ��Hc񋴳�  9�|9Hc�H�4�D�FE��E9�t!E��M��M)�M��D�6M��L�  fD�^����u�I��A��t Ic���s�  �A��Ic�D��H���g���1�1�@ f��  �f�T
H��H��u�E��xC1��T���t/Hc��tD�΃�f�tD1�f������	����4 u���f�t� H��A9�}�H��([]A\A]A^A_�1�A���������� �NHc�Sf�D����������E�A����E�E1�1�A��   A����y>�    Lc�fB���
  E��t^D9���   ��A�   A�   1�I��D9�|UD�Ƀ�F�L�D9�}D9�t�D9�|���t>9�tHc�f����
  f���
  E��u�I��1���D9�A�   A��   }�[�fD  ��
+f���
  �j���fD  D��A�   A�   1��l���f�f���
  �?��� AWAVAUATUS�^��E�A����Ɂ�   ������  1�E1�A�����A�   �A�@D�d�9�}	D9���  D9���   Lc��t F�\�L�E��A��D��D�O(f�   E��f��   C�7A�ID��!  L�wA��E�<D�O(D��D��$  D)�G�D�A����fD��   D��$  tBM���  ��$  E��F�D�E)�D9��m���F�L�A�D��$  A��fD	�   ��u�E����  D9��  A��A�   �   E1�H��9���  D�������fD  ����  A9��G  Lcˋ�$  E��I���  B�D�F�L�A)�D9���  E��L�wA��D��D�_(f�   E��f��   C�.A�KD��!  L�oA��E�t
  E��A)�A9��^  D���
  D�w(E��A��D��E	�L�_fD��   E�D��!  A�NL�OA��E�	D��$  D��D�w(D)�A��B�L�E��fD��   ��$  A����E����  E��A��H�OE	�D�o(fD��   D��D�D��!  A�EH�OA��D���$  D��D�o()���A��E�䉇$  fD��   �3����    H��E1�A��9�A�   ��   �5���[]A\A]A^A_Ã�
�o  D���
  ��$  E��E)�D9�D���
  ��  E��L�A��D��D�o(f�   E��f��   C�7A�MD��!  L�wA��E�<D�o(D��D��$  D)�A��D��f��   C�L)���
  A���E	ى�$  fD��   �����D  D���
  ��$  E��E)�D9�D���
  ��  E��L�A��D��D�o(f�   E��f��   C�7A�MD��!  L�wA��E�<D�o(D��D��$  D)�A��D��f��   C�L)���$  ��	��   A��
L�OE��D����A	ËG(fD��   ��E�	D��!  �HL�O��E�	�G(D�ы�$  )���	A����$  fD��   �����A��fD�   ���$  fD��   �L�����$  D��   A���6���f.�     A��fD�   DɃ�
�ND��!  L�G��E��w(��$  [])�D0�A\�щ�$  A��A]fD��   A^�f�     ��$  ��t5��~)�G(��   H�O��@�4f��   ��$  �G(��D  �G(��   H�O��@�4��!  �PH�O��@�4�G(fǇ     Ǉ$      �H���   fǇ     Ǉ$      H��H  H��  H��X  H���	  H��`  H��  H��p  H���
  H��x  H���  H���  1��    fǄ�     H��H=x  u�f1��    fǄ�	    H��H��xu�0�f.�     fǄ�
    H��H��Lu�fǇ�   HǇ      HǇ      Ǉ      Ǉ�      ��     D��$  S��A��
D�AD��!  L�O��G�D��$  �O(�   D)�A��
f����
   ��  ��H����u�   H�  H��  H��
H��  H��
H��H��H9�HC�I�t$H9���  H9��T  ���   �G  ��$  �u����
  �{�����H����	�A9���$  f��   �L���   L���	  H��L���m���D��L��H���_���L��L��H�������1��    fǄ�     H��H=x  u�f1��    fǄ�	    H��H��xu�0�f�fǄ�
    H��H��Lu��fǃ�   Hǃ      Hǃ      ǃ      ǃ�      tN��$  ����   �C(��   H�K��@�4��!  �PH�K��@�4�C(fǃ     ǃ$      []A\A]A^Ë�$  ��
     stream pointer is NULL     stream           0x%p
            zalloc    0x%p
            zfree     0x%p
            opaque    0x%p
            msg       %s
            msg                   next_in   0x%p  =>            next_out  0x%p            avail_in  %lu
            avail_out %lu
            total_in  %ld
            total_out %ld
            adler     %ld
     bufsize          %ld
     dictionary       0x%p
     dict_adler       0x%ld
     zip_mode         %d
     crc32            0x%x
     adler32          0x%x
     flags            0x%x
            APPEND    %s
            CRC32     %s
            ADLER32   %s
            CONSUME   %s
            LIMIT     %s
     window           0x%p
 s, message=NULL s, buf, out=NULL, eof=FALSE inflateScan v5.14.0 2.056 Zlib.c Compress::Raw::Zlib::constant Compress::Raw::Zlib::adler32 Compress::Raw::Zlib::crc32   Compress::Raw::Zlib::inflateScanStream  Compress::Raw::Zlib::inflateScanStream::adler32 Compress::Raw::Zlib::inflateScanStream::crc32   Compress::Raw::Zlib::inflateScanStream::getLastBufferOffset     Compress::Raw::Zlib::inflateScanStream::getLastBlockOffset      Compress::Raw::Zlib::inflateScanStream::uncompressedBytes       Compress::Raw::Zlib::inflateScanStream::compressedBytes Compress::Raw::Zlib::inflateScanStream::inflateCount    Compress::Raw::Zlib::inflateScanStream::getEndOffset    Compress::Raw::Zlib::inflateStream      Compress::Raw::Zlib::inflateStream::get_Bufsize Compress::Raw::Zlib::inflateStream::total_out   Compress::Raw::Zlib::inflateStream::adler32     Compress::Raw::Zlib::inflateStream::total_in    Compress::Raw::Zlib::inflateStream::dict_adler  Compress::Raw::Zlib::inflateStream::crc32       Compress::Raw::Zlib::inflateStream::status      Compress::Raw::Zlib::inflateStream::uncompressedBytes   Compress::Raw::Zlib::inflateStream::compressedBytes     Compress::Raw::Zlib::inflateStream::inflateCount        Compress::Raw::Zlib::deflateStream      Compress::Raw::Zlib::deflateStream::total_out   Compress::Raw::Zlib::deflateStream::total_in    Compress::Raw::Zlib::deflateStream::uncompressedBytes   Compress::Raw::Zlib::deflateStream::compressedBytes     Compress::Raw::Zlib::deflateStream::adler32     Compress::Raw::Zlib::deflateStream::dict_adler  Compress::Raw::Zlib::deflateStream::crc32       Compress::Raw::Zlib::deflateStream::status      Compress::Raw::Zlib::deflateStream::get_Bufsize Compress::Raw::Zlib::deflateStream::get_Strategy        Compress::Raw::Zlib::deflateStream::get_Level   Compress::Raw::Zlib::inflateStream::msg Compress::Raw::Zlib::deflateStream::msg Compress::Raw::Zlib::inflateScanStream::resetLastBlockByte      Compress::Raw::Zlib::inflateStream::set_Append  %s: buffer parameter is not a SCALAR reference  %s: buffer parameter is a reference to a reference      Wide character in Compress::Raw::Zlib::crc32    Wide character in Compress::Raw::Zlib::adler32  Compress::Raw::Zlib::inflateScanStream::DESTROY Compress::Raw::Zlib::inflateStream::DESTROY     %s: buffer parameter is read-only       s, good_length, max_lazy, nice_length, max_chain        Compress::Raw::Zlib::deflateStream::deflateTune Compress::Raw::Zlib::deflateStream::DESTROY     Compress::Raw::Zlib::inflateScanStream::status  Compress::Raw::Zlib::inflateStream::inflateSync Wide character in Compress::Raw::Zlib::Inflate::inflateSync     Compress::Raw::Zlib::inflateStream::inflate     Compress::Raw::Zlib::Inflate::inflate input parameter cannot be read-only when ConsumeInput is specified        Wide character in Compress::Raw::Zlib::Inflate::inflate input parameter Wide character in Compress::Raw::Zlib::Inflate::inflate output parameter        s, flags, level, strategy, bufsize      Compress::Raw::Zlib::deflateStream::_deflateParams      Compress::Raw::Zlib::deflateStream::flush       Wide character in Compress::Raw::Zlib::Deflate::flush input parameter   Compress::Raw::Zlib::deflateStream::deflate     Wide character in Compress::Raw::Zlib::Deflate::deflate input parameter Wide character in Compress::Raw::Zlib::Deflate::deflate output parameter        inf_s, flags, level, method, windowBits, memLevel, strategy, bufsize    Compress::Raw::Zlib::inflateScanStream::_createDeflateStream    flags, level, method, windowBits, memLevel, strategy, bufsize, dictionary       Wide character in Compress::Raw::Zlib::Deflate::new dicrionary parameter        Compress::Raw::Zlib::inflateScanStream::inflateReset    Compress::Raw::Zlib::inflateStream::inflateReset        Compress::Raw::Zlib::deflateStream::deflateReset        flags, windowBits, bufsize, dictionary  Your vendor has not defined Zlib macro %s, used Unexpected return type %d while processing Zlib macro %s, used  Compress::Raw::Zlib::inflateScanStream::DispStream      Compress::Raw::Zlib::inflateStream::DispStream  Compress::Raw::Zlib::deflateStream::DispStream  Compress::Raw::Zlib::inflateScanStream::scan    Wide character in Compress::Raw::Zlib::InflateScan::scan input parameter        Compress::Raw::Zlib::zlib_version       Compress::Raw::Zlib::ZLIB_VERNUM        Compress::Raw::Zlib::zlibCompileFlags   Compress::Raw::Zlib::crc32_combine      Compress::Raw::Zlib::adler32_combine    Compress::Raw::Zlib::_deflateInit       Compress::Raw::Zlib::_inflateScanInit   Compress::Raw::Zlib::_inflateInit       Compress::Raw::Zlib needs zlib version 1.x
     Compress::Raw::Zlib::gzip_os_code                       �&���&��p&��@&�� &���%��`%��%���$���$���$��X$��0$���"��$���"���"���#��$)��t"��)��t"��t"��t"��)���(���(��t"��t"��t"��t"��t"��t"��t"��t"��t"��t"��y&��h(��W(��$"��$"��$"��F(��$"��(��$"��$"��$"��(��$"��$"��$"���'��        need dictionary                 stream end                                                      file error                      stream error                    data error                      insufficient memory             buffer error                    incompatible version                                                    �0w    ,a�    �Q	�    �m    ��jp    5�c�    ��d�    2��    ���y    ���    ��җ    +L�	    �|�~    -��    ���    d�    � �j    Hq��    �A��    }��    ���m    Q���    ǅӃ    V�l    ��kd    z�b�    ��e�    O\    �lc    c=�    �
�    ���5    l��B    �ɻ�    @���    �l�2    u\�E    �
�    �|
    ��}    D��    ң�    h�    ��i    ]Wb�    �ge�    q6l    �kn    v��    �+Ӊ    Zz�    �J�g    o߹�    �ﾎ    C��    Վ�`    ���    ~�ѡ    ���8    R��O    �g��    gW��    ��?    K6�H    �+
�    �J6    `zA    ��`�    U�g�    �n1    y�iF    ��a�    �f�    ��o%    6�hR    �w�    G�    �"    /&U    �;��    (��    �Z�+    j�\    ����    1�е    ���,    ��[    ��d�    &�c�    ��ju    
�m    �	�    ?6�    �gr    W     �J��    z��    �+�{    8�    ��Ғ    
�    ��
  `     	�     �  @  	�   X    	� ;  x  8  	�   h  (  	�    �  H  	�   T   � +  t  4  	� 
  �  J  	�   V   @  3  v  6  	�   f  &  	�    �  F  	� 	  ^    	� c  ~  >  	�   n  .  	�    �  N  	� `   Q   �   q  1  	� 
  a  !  	�    �  A  	�   Y    	� ;  y  9  	�   i  )  	�  	  �  I  	�   U   +  u  5  	� 
  `     	�     �  @  	�   X    	� ;  x  8  	�   h  (  	�    �  H  	�   T   � +  t  4  	� 
  �  J  	�   V   @  3  v  6  	�   f  &  	�    �  F  	� 	  ^    	� c  ~  >  	�   n  .  	�    �  N  	� `   Q   �   q  1  	� 
  a  !  	�    �  A  	�   Y    	� ;  y  9  	�   i  )  	�  	  �  I  	�   U   +  u  5  	� 
      
  `     	�     �  @  	�   X    	� ;  x  8  	�   h  (  	�    �  H  	�   T   � +  t  4  	� 
  �  J  	�   V   @  3  v  6  	�   f  &  	�    �  F  	� 	  ^    	� c  ~  >  	�   n  .  	�    �  N  	� `   Q   �   q  1  	� 
  a  !  	�    �  A  	�   Y    	� ;  y  9  	�   i  )  	�  	  �  I  	�   U   +  u  5  	� 
  `     	�     �  @  	�   X    	� ;  x  8  	�   h  (  	�    �  H  	�   T   � +  t  4  	� 
  �  J  	�   V   @  3  v  6  	�   f  &  	�    �  F  	� 	  ^    	� c  ~  >  	�   n  .  	�    �  N  	� `   Q   �   q  1  	� 
  a  !  	�    �  A  	�   Y    	� ;  y  9  	�   i  )  	�  	  �  I  	�   U   +  u  5  	� 
      
  


















                	        
   
               
  �  J  �  *  �  j  �    �  Z  �  :  �  z  �    �  F  �  &  �  f  �    �  V  �  6  �  v  �    �  N  �  .  �  n  �    �  ^  �  >  �  ~  �    �  A  �  !  �  a  �    �  Q  �  1  �  q  �  	  �  I  �  )  �  i  �    �  Y  �  9  �  y  �    �  E  �  %  �  e  �    �  U  �  5  �  u  �  

                         (   0   8   @   P   `   p   �   �   �   �                                                      0   @   `   �   �      �                               0   @   `                                                                                   need dictionary stream end file error stream error data error insufficient memory buffer error incompatible version ;�  �   �S���  �Y���  �[��  ^��X  0`���  `b���  �d��  �f��X  �h���  �j���   m��   o��X  @q���  `s���  �u��  �w��X  �y���  �{���   ~��	   ���X	  @����	  `����	  ����
  ����X
  �����
  �����
   ���   ���X  @����  `����  ����  ����X  �����   ����  @���
���  ���   ���`  ���x  P!���  p!���  �!���  �!���  �"��  �"��(  $��H   $��`  0$��x  �$���   7���  `7��  �8��@  �9��X  �9��p  �:���  �;���  �;���  <���  �Z��@  �Z��`  �[���  0\���  �^���  �^��   �`��(  �`��@  0a��X  �a���  �b���  �b���  �b���   e��8  �h���  i���  �n��  �r��P  �t���  �v���  �w��   �x��   �x��8  y��P  �y���  �y���   {���  ���@  @���x  0����  ���  @���(  ���h   ����  @���   @���`    ����   0����   ����!  P���h!  а���!  б���!  �����!  �����!  p����!   ���("  л��@"  ���X"  ���p"  ����"  @����"  �����"             zR x�  $      �N��`   FJw� ?;*3$"    <   D   �T��   B�B�B �D(�A0�b
(A BBBD  <   �   �V��   B�B�B �D(�A0�b
(A BBBD  <   �   �X��   B�B�B �D(�A0�e
(A BBBI  <     �Z��)   B�B�B �D(�A0�w
(A BBBG  <   D  �\��   B�B�B �D(�A0�e
(A BBBI  <   �  `^��   B�B�B �D(�A0�e
(A BBBI  <   �  @`��   B�B�B �D(�A0�e
(A BBBI  <      b��   B�B�B �D(�A0�e
(A BBBI  <   D   d��   B�B�B �D(�A0�e
(A BBBI  <   �  �e��   B�B�B �D(�A0�b
(A BBBD  <   �  �g��   B�B�B �D(�A0�b
(A BBBD  <     �i��   B�B�B �D(�A0�b
(A BBBD  <   D  �k��   B�B�B �D(�A0�e
(A BBBI  <   �  `m��   B�B�B �D(�A0�b
(A BBBD  <   �  @o��   B�B�B �D(�A0�e
(A BBBI  <      q��   B�B�B �D(�A0�e
(A BBBI  <   D   s��   B�B�B �D(�A0�e
(A BBBI  <   �  �t��   B�B�B �D(�A0�e
(A BBBI  <   �  �v��   B�B�B �D(�A0�b
(A BBBD  <     �x��   B�B�B �D(�A0�b
(A BBBD  <   D  �z��   B�B�B �D(�A0�e
(A BBBI  <   �  `|��   B�B�B �D(�A0�e
(A BBBI  <   �  @~��   B�B�B �D(�A0�b
(A BBBD  <      ���   B�B�B �D(�A0�e
(A BBBI  <   D   ���   B�B�B �D(�A0�b
(A BBBD  <   �  ����   B�B�B �D(�A0�e
(A BBBI  <   �  ����   B�B�B �D(�A0�e
(A BBBI  <     ����   B�B�B �D(�A0�e
(A BBBI  <   D  ����   B�B�B �D(�A0�e
(A BBBI  <   �  `���1   B�B�A �D(�D0�
(A ABBF     <   �  `���   B�B�B �D(�A0�b
(A BBBD  <     @���   B�B�B �D(�A0�b
(A BBBD  <   D   ���9   B�B�A �D(�D0�
(A ABBI        �   ���              �  ���
              �  ����    Ds
I     <   �  ����_   B�B�D �A(�D0A
(A ABBD    <   	  Г��B   B�B�B �D(�A0��
(A BBBF  $   T	  ����N   M��I �y
Az
FL   |	  ����   B�B�B �B(�D0�A8�D`a
8A0A(B BBBD    L   �	  h����   B�B�B �B(�D0�A8�DP�
8A0A(B BBBF    <   
  ����   B�B�D �A(�D0
(A ABBB    <   \
  �����   B�B�D �A(�D0
(A ABBB    $   �
  ���   M��M��I@��
G L   �
   ����   B�B�B �B(�D0�A8�DPo
8A0A(B BBBF    <     �����   B�B�D �A(�D0	
(A ABBD    L   T  ����   B�B�B �B(�D0�A8�DP�
8A0A(B BBBH    L   �  0����   B�B�B �B(�D0�A8�DP�
8A0A(B BBBH    $   �  p���Y   M��S0����
C       ����=    H�f
BF <   <  ȭ��   B�B�B �D(�A0��
(A BBBG  L   |  ����}   B�B�B �B(�D0�A8�DPW
8A0A(B BBBF    L   �  ز���	   B�B�B �B(�A0�A8�G��
8A0A(B BBBA   L   
8A0A(B BBBI    L   l
8A0A(B BBBG    L   �
8A0A(B BBBA    ,     ���y    A�I�G M
AAH     L   <  h���   B�B�B �B(�D0�A8�Dpx
8A0A(B BBBE    L   �  8����   B�B�B �B(�D0�A8�D�?
8A0A(B BBBF   <   �  x���W   B�B�B �D(�A0��
(A BBBF  <     ����W   B�B�B �D(�A0��
(A BBBF  <   \  ����W   B�B�B �D(�A0��
(A BBBF  L   �  �����   B�B�B �E(�A0�A8�D`M
8A0A(B BBBH    ,   �  h���9   W����N`��
F       $     x���9    A�D�F kAA 4   D  ����`   B�F�K �
ABMYAB <   |  ����d   B�E�A �A(�D0W
(A ABBF    <   �  ����d   B�E�A �A(�D0W
(A ABBF    <   �  ���d   B�E�A �A(�D0W
(A ABBF    L   <  H���Y   B�B�B �B(�A0�A8�G`&
8A0A(B BBBG    <   �  X���=
   B�B�B �A(�A0�

(A BBBA     �  X���              �  0���             �  �
��                �
��              ,  �
��C           4   D   ���    B�D�D �J�� DAB          |  ���              �  ���   F�        �  ���              �  ���           ,   �  ����    B�G�C ��
ABE   L     @
8A0A(B BBBG       d   ��7    D�h
DF $   �  @���   M��N0���
E       �  � ���              �  0!��6           $   �  X!���    L��N0��}
Iu $     "���    M��I0��
E         ,  �"��              D  �"��p           L   \  #��k   B�E�B �B(�A0�A8�G��
8A0A(B BBBH       �  8A��W    D�B
JF,   �  xA��   M��M��N@���
E          �  XB��8           <     �B��y   B�B�A �A(�G@�
(A ABBH       T  �D��7           $   l  �D���   M��V0���
E    �  pF��!              �  �F��]           ,   �  �F���    A�H�G�P
CAD    4   �  `G���    A�F�G�W
CAGj
ACB   ,  �G��              D  �G��           D   \  �G��   B�V�R �H(�A0�A8��
0A(B IBBA  d   �  �I��t   B�B�B �B(�A0�A8�G`�
8A0A(B BBBBF
8A0A(B BBBH   $     �L���    M��I �p
J       <   4  @M��   A�C�G 
AAB�
AAA      D   t  �R��"   A�C�G 
AAK�
ADAFAD    ,   �  hV��   B�I�A �
ABJ  L   �  HX��   B�B�E �E(�A0�D8�DPf
8A0A(B BBBA    ,   <  Z���    A�A�G �
AAF        l  �Z���    A�G �A   �  x[��(              �  �[��@           <   �  �[���    B�E�E �A(�A0�~
(A BBBA      �  \��6                @\��%          |   ,  X]���   B�B�B �B(�D0�D8�D@+
8A0A(B BBBG<
8C0A(B BBBH�
8A0A(B BBBE 4   �  �m��'   B�A�A �F0�
 AABH     ,   �  �n���    A�A�G �
AAE     d     �o���   B�E�B �E(�D0�C8�GP2
8A0A(B BBBHi
8A0A(B BBBE       |  �q��)    D d <   �  r���   B�B�A �D(�D0�
(A ABBB    D   �  �s���   B�M�E �L(�E0�D8�v
0A(B BBBH  d     Hy��1   B�E�B �B(�A0�A8�DH�
8A0A(B BBBD�
8F0A(B BBBA   D   �   ~���    B�N�E �B(�A0�A8��
0A(B BBBF   L   �  �~���   B�B�B �B(�A0�A8�G`�
8A0A(B BBBA         h���
G   D   <  X���a   B�B�B �B(�A0�A8�
0A(B BBBA  L   �  �����   B�V�D �A(�A0�E
(A BOJA(A HMJ    �  �����              �  H����                0����   H��
G      $  ����              <  �����           <   T  �����   B�B�E �D(�C0�:
(A BBBA     �  ����              �  ����              �  ����              �  x���              �  ����"                ����L              $  Й��!                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           ��������        ��������                                                �[         �W         �W           �W         R           R       � � R        �  R       �  R        R     ��     ��     �     ��     ��     ��     ��     ��     ��     �            s             �<      
       �                           �"            �                           �4             �+              	      	              ���o    @+      ���o           ���o    �)      ���o                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   0"                     �<      �<      �<      �<      �<      =      =      &=      6=      F=      V=      f=      v=      �=      �=      �=      �=      �=      �=      �=      �=      >      >      &>      6>      F>      V>      f>      v>      �>      �>      �>      �>      �>      �>      �>      �>      ?      ?      &?      6?      F?      V?      f?      v?      �?      �?      �?      �?      �?      �?      �?      �?      @      @      &@      6@      F@      V@      f@      v@      �@      �@      �@      �@      �@      �@      �@      �@      A      A      &A      6A      FA      VA      fA      vA      �A      �A      �A      �A      �A      �A      �A      �A                              �""                              �     ��                 �     ��                           @�                   GCC: (Ubuntu/Linaro 4.6.3-1ubuntu5) 4.6.3 ,             �B      ��                      ,    h�       �     �                      ,    [�       �
     �                      ,    E�       0
!  �^   �0  �^   �.  �W   �"  �^   *,  �^   $  �^   �  �^   #+  �^     l  ?  B{   y   Qp   !  Y�   %+  n  �"  	<�   ,,  	L�   )  
�B   �  �W   ��  F7  �  #  	B   �  
B    �/   q  \
B    `  �#G   6  )�  # v  *W   #@�  +�  #H 	  W  
B     (  dG  W   
  �4   #__a ��  # 	4   N  
B    T  �  !x  �  #W   �:  $�    �  %U  ?�  �3  A�   # a$  Bp   # F�  �  HW   # �"  IW   #�  Jx  # N  �3  P�   # a$  Qp   #�  Rx  #  V]  �3  X�   # a$  Yp   #�  ZW   #�:  [�   #�(  \�   # `t  Z3  b�   #  f�   <  h^   # !%  iW   # p:�  K  <�  �  C�  �1  K�  _rt S�  �1  ]  d.  c]  ]<  jt   	W   �  
B      �3D  E)  5W   # �   6W   #  8W   #c/  k�  #   l�  e  W   e  �    D  O  �  4;   	  �  
B   
B    tms  #�  R*  %E  #   &E  #�  (E  #"   )E  #   �/    X5    # L7  �  #�	  W   #05   q  # 1   e^  ;  g  # a  h�  #  iW   #B  jW   #G(  k�  # 
B   � �#  &�  Y  (�   # �5  )�   #,!  *4   #�;  +-   #M  ,7  # DIR ��  M1  IV �^   UV �B   NV ��      b	[  OP i	�  op ($�	  �  %O.  # c  %O.  #-  %�@  #�  %�@  #B&  %;   	# �  %;   # �  %;   # z  %;   # �  %;   # n.  %;   # `  %+  #"�  %+  ## COP j	�	  cop P  �  �O.  # c  �O.  #-  ��@  #�  ��@  #B&  �;   	# �  �;   # �  �;   # z  �;   # �  �;   # n.  �;   # `  �+  #"�  �+  ##�  �7+  #$�#  �  #(�7  �  #0+  �,+  #8q&  �,+  #<"#  �aG  #@*  �gG  #H �  o	  
  ��  #�X  ��6  #��$  ��6  #�   �~+  #��!  ��>  #�z!  �D5  #��(  �+  #��  �  #�z)  �  #��  �R  #�P
  �nQ  #�	3  �nQ  #�	m  �Q  #�	l  �!+  #�	�:  �!+  #�	u0  ��  #�	c:  �  #�	�  �(R  #�	�  �.R  #�	R6  �+  #�	�  �+  #�	6  �  #�	�;  �+  #�	�7  �  #�	a	   	Q  #�	u  I   #�	  ,+  #�	S   
W   #�	i   �  #�	�
  U.  #�	e  
<<  ~+  #�
�  ~+  #�
�  ~+  #�
~  4R  #�
03  �  #�
�
    #�
    #�
    #�
�
�
    #�
�     #�
h%  ++  #�
�  -  #�
�0  .  #�
�5  /+  #�
�:  0  #�
+  2  #�
�'  3  #�
�  4  #�
=  5~+  #�
�  8P  #�
�;  9~+  #�
  <!+  #�
	  >!+  #�
�  B!+  #�
�4  EW   #�
-  Fb  #�
O  IU.  #�
  JU.  #��0  KU.  #��  LU.  #�j0  MU.  #�#  N�4  #�Y;  QU.  #�4  TU.  #�N)  WU.  #��  XU.  #�9  pU.  #�  q~+  #��  r~+  #�1  s~+  #��  t�4  #�h  w@4  #��  x@4  #��7  y~+  #��  z�4  #�3  {�4  #��  |�4  #��  }�4  #�2  ~�4  #��-  @4  #�,  �,+  #��,  �W   #�  �!+  #��  �!+  #��  �~+  #��  �~+  #�5  ��4  #��  �  #��<  ��4  #��  �O.  #��
  �O.  #�8%  �O.  #�
   #��      #��
     #��2  ~+  #�a0  !+  #��  !+  #��  !+  #��)  !+  #��  !+  #�*/  ,+  #��+  UR  #�a;  ,+  #��1  ^   #�O5  "  #�
  J~+  #�2  K~+  #��2  L~+  #�,)  M~+  #�&(  N~+  #�Z  O~+  #��7  P~+  #��"  Q~+  #��"  R~+  #��
  S~+  #�o  T~+  #�/#  U~+  #�_  V~+  #��(  W~+  #��;  X~+  #��  Y~+  #��,  Z~+  #��   [~+  #��  \@4  #��  ]|:  #�.  ^�  #��  _ZR  #�F<  `+  #��1  f  #�  hW   #�R  kjR  #��/  o�/  #��  s�/  #�6  �pR  #��"  ��4  #�i3  ��   #�3  �~+  #�^
  ��/  #�Y1  ��4  #��0  �vR  #�2*  �@4  #��  �@4  #�	  ��-  #��*  �|R  #��  �|R  #��  �~+  #�E  �AQ  #�9  �~+  #��  �~+  #�Y8  �~+  #�^  �~+  #�F  ��Q  #�7  ��4  #��(  ��4  #��8  �^   #��3  �,+  #��  �W   #��,  �@4  #�}  ��P  #�5'  ��P  #�0"  ��P  #�!&  ��P  #��  ��P  #�.  ��  #��  ��  #��  �@4  #��  �W   #�%:  ��R  #��#   �P  #�P$  
@4  #��	  
  @4  #�T  @4  #�j  @4  #� SV �	   sv qc   T)  r�   # �$  r,+  #!  r,+  #G  sb/  # AV �	n   av ��   T)  �1  # �$  �,+  #!  �,+  #G  ��0  # HV �	�   hv �!  T)  �w1  # �$  �,+  #!  �,+  #G  �1  # CV �	!  cv �P!  T)  ��0  # �$  �,+  #!  �,+  #G  �H0  # }/  �	\!  �  ��!  T)  ��3  # �$  �,+  #!  �,+  #G  ��1  # GP �	�!  gp PR"  7  ~+  # �!  
&  �	�#  �  (,$  �%  �4  # �  IL  #�3  +  #�;    #J"   +  #�  !!+  #�  "~+  #	/  #  #  XPV �	8$  xpv  ��$  �+  �@4  # �#  ��4  #>  ��  #�  ��  #   �	�$  
B     Q-  	  �-  
B    �  $c�-  �  �  $e�-  �-    $�-    �  %7k  �)  &�O.  !5  &�!+  �$  &�  �$  &�O.  t)  &�U.  D  &�  �2  &�!+   �  R"  �)  &� .  $.�.  %D   %m  %�  %�+  %�  %@  %^  %�  %y/  %O  	%�  
%�  %�  %  
5  "#$  5  "�5  �    �  g  'D5  �9  '+  # �F  '+  #�-  '+  # g  '
B    �-  '5�5  �C  '6!+  #  end '7!+  # �-  '8�5  <"  `'z�6  2  '{,7  # �  '|o7  #�  '�7  #v3  '��7  #>3  '��7  # �;  '�8  #(�	  '�78  #0-9  '�\8  #8�  '��8  #@Q%  '��8  #H  '��7  #P�3  '��8  #X �6  6  P!  �5  �5    'q�6  �.  's�  # 2  't�6  # !+  �*  'u�6  *�6  '7  r+  '7  ,+   ~+  
  '�  #$�
  '�W   #(�C  '�W   #,�  '�  #0 '('��<  m6  '�59  # �#  '�59  #cp '��8  #�9  '��8  #�  '�  #~1  '�!+  # i  '�!+  #$ '8'�K=  m6  '�59  # c1 '�!+  #c2 '�!+  #cp '��8  #�+  '�!+  #�C  '�!+  #x
  '�  #A '��9  # B '��9  #(me '��9  #0 '@'��=  i  '�,+  # cp '��8  #c1 '�!+  #c2 '�!+  ##/  '�  #   '�  #�C  '�W   # min '�W   #$max '�W   #(A '��9  #0B '��9  #8 )H'7�>  +yes '>�8  "�
  'I;9  "g  'Rq9  "0'  'c�9  "�&  't�:  "�(  '|;  "2)  '�U;  "�   '��;  "�#  '��;  "*7  '�A<  "�  '��<  "�  '�K=   �  '��8  �  �'��>  C	  '��>  # �8  '��>  #�  '��>  #� 	�>  �>  
B   - �>  �  '��>  
B    	  �B  -B   � 	  �B  
B    
  ,+  #�  ,,^   #�  ,-^   #�
[  #��*  -
  '�F  ,  �[G  �+  �  PG  
  QO.  # cv S�4  #@8  U�4  #o
  V�4  #�)  W!+  # h$  X�G  #( v@  
  ^O.  # cv `�4  #gv bU.  #�1  cU.  # 
  �O.  # �   �~+  #C%  �O.  #�<  �~+  #cv ��4  # 
  .L+  #��  .M+  #�S(  .N@4  #��  .O�/  #�t;  .P�4  #��  .d)P  #��  .e9P  #��4  .f!+  #��  .iJ  #�  .j7  #��!  .l  #��,  .m+  #�  M  �L  	[.  9P  
B    	!+  IP  
B    w9  .n M  �)  TP    `P  N  Z  �P  �P  *W   �P  r+   �  ��P  �P  �P  r+  ~+   S  �P  5  ��P  �P  *  �P  r+  ~+   C  ��P  �P  	Q  r+   /!  �AQ  %�   %  %�4  %�;  %U.  %n+  %�!   
B    �   *zQ  �Q  �Q  r+  O.   m/  ;�Q  �Q  *!+  �Q  r+  '7  '7   L  IzQ  
B    �>  �>  :R  �  �Q  	�   UR  
B    0,+  	+  jR  
B   	 IP  )*  �F  �-  �   $/;T  %�   %65  %  %�  %�  %j5  %Q4  %�  %Z  %H6  	%"  
%  %(   %%  
  �~+  #�u#  �ST  #��  �W   #�n<  �  #�  �  #�F  �_T  #��6  �W   #�-$  �W   #��  �W   #��
  g�  6 7�    �X  8N   W   9�
  #r+  9�  $   1h  M�   Y  2x,  M�   2  MW   25  M[   :"  RY  4s �W  8�9  W   8E  W   88  W    ;�:  W   �Y  2�
  r+  2W/  �  2i  �Y   �  ;�:  eW   �Y  2�
  er+  2W/  e�  2i  e�Y   ;  �W   �Y  2�
  �r+  2W/  ��  2i  ��Y   ;  �W   $Z  2�
  �r+  2W/  ��  2i  ��Y   ;   �W   bZ  2�
  �r+  2W/  ��  2i  �Y  2=  � R   7D1  7W   �Z  8�
  7r+  8W/  7�  4len 7�  8i  7�Y  8=  7 R   :�  [+[  8N(  [�U  4len [;   4rot [;   5tmp c-   9�:  d;   9�C  e�U  9�.  e�U  5to e�U  9�&  e�U   :l  �f[  4ptr ��   8�  �W   5p �  5i �W    <�%  �
  �
  �
  �
  �
  �r+  T  >cv ��4  w  ?�
  �W   @sp ��/  �  @ax �!+  2	  A2)  ��/  �	  A>  �!+  
  B`  *^  @s ��W  J
  AW   �ST  m
  A�  �'7  �
  C�  @tmp ��  J
    C�  A�  �X\  �
    <h  �0I      YK      �
  3_  =�
  �r+  �  >cv ��4  "  ?�
  �W   @sp ��/  ~  @ax �!+  �  A2)  ��/  {
  �r+  �  >cv ��4  �  ?�
  �W   @sp ��/    @ax �!+  s  A2)  ��/    A>  �!+  U  B�  `  @s ��W  �  AW   �ST  �  A�  �'7  �  C  @tmp ��  �    C@  A�  �X\      <;  j�M      �O      @  a  =�
  jr+  @  >cv j�4  c  ?�
  mW   @sp m�/  �  @ax m!+    A2)  m�/  �  A>  m!+     Bp   a  @s t�W  6  AW   uST  Y  A�  v'7  �  C�  @tmp y�  6    C�  A�  �X\  �    <�  F�O      �Q      �  	b  =�
  Fr+  �  >cv F�4    ?�
  IW   @sp I�/  j  @ax I!+  �  A2)  I�/  g  A>  I!+  +  B   �a  @s P�W  a  AW   QST  �  A�  R'7  �  Cp  @tmp U�  a    C�  A�  eX\  �    <
  "�Q      �S        �b  =�
  "r+    >cv "�4  9  ?�
  %W   @sp %�/  �  @ax %!+  �  A2)  %�/  �  A>  %!+  �  B�  �b  @s ,�W    AW   -ST  /  A�  .'7  g  C   @tmp 1�      CP  A�  AX\  �    <<!  �
�S      �U      �  �c  =�
  �
r+  �  >cv �
�4  �  ?�
  �
W   @sp �
�/  @  @ax �
!+  �  A2)  �
�/  =   A>  �
!+  �   B�  �c  @s �
�W  �   AW   �
ST  �   A�  �
'7  !  C�  @tmp �
�  �     C   A�  �
X\  H!    <�4  �
 V      X      l!  �d  =�
  �
r+  l"  >cv �
�4  �"  ?�
  �
W   @sp �
�/  �"  @ax �
!+  J#  A2)  �
�/  �#  A>  �
!+  ,$  B0  �d  @s �
�W  b$  AW   �
ST  �$  A�  �
'7  �$  C�  @tmp �
�  b$    C�  A�  �
X\  �$    <�  s
 X      1Z      %  �e  =�
  s
r+  &  >cv s
�4  :&  ?�
  v
W   @sp v
�/  �&  @ax v
!+  �&  A2)  v
�/  �'  A>  v
!+  �'  B�  �e  @s }
�W  
ST  0(  A�  
'7  g(  C0  @tmp �
�  
X\  �(    <�  S
@Z      Q\      �(  �f  =�
  S
r+  �)  >cv S
�4  �)  ?�
  V
W   @sp V
�/  @*  @ax V
!+  �*  A2)  V
�/  =+  A>  V
!+  �+  B�  �f  @s ]
�W  �+  AW   ^
ST  �+  A�  _
'7  ,  C�  @tmp b
�  �+    C  A�  n
X\  G,    <�  3
`\      y^      k,  �g  =�
  3
r+  k-  >cv 3
�4  �-  ?�
  6
W   @sp 6
�/  �-  @ax 6
!+  I.  A2)  6
�/  �.  A>  6
!+  +/  B@  �g  @s =
�W  a/  AW   >
ST  �/  A�  ?
'7  �/  C�  @tmp B
�  a/    C�  A�  N
X\  �/    <�  
�^      �`      0  �h  =�
  
r+  1  >cv 
�4  91  ?�
  
W   @sp 
�/  �1  @ax 
!+  �1  A2)  
�/  �2  A>  
!+  �2  B�  �h  @s 
�W  3  AW   
ST  /3  A�  
'7  f3  C@	  @tmp "
�  3    Cp	  A�  .
X\  �3    <j  �	�`      �b      �3  �i  =�
  �	r+  �4  >cv �	�4  �4  ?�
  �	W   @sp �	�/  ?5  @ax �	!+  �5  A2)  �	�/  <6  A>  �	!+   7  B�	  �i  @s �	�W  67  AW   �	ST  Y7  A�  �	'7  |7  C�	  @tmp 
�  67    C 
  A�  
X\  �7    <6+  n	�b      �d      �7  �j  =�
  n	r+  �8  >cv n	�4  �8  ?�
  q	W   @sp q	�/  U9  @ax q	!+  �9  A2)  q	�/  R:  A>  q	!+  �:  BP
  tj  @s x	�W  �:  AW   y	ST  �:  A�  z	'7  ';  C�
  @tmp }	�  �:    C�
  A�  �	X\  ];    <�&  N	�d      �f      �;  }k  =�
  N	r+  �<  >cv N	�4  �<  ?�
  Q	W   @sp Q	�/   =  @ax Q	!+  _=  A2)  Q	�/  �=  A>  Q	!+  A>  B   fk  @s X	�W  w>  AW   Y	ST  �>  A�  Z	'7  �>  CP  @tmp ]	�  w>    C�  A�  i	X\  ?    <V7  .	 g      i      ,?  ol  =�
  .	r+  ,@  >cv .	�4  O@  ?�
  1	W   @sp 1	�/  �@  @ax 1	!+  
A  A2)  1	�/  �A  A>  1	!+  �A  B�  Xl  @s 8	�W  "B  AW   9	ST  EB  A�  :	'7  }B  C   @tmp =	�  "B    C0  A�  I	X\  �B    <�  � i      1k      �B  am  =�
  �r+  �C  >cv ��4  �C  ?�
  �W   @sp ��/  VD  @ax �!+  �D  A2)  ��/  SE  A>  �!+  �E  B`  Jm  @s ��W  �E  AW   �ST  �E  A�  �'7  (F  C�  @tmp ��  �E    C�  A�  �X\  ^F    <�)  �@k      Qm      �F  Sn  =�
  �r+  �G  >cv ��4  �G  ?�
  �W   @sp ��/  H  @ax �!+  `H  A2)  ��/  �H  A>  �!+  BI  B
  gr+  ,K  >cv g�4  OK  ?�
  jW   @sp j�/  �K  @ax j!+  
L  A2)  j�/  �L  A>  j!+  �L  B�
  Gr+  �N  >cv G�4  �N  ?�
  JW   @sp J�/  VO  @ax J!+  �O  A2)  J�/  SP  A>  J!+  �P  Bp   p  @s Q�W  �P  AW   RST  �P  A�  S'7  (Q  C�  @tmp V�  �P    C�  A�  bX\  ^Q    <�  '�q      �s      �Q  )q  =�
  'r+  �R  >cv '�4  �R  ?�
  *W   @sp *�/  S  @ax *!+  `S  A2)  *�/  �S  A>  *!+  �T  B   q  @s 1�W  �T  AW   2ST  U  A�  3'7  RU  Cp  @tmp 6�  �T    C�  A�  BX\  �U    <O#  �s      �u      �U  r  =�
  r+  �V  >cv �4  �V  ?�
  
W   @sp 
�/  +W  @ax 
!+  �W  A2)  
�/  (X  A>  
!+  lX  B�  r  @s �W  �X  AW   ST  �X  A�  '7  �X  C   @tmp �  �X    CP  A�  "X\  3Y    <C  ��u      �w      WY  
  �r+  WZ  >cv ��4  zZ  ?�
  �W   @sp ��/  �Z  @ax �!+  5[  A2)  ��/  �[  A>  �!+  \  B�  �r  @s ��W  M\  AW   �ST  p\  A�  �'7  �\  C�  @tmp ��  M\    C   A�  X\  �\    <  � x      z      ]  �s  =�
  �r+  ^  >cv ��4  $^  ?�
  �W   @sp ��/  �^  @ax �!+  �^  A2)  ��/  }_  A>  �!+  �_  B0  �s  @s ��W  �_  AW   �W   `  A�  �'7  =`  C�  @tmp ��  �_    C�  A�  �X\  s`    <�  � z      9|      �`  �t  =�
  �r+  �a  >cv ��4  �a  ?�
  �W   @sp ��/  b  @ax �!+  ub  A2)  ��/  c  A>  �!+  Wc  B�  �t  @s ��W  �c  AW   �ST  �c  A�  �'7  �c  C0  @tmp ��  �c    C`  A�  �X\  d    <e  �@|      Y~      Bd  �u  =�
  �r+  Be  >cv ��4  ee  ?�
  �W   @sp ��/  �e  @ax �!+   f  A2)  ��/  �f  A>  �!+  g  B�  �u  @s ��W  8g  AW   �W   [g  A�  �'7  ~g  C�  @tmp ��  8g    C  A�  �X\  �g    <�6  g`~      y�      �g  �v  =�
  gr+  �h  >cv g�4  �h  ?�
  jW   @sp j�/  Wi  @ax j!+  �i  A2)  j�/  Tj  A>  j!+  �j  B@  �v  @s q�W  �j  AW   rW   �j  A�  s'7  k  C�  @tmp v�  �j    C�  A�  �X\  Jk    <�  @��      ��      nk  �w  =�
  @r+  nl  >cv @�4  �l  ?�
  CW   @sp C�/  �l  @ax C!+  Lm  A2)  C�/  �m  A>  C!+  n  B�  �w  AW   J;   <n  A�  K'7  bn   C@  A�  ZX\  �n    <9  �
��      у      �n  �x  =�
  �
r+  �o  >cv �
�4  �o  ?�
  �
W   @sp �
�/  (p  @ax �
!+  �p  A2)  �
�/  %q  A>  �
!+  iq  Bp  ~x  @s �
�W  �q  AW   �
  �q  A�  �
'7  �q  C�  @tmp �
�  �q    C�  A�  �
X\  0r    <U  ���      �      Tr  �y  =�
  �r+  Ts  >cv ��4  ws  ?�
  �W   @sp ��/  �s  @ax �!+  2t  A2)  ��/  �t  A>  �!+  u  B   py  @s ��W  Ju  AW   �  mu  A�  �'7  �u  Cp  @tmp ��  Ju    C�  A�  �X\  �u    <�2  + �      9�      �u  Uz  =�
  +r+  �v  >cv +�4  "w  ?�
  .W   @sp .�/  ~w  @ax .!+  �w  A2)  .�/  Sx  A>  .!+  �x  B�  >z  AW   5�  �x  A�  6'7  y   C   A�  ;X\  &y    D�  �@�      H�      w�z  =/  �kT  Jy  >ptr �kT  my   Ez
  �r+  �{  >cv ��4  �{  ?�
  �W   @sp ��/  �{  @ax �!+  2|  A2)  ��/  �|  A>  �!+  �|  BP  �{  @s ��W  5}  AX  ��U  k}  C�  @tmp  
��            �}  '}  =�
  �
r+  �~  >cv �
�4  �~  ?�
  �
W   @sp �
�/    @ax �
!+  U  A2)  �
�/  �  A>  �
!+  5�  B�  }  @s �
�W  k�  A`?  �
  ��  AW   �
  �  B�  �|  A*  �
R  F�   C@  @tmp �  k�    G9�      R�      A�  X\  i�    F�  )~+  Ѝ      �      ��  x}  >sv )~+  �  =�  )�  ��  9�
  0r+   <y  � �      Ē      ��  �~  =�
  �r+  2�  >cv ��4  U�  ?�
  �W   @sp ��/  ��  @ax �!+  �  A2)  ��/  ��  A>  �!+  =�  Bp  ~~  @crc �ST  ��  @len ��  ��  @buf ��U  �  A�$  �W   T�  @sv �~+  ��  AW   �ST  Q�  A�  �'7  ��   C�  A�  �X\  �    <�  xВ      ��      �  �  =�
  xr+  Y�  >cv x�4  |�  ?�
  {W   @sp {�/  ؊  @ax {!+  7�  A2)  {�/  ��  A>  {!+  d�  B�  �  Az#  �ST  ��  @len ��  �  @buf ��U  2�  @sv �~+  {�  AW   �ST  )�  A�  �'7  _�   C@  A�  �X\  ��    <!  ��      z�      ̎  ��  =�
  r+  ̏  >cv �4  �  ?�
  W   @sp �/  K�  @ax !+  ��  A2)  �/  �  A>  !+  b�  Bp  w�  @s "�W  ��  B�  `�  @tmp %�  ��   C   @_sv ~'7  Α    GÖ      �      A�  ;X\  �    <�"  �	��      :�      *�  ��  =�
  �	r+  *�  >cv �	�4  M�  ?�
  �	W   @sp �	�/  ��  @ax �	!+  ��  A2)  �	�/  |�  A>  �	!+  ��  B0  o�  @s �	�W  ��  B�  X�  @tmp �	�  ��   C�  @_sv '7  ,�    G��      ��      A�  �	X\  d�    F1  J~+  @�      Q�      ��  �  >sv J~+  �  =�  J�  F�  9�
  Qr+  A�7  R  ��  Hna S�  �H <%  �`�      .�      O�  3�  =�
  �r+  ��  >cv ��4  Ę  ?�
  �W   @sp ��/  
  r+  P�  >cv �4  s�  ?�
  �W   @sp ��/  ϝ  @ax �!+  �  A2)  ��/  ��  A>  �!+  �  B�  �  @s ��W  �  B�  �  @tmp ��  �   C   @_sv '7  R�    G!�      B�      A�  �X\  ��    <\  ��      c�      ��  )�  =�
  �r+   �  >cv ��4  #�  ?�
  �W   @sp ��/  �  @ax �!+  ޡ  A2)  ��/  g�  A>  �!+  ��  BP  �  A�  �ST  �  A�3  �ST  �  A�1  �^   M�  AW   �ST  ��  A�  �'7  ��   C�  A�  	X\  �    <�  �p�      �      �  '�  =�
  �r+  V�  >cv ��4  y�  ?�
  �W   @sp ��/  ե  @ax �!+  4�  A2)  ��/  ��  A>  �!+  �  B�  �  A  �ST  7�  A  �ST  m�  A�1  �^   ��  AW   �ST  ݧ  A�  �'7  �   C   A�  �X\  6�    <�(  b �      Y�      Z�  ��  =�
  br+  ��  >cv b�4  ݨ  ?�
  eW   @sp e�/  9�  @ax e!+  ��  A2)  e�/  �  A>  e!+  �  BP  ކ  AW   lST  ��  A�  m'7  �   C�  A�  rX\  �    I�X  `�      ��      2�  T�  J�X  ��  K�X  L�X  �  M�X  ��      �  C   K�X  K�X  N�X     < 4  ~
  ~
  �
  �	r+  ��  >cv �	�4  ��  ?�
  �	W   @sp �	�/  ��  @ax �	!+  ,�  A2)  �	�/  ��  A>  �	!+  ��  B�  :�  @s �	�W  /�  @buf �	~+  e�  A  �	�  ܲ  AW   �	�U  �  B0  $�  @tmp �	�  /�   C`  @in ;   _�    C�  A�  �	X\  ��    <�6  [@�      ׶      ��  �  =�
  [r+  �  >cv [�4  /�  ?�
  ^W   @sp ^�/  x�  @ax ^!+  ��  A2)  ^�/  O�  A>  ^!+  ��  B�  ۊ  @s e�W  ��  @buf f~+  ��  A�  g~+  ��  5eof h  AI  iGT  �  Ap1  jGT  �  A�  kW   y�  A  l�  ξ  A&  mST  q�  A,  2  �  AW   s�U  ��  B   ��  @tmp v�  ��   Bp  Ċ  @in �;   ��   C�  A*  �R  6�    C�  A�  )	X\  Y�    <�+  #�      $�      }�  �  =�
  #r+  ��  >cv #�4  ��  ?�
  &W   @sp &�/  ;�  @ax &!+  r�  A2)  &�/  ��  A>  &!+  R�  B    ��  @s -�W  ��  A�9  .W   ��  A�  /W   ��  A
(  0W   0�  AE  1ST  y�  AW   2�U  ��  C`   @tmp 5�  ��    C�   A�  bX\  ��    <-  �0�      ;�      
  �r+  _�  >cv ��4  ��  ?�
  �W   @sp ��/  ��  @ax �!+  �  A2)  ��/  ��  A>  �!+  B�  B�   M�  @s ��W  ��  A�  �~+  �  @f �W   ��  AI  �GT  ��  A�  �GT  �  A�  �GT  r�  A&  �ST  ��  AG,  �ST  �  AW   ��U  p�  C !  @tmp ��  ��    C�!  A�  X\  ��    <�$   @�      ��      �  ��  =�
   r+  V�  >cv  �4  y�  ?�
  W   @sp �/  ��  @ax !+  ��  A2)  �/  ��  A>  !+  ��  B�!  ��  @s 
�W  �  @buf ~+  q�  A�  ~+  '�  AI  
  
  
(  ,
  r+  M�  >cv �4  p�  ?�
  W   @sp �/  ��  @ax !+  q�  A2)  �/  ��  A>  !+  q�  CP#  A�9  W   ��  A�  W   
�  A�  W   Y�  A8  W   ��  A-   W   $�  A
(  W   ��  AE   ST  ��  A�
  !~+  	�  @err 	W   ��  @s 
�W  ;�  B�#  ܑ  @obj 4~+  ��   C$  @sv 9~+  Y�     <	  f��      G�      ��  Ւ  =�
  fr+  ��  >cv f�4  ��  ?�
  iW   @sp i�/  �  @ax i!+  E�  A2)  i�/  ��  A>  i!+  �  B@$  ��  @s p�W  H�  AW   q�U  ��  C�$  @tmp t�  H�    C�$  A�  �X\  �    <�&  7P�      ��      %�  ��  =�
  7r+  %�  >cv 7�4  H�  ?�
  :W   @sp :�/  ��  @ax :!+  ��  A2)  :�/  Q�  A>  :!+  ��  B�$  ��  @s A�W  ��  AW   B�U  (�  C@%  @tmp E�  ��    Cp%  A�  VX\  ��    <Y4  ���      �      ��  ��  =�
  �r+  ��  >cv ��4  ��  ?�
  �W   @sp ��/  �  @ax �!+  K�  A2)  ��/  ��  A>  �!+  �  B�%  ��  @s ��W  N�  AW   ��U  ��  C�%  @tmp ��  N�    C &  A�  �X\  �    <*  _�      ��      +�  ɕ  =�
  _r+  }�  >cv _�4  ��  ?�
  bW   @sp b�/  ��  @ax b!+  B�  A2)  b�/  ��  A>  b!+  ��  @ix f!+  B�  CP&  A�9  lW   ~�  A8  mW   ��  AE  nST  '�  A�
  o~+  a�  @err HW   ��  @s I�W  ��  B�&  ��  @obj y~+  ��   C�&  @sv �~+  ��     <-1  ���      )�      G�  ї  =�
  �r+  ��  >cv ��4  ��  ?�
  �W   @sp ��/  �  @ax �!+  5�  A2)  ��/  ��  A>  �!+  �  C '  P�  '7  N Qlen 	�  � R�F  
W   Siv �  ^Qpv 
 KQ[  L[[  �
 VE[  O�X  E�      \�      �W�X  
�     �  X�  �p�      ��      �
 ��  >s ��W  � =q  �   U�X  r�       )  ���  W�X  
��     � Y�X  ��      ��      �Ø  J�X  O  Y�X  ��      ��      ��  J�X  {  Y�X  ��      ��      ��  J�X  �  Y�X  ��      �      �5�  J�X  �  Y�X  �      �      �[�  J�X  �  U�X  '�      @)  �}�  J�X  +
  @r+   >cv @�4  B ?�
  CW   @sp C�/  � @ax C!+  � A2)  C�/  K A>  C!+  � B�*  q�  @s J�W  � Aq  K  . C�*  @tmp N�  �   G�      0�      A�  aX\  Q   <,  @�      ��      u ��  =�
  r+  u >cv �4  � ?�
  W   @sp �/  � @ax !+   A2)  �/  � A>  !+   B +  _�  @s �W  N Aq    � C@+  @tmp �  N   G�      ��      A�  2X\  �   <p  ���      �      � p�  =�
  �r+  � >cv ��4  � ?�
  �W   @sp ��/  7 @ax �!+  n A2)  ��/  � A>  �!+  N Bp+  M�  @s ��W  � Aq  �  � C�+  @tmp ��  �   G��      �      A�  �X\  �   <.  � �      y�       ��  =�
  �r+  f >cv ��4  � ?�
  �W   @sp ��/  � @ax �!+  	 A2)  ��/  � A>  �!+  � B�+  l�  @s ��W  ? @buf �~+  � 5out �~+  5eof �  A%  �  & A�   �W   J A  ��  m AW   ��U  � B0,  ��  @tmp ��  ?  B�,  ��  A*  �R  T   B�,  ɠ  @in  ;   w   M�Z  �      �,  �J�Z  �  J�Z  �  C -  L�Z  B! L�Z  �! L[  " L[  J" J�Z  �" L�Z  �" L[  # MXX  `�      P-  �JtX  (# JjX  ^# C�-  L~X  �#      C�-  A�  X\  �#   <�  �
  �
  �
�     �[#�      �     ��  @cv �
B   	
B    \;,  ��  	 �     ע  ]�  �   ^o  2��-  ^C*  2��-  	  9�  _ ?�'  �G�  .�  ^�  3 U+  ?�
  �
     92  �2  m9   c  �8  oL   M3  7  p_   H3  =  v-   l  int    <  �<  �S   �   �  �S   �3  �S   �1  ��   �<  �_   �<  �_   rem �L    	�   �     �     w5  
�   �& 
�   ' 
�   '' �   �' �   �' �   (  �  AS   �     J
     w�  
     f
     wP  
     `
     �
�   |+ 
�   F+ 
�   + P
     `
     �   �   �      �<  �S   p
     �
     w
     �
     �
�   , 
�   �+ 
�   �+ p
     �
     �   �   �       �   &  l"  �<  �  �
     %
     �
     wP  
&=  Y�   Umat Z�   Tn \a   T, 
     �
     _�   x, �   �, �
     �
     �   -    �<  cG   �
     �     I- t    dG   .   eG   }. �1  ft   �. n ha   =/ row iS   a/ 5=  jt  ��{odd kt  ��}�   f     �     �-  �   �/ �   �/ f     �     �   0   
�   	�   	�    N  pU�  �1  V�  #   W@   #�)  XS   #@-  Z�  #l:  [@   # �  \S   #(
�)  u>  ?  
=>  wy   #�7�>  xy   #�7
V   `   P   s   p  0  	� 
  `     	�     �  @  	�   X    	� ;  x  8  	�   h  (  	�    �  H  	�   T   � +  t  4  	� 
  �  J  	�   V   @  3  v  6  	�   f  &  	�    �  F  	� 	  ^    	� c  ~  >  	�   n  .  	�    �  N  	� `   Q   �   q  1  	� 
  a  !  	�    �  A  	�   Y    	� ;  y  9  	�   i  )  	�  	  �  I  	�   U   +  u  5  	� 
  `     	�     �  @  	�   X    	� ;  x  8  	�   h  (  	�    �  H  	�   T   � +  t  4  	� 
  �  J  	�   V   @  3  v  6  	�   f  &  	�    �  F  	� 	  ^    	� c  ~  >  	�   n  .  	�    �  N  	� `   Q   �   q  1  	� 
  a  !  	�    �  A  	�   Y    	� ;  y  9  	�   i  )  	�  	  �  I  	�   U   +  u  5  	� 
]  !len L   �S !ret y   ZT #pG  
�   	�   	�    N  pU�  �1  V�  #   W@   #�)  XS   #@-  Z�  #l:  [@   # �  \S   #(
�)  u>  ?  
=>  wy   #�7�>  xy   #�7
�   `   P   s   p  0  	� 
  `     	�     �  @  	�   X    	� ;  x  8  	�   h  (  	�    �  H  	�   T   � +  t  4  	� 
  �  J  	�   V   @  3  v  6  	�   f  &  	�    �  F  	� 	  ^    	� c  ~  >  	�   n  .  	�    �  N  	� `   Q   �   q  1  	� 
  a  !  	�    �  A  	�   Y    	� ;  y  9  	�   i  )  	�  	  �  I  	�   U   +  u  5  	� 
  `     	�     �  @  	�   X    	� ;  x  8  	�   h  (  	�    �  H  	�   T   � +  t  4  	� 
  �  J  	�   V   @  3  v  6  	�   f  &  	�    �  F  	� 	  ^    	� c  ~  >  	�   n  .  	�    �  N  	� `   Q   �   q  1  	� 
  a  !  	�    �  A  	�   Y    	� ;  y  9  	�   i  )  	�  	  �  I  	�   U   +  u  5  	� 
  ��  <� !�?  �@   �� #�  ��  � #�?  �_   Q� #  ��  �� #�?  �L   � +ret �y   .�  �  f   2�?  y   �D     (E     w0  3>  �  U3�C   �  T#�  "�  d�  *7  Qy   0E     �G     �� I  !>  R�  �� +len TL   ӌ +in U_   � +out U_   .� 4buf V�  �@#�  W�  e� 5  �E     @.  j   /C  �� /7  �� /+  B� 6p.  7O  �� 7[  �   8  QF     �.  n/C  y� /7   /+  � 6�.  7O  w� 7[  ��    2�?  �y   �G     �G     w�  3>  ��  U#�  ��  \�  *@  �y   �G     �I     ��   !z,  ��  �� !�?  ��  )� #�  ��  r� #2  ��  � #D  ��  R� #?  �L   �  2e?  �y   �I     �I     wf  3>  ��  U3�?  �y   T#�  ��  �  9�?  ��  �I     -J     w3>  ��  U#�  ��  6�   �   
�   	�   	�    N  pU�  �1  V�  #   W@   #�)  XS   #@-  Z�  #l:  [@   # �  \S   #(
  l"  �@  �  �J     �K     D  �2  m9   c  �8  oL   M3  7  p_   H3  =  v-   l  int m@  {S   �*  �   17  P�   �   �   �   	�   	@   	@    E#  Q�   �   
�   	�   	�    N  pU�  �1  V�  #   W@   #�)  XS   #@-  Z�  #l:  [@   # �  \S   #(
�   	�   	�    N  pU�  �1  V�  #   W@   #�)  XS   #@-  Z�  #l:  [@   # �  \S   #(
(  ��   #��B  �@   #�	A  ��   #�KA  �  #�/A  Đ  #�H  Š  #��F  �  #�DF  �  #��F  �  #��C  ˰  #�|G  ��  #�oA  υ   #�)�B  Ѕ   #�)2  ��  #�)yB  ��  #�-E  �@   #�-�D  �@   #�-8D  ��  #�.�B  �t  #�.�D  �t  #�.�C  �@   #�.�@  �@   #�.�D  W  #�.xC  �   #�.B  
t  #�. �  `  h�   �>  jP  :  �=  Pp  �<  q�   # �  rS   #�>  s�   #
  ">  2E  buf 3�  "Y  4L   #len 6L    $D  l N     tQ     ��   s mL  �� n oL   � m oL   3� p py  V� �D  qL   �� ?  r@   � %�	  hN     @/  ��
  &�	  l� &�	  �� &�	  <� '�/  (
  ��   )@0  �
  str �@   Τ  'p0  �C  �t  � Y
  �t  P�   $jC  �Q     
R     �� e  >  �E  �� len �L   B� s �L  ��  ,B  �  R     �W     � O  s �L  � A  ��   F� �C  �n  �� cD  ��   � )�0    �@  �@   ʩ '�0  len A  � .F  W  6�   *�T     �T     -  cc A  ��  +�V     6W     cc 0A  ��   �A  Z  �W     �[     Ǫ �  s [L  � A  \�   _� �C  ^n  �� cD  _�   � )P1  �  len �A  N� .F  �W  q�  +�Y      Z     cc �A  ��   C    �[     �]     ʭ b
  D  � �?  E@   �� s GL  � str H@   Q� n H@   �� �'  I�   Բ �?  JL   !�   K4  X�    -f   ,�C  ��   �_     �`     }� e  >  �E  -� s �L  v�  �B  O~  s PL   ,4  ��   �`     �a     �� �  >  �E  4� ret ��   j� .e  �`     �a     �&s  ��   /�B  ��   �a     �a     w)  0>  �E  U0�C  �#  T /OD  ��   �a     b     wy  0>  �E  U0�4  �y  T0G  �  Q L   �   ,�A  ��   b     �b     �� �  >  �E  �� G  ��   �   ��   Z� s �L  �� put ��   ڷ  /K  �   �b     �b     wt  0>  E  U0�  �   T0�  �   Q0�  �   R0�  �   Xs L  ��  /�B  3S   �b     d     w�  >  4E  !� @  5S   W� s 7L  �� �D  8S   �� �C  8S   c� str 9�  ��  !�C  �  :  s �L  "A  ��   1cD  ��   2#cc �A    !*C  C  �  s DL  "A  E�   1cD  G�   1�8  H@   1X  I�  1  I�  3�  #len pA  1.F  pW   2#cc xA    ,�$  ��    d     
u     � (  >  �E  � A  ��   � �@  ��   �� s �L  �� )�1  �  B  �  7� %�  �e     P2  �|  4  4
  '�2  (   Z� '�2  (-  ��    5:  g     3  �4V  4L  '�3  (b  ɿ (n  �� (z  R� (�  �� )�3  �  (�  ��  ' 4  (�  �� (�  ��     %�   h     `4  �  &�  4�  %�  Ch     �4  �5  &�  W�  )�4  �  L?  �@   z� 1?A  �@   %�  �h      5  �|  &�  ��  %�  Bi     @5  ��  &�  ��  5�  `i     �5  �&�  	�   )�5  �  beg �@   ,�  ) 6    beg @   �� val �   1�  '�6  beg 7@   �� val 8�   2�   ,�+  ��   u     7v     �� �  >  �E  �� �  ��   �� 
(  ��   T� s �L  �� 77  �&  �� err ��   6�  ,UA  ��   @v     'w     �� �  >  �E  X� �  ��   ��  6C  ��   0w     z     �� �  7>  �E  �� 7�  ׅ   P� 7�  ؅   �� 78  م   � 7-   څ   y� 7
(  ۅ   �� 8�2  ��  � 8�>  ݅   �9s �L  }� :�'  ��   �� ;�@  ��  :�@  ��  9�  �  -~   ~   �  _    -�  6�A  ��   z     9z     �� H  7>  �E  �� 7�  ˅   � 7�2  ��  )� 7�>  ͅ   `�  ,jD  ��   @z     |     �� �  z,  �E  �� �?  �E  �� ds �L  )� ss �L  r� �@  ��  ��  �  �  _   	 <�D  ��  	@"     -�  �  �  _   	 =>,  3  -�  A    > ?D  ?"  -	  ?E  @5  -	  ~   J  _   C @XC  6`  	��     -:   �   �  l"  VE  �  |     ��     �P  �2  m9   c  �8  oL   M3  7  p_   H3  =  v-   l  int �*  �   17  P�   �   �   �   	�   	@   	@    E#  Q�   �   
�   	�   	�    N  pU�  �1  V�  #   W@   #�)  XS   #@-  Z�  #l:  [@   # �  \S   #(
�)  u>  ?  
=>  wy   #�7�>  xy   #�7
�E   I    �     1�     x� �  �F  !�   k� �>  "�  T#F  #4   �� =  $�  6� G  %�  n� T=  &�  �� 
�   	�   	�    N  pU�  �1  V�  #   W@   #�)  XS   #@-  Z�  #l:  [@   # �  \S   #(
(  ��   #��B  �@   #�	A  ��   #�KA  ��  #�/A  ��  #�H  ��  #��F  �S  #�DF  �S  #��F  �S  #��C  ��  #�|G  �	  #�oA  ϑ   #�)�B  Б   #�)2  �  #�)yB  �+  #�-E  �@   #�-�D  �@   #�-8D  �1  #�.�B  �z  #�.�D  �z  #�.�C  �@   #�.�@  �@   #�.�D  ]  #�.xC  �   #�.B  
z  #�. �  `  h�   �>  j\  F  �=  Pp$  �<  q�   # �  rS   #�>  s�   #
  !s �	  7� "�G  ��  T!k ��   m� #v ��   �� #j ��   $�  �E  �#  s �	  FF  �#  �G  ��  �C  ��   F  �C  �>  �N  �G  ��   H  ��   h ��   n ��   m ��   G  ��   �G  ��   f �]  !H  ��    �   �G  i@�     �     �� :
  `�      7  �z  '�
  3� 'x
  �� (@7  )�
  �� )�
  � )�
  �� )�
  �� )�
  :� )�
  �� )�
  �� )�
  .� )�
  �� )�
  �� )   �� )  �� )  �   *�  ��     �     �+�  +�  +�  ,��     �     -�  ��)�  8� )�  o� )�  �� ,��     ��     )�  �� *Y  ��     �     Z'k  �� 'w  #� ,��     �     )�  [�        �F  � �     -�     �� �
�   a ,B�     ��     #val 
�   �   /�8  �  #len 
�   � (09  #val 
�   �   /�9  �  #len 
 #lc *�   �
 #lx +L   �
 %�  ,L   9 %�>  -�   � /�:  !  #len 8�   W ,��     �     #val 8�   �   /�:  Q  #len 3�   � (;  #val 3�   �   /@;  �  #len <�   	
 /`>  ,  4len ��   (�>  #val ��   @   (�>  #len ��   d ,,�     h�     4val ��       KF  D'  s E	  H  F�   [G  G�    H  H�   �F  J�   6�  len P�   val P�     6�  len Q�   val Q�     6
  len R�   val R�     len U�   val U�      3�G  �p�     �     � �  !s �	  � !buf ��	  � $bG  �z  T $�.  ��   � %3G  �z   %dF  �z  � %<G  ��   � &�	  ��     0?  ��  '�	  � (p?  )�	  	   /�?    #len ��   @ (�?  #val ��   �   &b  ��     @  �  '�  � '�  � 'z  ; 'p  z (`@  )�  � /�@  �  )�  � ,Þ     &�     )�     /�@  �  )�  8 ,/�     ��     )�  p   / A  �  )�  � ,��     �     )�  �   (`A  )   (�A  )  +     &@	  �     B  �9  +N	  (@B  )X	  N   &	  k�     pB  �[  ',	  r  /�B  �  #len ��   � ,H�     ��     #val ��   �   5c	  p�     �B  �+u	  ( C  )	   7�	     8�G  ��    �     Ť     w  .s �	  U$.F  �L   ( !lc �L   q  �   '  _    9�F  ><  	��       �   Q  _    9�F  Af  	��     A  �   {  _    9�G  D�  	@�     k  G  �  _    9mG  G�  	 �     �  �  �  _    9�G  �  	 �     �  �  �  _    9�F  @  	 �     �  9�G  v)  	@�       9)F  {C  	��     A  9�F  }�  	�""     9=F  ��  	 #"     9�F  ��  	 #"     G  �  _   � :D  f�  	 �     �  G  �  _   � :E  I�  	 �     �   ;     l"  VH  �  Ф     ��     '[  �2  m9   c  �8  oL   M3  7  p_   H3  =  v-   l  int f      <  *H  �   Ф     ؤ     w�   r   �(  #S   �     �     w�   	�9  %S   � GH  ��   �     �     w"  
err �y   U 6H  ��     2�     wp  z,  ��   � �?  �p  � 
s1 �p  U
s2 �p  T
  	I  
! I/  :;  & I  
  
  &   :;  
  :;   
  !:;  "
  ':;  (:;  ):;  *'I  +
  E.?:;'I@
  F.:;'I@  G  H4 :;I
  I.1@  J 1  K4 1  L4 1  M1RUXY  N 1  O1XY  P4 :;I  Q4 :;I  R4 :;I  S4 :;I
  T1RUXY  U1RUXY  V 1  W 1
  X.:;'@  Y1XY  Z4 :;I
  [  \4 :;I
  ]4 :;I  ^4 :;I?<  _!    %   :;I  $ >  $ >  .:;'I    :;I  4 :;I  4 :;I  	.1@
  
 1  4 1  .?:;'I@
  
   %  $ >   :;I  $ >  .:;'I    :;I  4 :;I   I  	.:;'@
  
 :;I
   :;I
  4 :;I  
  4 :;I
  1XY  I  ! I/  . ?:;'I@
  & I  .?:;'I@   :;I  .?:;'I@
  4 :;I
   %   :;I  $ >  $ >      :;I   I  'I  	 I  
'  :;  
  
   <  :;  :;  ( 
  ! I/  .?:;'I@   :;I  4 :;I   :;I   4 :;I  !4 :;I  "4 :;I  #4 :;I
  $
 :;  %1RUXY  & 1  'U  (4 1
  ).?:;'I@  * :;I   %   :;I  $ >  $ >      :;I   I  'I  	 I  
'  :;  
  
   <  :;  :;  ( 
  ! I/  .:;'I    :;I  4 :;I  4 :;I   .:;'I@  ! :;I  " :;I  #4 :;I  $.?:;'I@
  % :;I
  &4 :;I  ' :;I  (.?:;'I@  )4 :;I  *.?:;'I@  +4 :;I  ,4 :;I
  -
 :;  .1XY  / 1  0  14 1
  2.?:;'I@
  3 :;I
  44 :;I
  51RUXY  6U  74 1  81RUXY  9.?:;'I@
   %   :;I  $ >  $ >      :;I   I  'I  	 I  
'  :;  
  
  :;  
  .?:;'I@   :;I  4 :;I
  4 :;I  & I   %   :;I  $ >  $ >      :;I   I  'I  	 I  
'  :;  
  
  :;  
  .?:;'I@   :;I  4 :;I
  4 :;I  & I  .?:;'I@
  .?:;'I@
   %   :;I  $ >  $ >      :;I   I  'I  	 I  
'  :;  
  
  :;  
   :;I  :;  
  !.:;'I   " :;I  #4 :;I  $.:;'@  %1RUXY  & 1  'U  (4 1  )U  *  +  ,.?:;'I@  -& I  .1XY  /.?:;'I@
  0 :;I
  14 :;I  2  3  4 1  51RUXY  6.?:;'I@  7 :;I  8 :;I
  94 :;I  :4 :;I  ;4 :;I  <4 :;I
  =4 :;I?<  >!   ?4 :;I?<  @4 :;I?
   %   :;I  $ >  $ >      :;I   I  'I  	 I  
'  :;  
  
   <  :;  :;  ( 
   :;I  4 :;I
  4 :;I  4 :;I  4 :;I
  4 :;I  
 :;   %  $ >  $ >  :;  
  
   :;I  :;  	( 
.?:;'I@   :;I   :;I
  
   I  & I  I  ! I/  4 :;I?
   %   :;I  $ >  $ >      :;I   I  'I  	 I  
'  :;  
  
  :;  
   :;I  :;  
  #4 :;I  $ :;I  %4 :;I  &1RUXY  ' 1  (U  )4 1  *1XY  + 1  ,  -4 1
  . :;I
  /U  0.1@
  1 1
  2.?:;'@
  3.?:;'@  44 :;I  51RUXY  6  74 1  8.?:;'I@
  94 :;I
  :4 :;I?
   %   :;I  $ >  $ >   I  . ?:;'I@
  & I  .?:;'I@
  	4 :;I  
 :;I
  .?:;'@
   :;I  
   52   �  �
t �s. �J . " , L g p� (-u-Y&�4)�� J � u. < "0 � 
t �s. �J . " , L g p� (-u-�~&�8)x� J � u. < "0 � t �t. �t . " , L g l (-u-UȮ4)�� J � u. < "0 � �ut �� �t� �� & " , L g l� (-u-YȮ4)�� J � u. < "0 � 
t �u. �
t . " , L g p (-u-YȮ4)�� J � u. < "0 � 
t �u. �
t . " , L g p (-u-UȮ4)�� J � u. < "0 � t �u. �
t . " , L g l (-u-UȮ4)�� J � u. < "0 � t �u. �
t . " , L g l (-u-�}Ȯ4)�� J � u. < "0 � 
t �v. �	t . " , L g p (-u-�Ȯ8)x� J � u. < "0 � 
t �w. �J . " , L g p� (-u-Y&�4)�� J � u. < "0 � 
t �w. �J . " , L g p� (-u-Y&�4)�� J � u. < "0 � 
t �w. �J . " , L g p� (-u-Y&�4)�� J � u. < "0 � 
t �w. �t . " , L g p (-u-YȮ4)�� J � u. < "0 � 
t �x. �J . " , L g p� (-u-Y&�4)�� J � u. < "0 � 
t �x. �t . " , L g p (-u-�~Ȯ4)�� J � u. < "0 � 
t �x. �t . " , L g p (-u-YȮ4)�� J � u. < "0 � 
t �x. �t . " , L g p (-u-YȮ8)x� J � u. < "0 � 
t �y. �t . " , L g p (-u-�|Ȯ4)�� J � u. < "0 � 
t �z. �J . " , L g p� (-u-Y&�4)�� J � u. < "0 � 
t �z. �J . " , L g p� (-u-Y&�4)�� J � u. < "0 � 
t �z. �t . " , L g p (-u-YȮ4)�� J � u. < "0 � 
t �z. �t . " , L g p (-u-YȮ4)�� J � u. < "0 � 
t �{. �J . " , L g p� (-u-Y&�4)�� J � u. < "0 � 
t �{. �t . " , L g p (-u-YȮ4)�� J � u. < "0 � 
t �{. �J . " , L g p� (-u-Y&�8)x� J � u. < "0 � 
t �{. �t . " , L g p (-u-YȮ4)�� J � u. < "0 � 
t �{. �t . " , L g p (-u-YȮ4)�� J � u. < "0 � 
t �|. �t . " , L g p (-u-YȮ4)�� J � u. < "0 � 
t �|. �t . " , L g p (-u-�y��5)x� J 
< 0 � + � �
J . n� �X � 0�u-�n%Ys=u�t<YK�� � fNU%�?G nf � st K��.4)��Z,uJ<� J � H ? ��~f"� � �� � f� � �� > K  �i #�~'�֟��-= & " , L g �~  �t � ( �0 �~@���O#4)��Z,vJ
<� J �~� "� � � � fK � ���~(��u�Y-= & " , L g �~< (< � � x0����f�4)��w�
<- � �v+ �� ���Z�	�� i� �v� t�	f	f�}*�4)��w�
<- � �x+ �� ���Z��� i� �x� t�f	f�p*#�� � vYK� ��
t�g� �� �w a' Y "&g<�v� k& Y��
�8)x�D � ( � g � = � > f � �5 � �zt �  �z� �X �z. �< & " , L g e< � r 0 0 02q-�{��4)��w�
<- � �|+ �� ����� m� �|� t�f	f�|*4)��y�C � ' � = � � f �}� �� �}� �X �}. �< & " , L g pX � r 8,[$4)��y�C � ' � = � � f �~� �� �}� �X �}. �< & " , L g pX � r 8,�$�5)x� J � Y - v< J / " , Z � z���{�s /w]iy<_y ���4)��v�
< �0 � 
( �t. �t � 2 � / + � g q��v-�x�4)��\*xJD@~\ f0 � �x+ "� �   K P zJ M � ~ P Y s A K g - Kh��Ys� + � / + � g W< �x� �<�t< �t jt���t-�}�:E��YIxJD��rJX *9 ( � xJ ��yf�vZHZ fٱ � � W N � � Z H m< Xkg�wHvn�.�y� ��� �#�.��y���73	f g ;=# [�~AL$�KYK9 <�K;w:�+1
� �z����u� �
f# ���z+f��ti/�yfU2��<4)��D � ' � g � = � � �0 � �|tg�g�g̈́G��Z��t ;� �|. �� = s � + � / + � g Kf � 0 0 00r-�~#87��	Xw<xJR	� $2 � ) xJ 	< ��|f�ryZH>i��usKK�qMY�;Zsct��ZwP� � V h ���gs� 1 � 2 9 � � �J � xJ 	J w� �i ��}�r�&Z=HM9w�V��Z,ɻ � �%9 ��h.f�~387��Y;xJR�_y<� $2 � �}t � w �� � g W K > , L : >i��H>jY�ueKK�qMY�;Zs c '���-/ sX�L([I;M9jK0d?+w/���us� 3 � 2 9 � � �� �}8 q� f9z��1t � �����f�}.�|�&7;�zJw���/g0Y���t7)��
< � ( � g � g � = � = � g � � �0 � �ttP+srg��&+?l=-X�.�tJ X 2 , L J�ȡ �. � 8 0 0 0 0 0 �t+" @�/s%-= � � t �h(�M9wk/����� � (��n-�m�B)x�w�	< . ( � g � = � = � = � g � � �}�P�w7uxz<j�&yfCg ��5�.�~X���~J$,> Z , � J�ȡ �< � 0 0 0 0 0 �~0�/s%-= � � tf� tt��M+w�=- 
� ( gt����#�4)��v�
< �0 � �v+ � - =�	f� 2 � / + � g n� �vt � - =g�	�v-�y�4)��v�
< �0 � �y+ � - =�f� 2 � / + � g n� �yt � - =g��v-�y�4)��v�
< �0 � �}+ � - =�f� 2 � / + � g n� �}t � - =g��v-�~�-Fxpەv.DL � ( � = � � �}�v�-=j���0 � t * ) A Z , � J�ȡ �X � 0 �~0�/s%-= � � ts�i �Y(�� � J �� !� (nt	Xwt o< ��t�|�%C�z��.�zJ J �� k. J � � �z� ���}.���J� �y( �( ���~0�r�| uu-� � ���
��}X�fi��}.�X�}J�t �}<���}X���}J�X�}��*�}t�.�}����}t�.�}��X�}��X�}<�.�}<���}t�.�}J�.�}J�(�}f���}J�t�}f���}J�t�}f���}J�t�}f���}J�t�}f���}J���|J�%�|J���4)��v�
< 0 � 	+ -i � i +P�� l�� � 0 �y�v-�y#�4)��v�
< 0 � 	+ -i � i +P�� l�� � 0 �y�v-�y#�8)x�v�
< 0 � 	+ -i � i +P�� l�� � 0 �y�v-�
�Ks" - � 5 G � � �uJ (� �
� 	f 
��i��
. 
t��4.Igu�Ih;uY. e�� �
��k+Y�}J��X��-�,t��}J����p/�Ȅ
     � � nJ /X�K>FX���C�qX�W  = r^��Jf7tJ<Y>F;�\�@f� X��KY>F� �[>�~<�W!f�h��g|J�dJ �  ; =/���� M   i   �
X^=L�}t��y��~t� + + r L H 0 : �� J �~� � & J�t�~֭ % & J]� � � & J�/�hV>��[��~ =>9=LGZ>:>=vyXLvM f	� � X ��KsLr3u�=��[-��uL���h<��W<�vVK��f���/��%�~X=;v��Xu�. �̝KI� 1 q M H > : s 0� J.��~.z.lw�U?9i�NG1*/Y=v<.uJh J�� �~�&� gIYQ��Ih�[� ��}tuWK :.h)�nXX�XgIYJh���vVK��|Xru����~�H�J����ZH>uM+Mn�~� ��� (O.Y-K / � % J�Y-�B' � r L H > : �u J%$�K;h 4 � > : � �� J.���vVK��~X�I� Ƽ� � � 0 : �� J'g�,K;f � � ' J��+?9N-K / � ' J<�Y-�;MKe/IhvVK��~X�;?+?s=Ii�W/���KPz<4SK/-C�/�}.�t�}J �f �X= p�&� �~< J ' J t) < # J)��;>I=:��u;is=e�٭vVK�pX�	��[;�uL�KvVK�Zv��L����; = ."g�/S] �	   i   �
�Ʈ�u � H =� �ˑ�0:Z! ? : 0 : � 0'�uI?:u�j��|�J�u�)u � H K�@�K�Y�0g 8 : 0 : � 0#YI/���� �{�X . ���K���� �X f ���I�Y� � C	��vVK���[J�[��LYYKF->;>=K� n�X . ��=>9=LGZ>:>=vyXLvM f���}�� KX �K�;uI:0� O�=��[e�+uL>,>�vVK��}� �t�#u � H ˣK;f �t < ���/=eils=� �}JX . ��Iug�� �X . ���u�ʁ���~J �X X ��IKY��Wk���~�K������ٟsK / IZIZ���==�K���#�sK / IZIZ���==�K� �X � ���vVK��X��I� J��KIK/ggK� �W�YI =� X 0 , L ��t�KIv�� �X J ��ugKL $-��2:�vVK��{��J � �X . ��ɭ���}� J ���vVK�.��@= � ���|t�����W��~�Ke�X�j.������ �g�-�{<�t�{J �X �YI=�|t�� � IZZ;KI;�I-== ��J < ��u-0r�;� �	���{����vVK�R�փIZWugvVK��~t/�=������H�IK;/�I/;K�	<�}��H����O�K=�K �|��^�{Xvs�L�J��uWK�� [;�\�vVK��~XZSj��~�vVK�\XvVK� ?X % - Y ; �(t f ��u�;LI=:� �t . ���/=e� �=���\��{���,ZHYWKh�M0t���� ���~t�2��vVK��~X�e� �XaFLI��PZH0/qL/I�/W��.�~X[;�UuL�,>�vVK��}X�oCVK��X���Xu�Xv��L�,>�B�����: > .# �ב�/y�_�(x<D fʔf:KK=u:L�,KK2v/ e' K W3�KW�uh�"� X�iL-u�x..��� �ʯ�su/;=;?9Mmf�mfvH==:�a��y<�Z�1y<	�w�*.V<�gy<�h�1y<	�#f@UH>M�K�L,KvL& �
%Y�;t �� X�u ����#   � I���:>h���->:>m����;�/=IY;/ZZ-L t� sZ=p�y�zz�t ���0 X�u- � t��dr� �    @   �
�	��I� A   X   �
<YK
X� ��JO�  u ���-.S<-< � eu�	���J� J��J� J � �J � J��J� J � �J � J��J� J � �J � J��� � �飙=W/x�:h3W��Ys��Fxe���z�<:tSXz. �n<J!��}��J�|�f�}<L�<�}<�J�}X�@�Y��c��gI/g;= ��ZH��e>e=;g` ���|���.=uJg_f+Jw.^t+<UJ-XK-=�;=2Mt5�K-=�8@2:03���\�9�u;YtJ�'�=;٭z�|X�v��|fZL��Xw��uKKKg-=/��� ���
�
.rP��ى�"�hI�0,i;u f�z(j��� �;g2hV�  f �" X � < �X � <z.  f + zX B�~�2T_yJCG
�jq�Y)k .v0-eh � f+�K � f/._փ��I�2�VY � f K" <�� f f�u>m �[K � � u W��9w
�Yu<
J=uf� t��Ks=e��t�IK�JJur@T���;�f �v���t���vX�	JY�vX�	JY�vX�	JY�vX�	JY�vX�	JY�vX�	J�vX�	J��vX�	JV?�-gg	�fh�>gc<�wZ ���/<u;�K-gs�� ���=e/���xT��= ����<u;�K-gs�� ���=e/�~��� #� �= ����u�=�-u-=��o�a�u��-�I�j��v>� �u-�atgt ��� �<�c�"��� �=I=�I=�I=�I=�I=�I=�s=�}J�:K��I=
� �$�I��
���WJ)XkY <Yw�IK�;=�zfM?aA,�K=>MSM;K�I=-K�IK�IK��N�V�vvUK� f�/LqNuTBy<u{�M�I�;�.X�.� �s�;�Y`��K���	�  Π;=h;K�>�;K�;K�eK�G=L ���//"K�I/>qYvupxu�0X��r� �   [   �
<>o�nxf�g;/�EY�� X bY f � - u � � _� �<fy�0dv=?T�iU���u<
fuYL�.L/-Z;=/�{.�� X��w.� �Pv<
 vS�S��
�Z�z�1oJY=;g XZZK J��ZG/q.<p�.r�Y5=���My.ptIg J�  �䒽z�?iJ�܃� +h X j  	M w< 	��G=k<.j�fq�� %s��=� x H % g � wc� � H�X5y<5y.Q	� �Yb���YY��;Y �b�K� aK � � �`��� . L xf `� � u I � - � g< � � � � v� � E - g - � - �� ��Yg�r�,��y�	t�v�u��������>�Yo<��s! ��f�.l���Y-/-�-K�x.|�}f���=��}.��� �}'
t�` J�~��<�~ig� cA�_>�-��>�4wq�� ����|��u�<�{.�Y�<�.�,��~�d� �u�~���	��J��~�ZX&.`���;�,/wI���~X ;� z`�b���"
        w 
               w(       m       w0m      n       w(n      p       w p      r       wr      t       wt      x       wx             w0                                U                                T       {        \u      �       \�             \                       "        p "       H        ]"      O       VO      _       v�                +       7        p� 7       8        V8       �        v��              Vu      �       v��      �       V�             v�                8       Z        v  $ &3$p"��      �       Q                8       H        } v  $ &3$p8�                	             P                             p      t       ^                {       p       \�      �       \                U      u       1�                       "       w"      $       w$      &       w&      *       w *      +       w(+      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      1       w0                       4       U                       8       T8      �       \�      �       \      1       \                >      B       p B      h       ]B      o       Vo             v�                K      W       p� W      X       VX      �       v��      7       V�      �       v��             V      1       v�                X      z       v  $ &3$p"�             Q                X      h       } v  $ &3$p8�                )      ;       P                /      ;       p;      �       ^                �      �       \�             \                u      �       1�                @      B       wB      D       wD      F       wF      J       w J      K       w(K      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      Y       w0                @      T       U                @      X       TX      �       \�      �       \B      Y       \                ^      b       p b      �       ]e      �       V�      �       v�                k      w       p� w      x       Vx      �       v��      Z       V�      �       v��      B       VB      Y       v�                x      �       v  $ &3$p"�B      F       Q                x      �       } v  $ &3$p8�                I      ^       P                R      ^       p�^      �       ^                �      �       \�      B       \                �      �       1�                `      b       wb      d       wd      f       wf      j       w j      k       w(k      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      �       w0                `      t       U                `      x       Tx      �       \�      �       \r      �       \                ~      �       p �      �       ]�      �       V�      �       v�                �      �       p� �      �       V�      �       v��      �       V�             v�      r       Vr      �       v�                �      �       v  $ &3$p"�r      v       Q                �      �       } v  $ &3$p8�                i      �       P                �      �       ^                �      �       \      r       \                �      �       1�                �      �       w�      �       w�      �       w�      �       w �      �       w(�       
       w0 
      
       w(
      
       w 
      
       w
      
       w
      
       w
      �
       w0                �      �       U                �      �       T�      	       \
      
       \�
      �
       \                �      �       p �      �       ]�	      �	       V�	      �	       v�                �      �       p� �      �       V�      	       v�	      �	       V
      1
       v�1
      �
       V�
      �
       v�                �      �       v  $ &3$p"��
      �
       Q                �      �       } v  $ &3$p8�                �	      �	       P                �	      �	       p��	      
       ^                	      
       \1
      �
       \                �	      
       1�                �
      �
       w�
      �
       w�
      �
       w�
      �
       w �
      �
       w(�
              w0       !       w(!      #       w #      %       w%      '       w'      0       w0      �       w0                �
      �
       U                �
      �
       T�
      +       \(      ;       \�      �       \                �
      �
       p �
      �
       ]�             V             v�                �
      �
       p� �
      �
       V�
      0       v�0      �       V(      Q       v�Q      �       V�      �       v�                �
      
       v  $ &3$p"��      �       Q                �
      �
       } v  $ &3$p8�                �      �       P                �      �       p��      '       ^                +      #       \Q      �       \                      (       1�                �      �       w�      �       w�      �       w�      �       w �      �       w(�      @       w0@      A       w(A      C       w C      E       wE      G       wG      P       wP      �       w0                �      �       U                �      �       T�      K
       Vh      �       v��      �       V�      	       v�                (      J       v  $ &3$p"��      �       Q                (      8       } v  $ &3$p8�                �             P                             p�      g       ^                k      c       \�      �       \                H      h       1�                             w             w             w             w              w(      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      )       w0                      $       U                      (       T(      �       \�      �       \      )       \                .      2       p 2      X       ]5      b       Vb      r       v�                ;      G       p� G      H       VH      �       v��      *       V�      �       v��             V      )       v�                H      j       v  $ &3$p"�             Q                H      X       } v  $ &3$p8�                      .       P                "      .       p�.      �       ^                �      �       \�             \                h      �       1�                0      2       w2      4       w4      6       w6      :       w :      ;       w(;      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      A       w0                0      D       U                0      H       TH      �       \�      �       \*      A       \                N      R       p R      x       ]R             V      �       v�                [      g       p� g      h       Vh      �       v��      G       V�      �       v��      *       V*      A       v�                h      �       v  $ &3$p"�*      .       Q                h      x       } v  $ &3$p8�                9      K       P                ?      K       p� K      �       ^                �      �       \�      *       \                �      �       1�                P      R       wR      T       wT      V       wV      Z       w Z      [       w([      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      a       w0                P      d       U                P      h       Th      �       \�      �       \J      a       \                n      r       p r      �       ]r      �       V�      �       v�                {      �       p� �      �       V�      �       v��      g       V�      �       v��      J       VJ      a       v�                �      �       v  $ &3$p"�J      N       Q                �      �       } v  $ &3$p8�                Y      k       P                _      k       pk      �       ^                �      �       \�      J       \                �      �       1�                p      r       wr      t       wt      v       wv      z       w z      {       w({      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      �       w0                p      �       U                p      �       T�      �       \�      �       \j      �       \                �      �       p �      �       ]�      �       V�      �       v�                �      �       p� �      �       V�      �       v��      �       V�      	       v�	      j       Vj      �       v�                �      �       v  $ &3$p"�j      n       Q                �      �       } v  $ &3$p8�                y      �       P                      �       p(�      �       ^                �      �       \	      j       \                �      �       1�                �      �       w�      �       w�      �       w�      �       w �      �       w(�              w0              w(             w              w             w             w      �       w0                �      �       U                �      �       T�             \             \�      �       \                �      �       p �      �       ]�      �       V�      �       v�                �      �       p� �      �       V�             v�      �       V      1       v�1      �       V�      �       v�                �      �       v  $ &3$p"��      �       Q                �      �       } v  $ &3$p8�                �      �       P                �      �       p��             ^                             \1      �       \                �             1�                �      �       w�      �       w�      �       w�      �       w �      �       w(�             w0             w(              w        "       w"      $       w$      (       w(      �       w0                �      �       U                �      �       T�      +       \%      3       \�      �       \                �      �       p �      �       ]�      �       V�             v�                �      �       p� �      �       V�      0       v�0      �       V%      I       v�I      �       V�      �       v�                �      
       v  $ &3$p"��      �       Q                �      �       } v  $ &3$p8�                �      �       P                �      �       p�      $       ^                +              \I      �       \                      %       1�                �      �       w�      �       w�      �       w�      �       w �      �       w(�      @       w0@      A       w(A      C       w C      E       wE      G       wG      P       wP      �       w0                �      �       U                �      �       T�      K       \H      [       \�      �       \                �      �       p �             ]�      "       V"      2       v�                �             p�              V      P       v�P      �       VH      q       v�q      �       V�      �       v�                      *       v  $ &3$p"�*      P       v  $ &3$~ "�P      �       v $ &3$~ "�H      q       v  $ &3$~ "��      �       Q�      �       v  $ &3$~ "�                             } v  $ &3$p8�                �      �       P                �      G       ^                K      C       \q      �       \                (      H       1�                �      �       w�      �       w�      �       w�      �       w �      �       w(�      `!       w0`!      a!       w(a!      c!       w c!      e!       we!      g!       wg!      p!       wp!      	"       w0                �              U                �              T       k        \h!      {!       \�!      	"       \                               p        8        ]!      B!       VB!      R!       v�                       '        p� '       (        V(       p        v�p       
!       Vh!      �!       v��!      �!       V�!      	"       v�                (       J        v  $ &3$p"��!      �!       Q                (       8        } v  $ &3$p8�                �       !       P                !      !       p�!      g!       ^                k       c!       \�!      �!       \                H!      h!       1�                "      "       w"      "       w"      "       w"      "       w "      "       w("      �#       w0�#      �#       w(�#      �#       w �#      �#       w�#      �#       w�#      �#       w�#      )$       w0                "      $"       U                "      ("       T("      �"       \�#      �#       \$      )$       \                ."      2"       p 2"      X"       ]5#      b#       Vb#      r#       v�                ;"      G"       p� G"      H"       VH"      �"       v��"      *#       V�#      �#       v��#      $       V$      )$       v�                H"      j"       v  $ &3$p"�$      $       Q                H"      X"       } v  $ &3$p8�                #      .#       P                "#      .#       p�.#      �#       ^                �"      �#       \�#      $       \                h#      �#       1�                0$      2$       w2$      4$       w4$      6$       w6$      :$       w :$      ;$       w(;$      �%       w0�%      �%       w(�%      �%       w �%      �%       w�%      �%       w�%      �%       w�%      I&       w0                0$      D$       U                0$      H$       TH$      �$       \�%      �%       \2&      I&       \                N$      R$       p R$      x$       ]U%      �%       V�%      �%       v�                [$      g$       p� g$      h$       Vh$      �$       v��$      J%       V�%      �%       v��%      2&       V2&      I&       v�                h$      �$       v  $ &3$p"�2&      6&       Q                h$      x$       } v  $ &3$p8�                9%      N%       P                B%      N%       p�N%      �%       ^                �$      �%       \�%      2&       \                �%      �%       1�                P&      R&       wR&      T&       wT&      V&       wV&      Z&       w Z&      [&       w([&      �'       w0�'      �'       w(�'      �'       w �'      �'       w�'      �'       w�'      �'       w�'      a(       w0                P&      d&       U                P&      h&       Th&      �&       \�'      �'       \J(      a(       \                n&      r&       p r&      �&       ]r'      �'       V�'      �'       v�                {&      �&       p� �&      �&       V�&      �&       v��&      g'       V�'      �'       v��'      J(       VJ(      a(       v�                �&      �&       v  $ &3$p"�J(      N(       Q                �&      �&       } v  $ &3$p8�                Y'      k'       P                _'      k'       p� k'      �'       ^                �&      �'       \�'      J(       \                �'      �'       1�                p(      r(       wr(      t(       wt(      v(       wv(      z(       w z(      {(       w({(      �)       w0�)      �)       w(�)      �)       w �)      �)       w�)      �)       w�)      �)       w�)      �*       w0                p(      �(       U                p(      �(       T�(      �(       \�)      �)       \j*      �*       \                �(      �(       p �(      �(       ]�)      �)       V�)      �)       v�                �(      �(       p� �(      �(       V�(      �(       v��(      �)       V�)      	*       v�	*      j*       Vj*      �*       v�                �(      �(       v  $ &3$p"�j*      n*       Q                �(      �(       } v  $ &3$p8�                y)      �)       P                )      �)       p(�)      �)       ^                �(      �)       \	*      j*       \                �)      �)       1�                �*      �*       w�*      �*       w�*      �*       w�*      �*       w �*      �*       w(�*       ,       w0 ,      ,       w(,      ,       w ,      ,       w,      ,       w,      ,       w,      �,       w0                �*      �*       U                �*      �*       T�*      +       \,      ,       \�,      �,       \                �*      �*       p �*      �*       ]�+      �+       V�+      �+       v�                �*      �*       p� �*      �*       V�*      +       v�+      �+       V,      1,       v�1,      �,       V�,      �,       v�                �*      �*       v  $ &3$p"��,      �,       Q                �*      �*       } v  $ &3$p8�                �+      �+       P                �+      �+       p��+      ,       ^                +      ,       \1,      �,       \                �+      ,       1�                �,      �,       w�,      �,       w�,      �,       w�,      �,       w �,      �,       w(�,       .       w0 .      !.       w(!.      #.       w #.      %.       w%.      '.       w'.      0.       w0.      �.       w0                �,      �,       U                �,      �,       T�,      +-       \(.      ;.       \�.      �.       \                �,      �,       p �,      �,       ]�-      .       V.      .       v�                �,      �,       p� �,      �,       V�,      0-       v�0-      �-       V(.      Q.       v�Q.      �.       V�.      �.       v�                �,      
-       v  $ &3$p"��.      �.       Q                �,      �,       } v  $ &3$p8�                �-      �-       P                �-      �-       p��-      '.       ^                +-      #.       \Q.      �.       \                .      (.       1�                �.      �.       w�.      �.       w�.      �.       w�.      �.       w �.      �.       w(�.      =0       w0=0      >0       w(>0      @0       w @0      B0       wB0      D0       wD0      H0       wH0      �0       w0                �.      �.       U                �.      �.       T�.      K/       \E0      S0       \�0      �0       \                �.      �.       p �.      /       ]�/      0       V0      /0       v�                �.      /       p� /      /       V/      P/       v�P/      �/       VE0      i0       v�i0      �0       V�0      �0       v�                /      */       v  $ &3$p"�*/      P/       v  $ &3$~ "�P/      �/       v $ &3$~ "�E0      i0       v  $ &3$~ "��0      �0       Q�0      �0       v  $ &3$~ "�                /      /       } v  $ &3$p8�                �/      �/       P                �/      �/       p�/      D0       ^                K/      @0       \i0      �0       \                %0      E0       1�                �0      �0       w�0      �0       w�0      �0       w�0      �0       w �0      �0       w(�0      `2       w0`2      a2       w(a2      c2       w c2      e2       we2      g2       wg2      p2       wp2      	3       w0                �0      1       U                �0      1       T1      k1       \h2      {2       \�2      	3       \                1      1       p 1      81       ]2      B2       VB2      R2       v�                1      '1       p� '1      (1       V(1      p1       v�p1      
2       Vh2      �2       v��2      �2       V�2      	3       v�                (1      J1       v  $ &3$p"��2      �2       Q                (1      81       } v  $ &3$p8�                �1      2       P                2      2       p�2      g2       ^                k1      c2       \�2      �2       \                H2      h2       1�                3      3       w3      3       w3      3       w3      3       w 3      3       w(3      }4       w0}4      ~4       w(~4      �4       w �4      �4       w�4      �4       w�4      �4       w�4      !5       w0                3      $3       U                3      (3       T(3      �3       \�4      �4       \
5      !5       \                .3      23       p 23      X3       ]24      _4       V_4      o4       v�                ;3      G3       p� G3      H3       VH3      �3       v��3      '4       V�4      �4       v��4      
5       V
5      !5       v�                H3      j3       v  $ &3$p"�
5      5       Q                H3      X3       } v  $ &3$p8�                4      +4       P                4      +4       p+4      �4       ^                �3      �4       \�4      
5       \                e4      �4       1�                05      25       w25      45       w45      65       w65      :5       w :5      ;5       w(;5      �6       w0�6      �6       w(�6      �6       w �6      �6       w�6      �6       w�6      �6       w�6      I7       w0                05      D5       U                05      H5       TH5      �5       \�6      �6       \27      I7       \                N5      R5       p R5      x5       ]U6      �6       V�6      �6       v�                [5      g5       p� g5      h5       Vh5      �5       v��5      J6       V�6      �6       v��6      27       V27      I7       v�                h5      �5       v  $ &3$p"�27      67       Q                h5      x5       } v  $ &3$p8�                96      N6       P                B6      �6       ^                �5      �6       \�6      27       \                �6      �6       1�                P7      R7       wR7      T7       wT7      V7       wV7      Z7       w Z7      [7       w([7      �8       w0�8      �8       w(�8      �8       w �8      �8       w�8      �8       w�8      �8       w�8      i9       w0                P7      d7       U                P7      h7       Th7      �7       \�8      �8       \R9      i9       \                n7      r7       p r7      �7       ]u8      �8       V�8      �8       v�                {7      �7       p� �7      �7       V�7      �7       v��7      j8       V�8      �8       v��8      R9       VR9      i9       v�                �7      �7       v  $ &3$p"�R9      V9       Q                �7      �7       } v  $ &3$p8�                Y8      n8       P                b8      n8       p�n8      �8       ^                �7      �8       \�8      R9       \                �8      �8       1�                p9      r9       wr9      t9       wt9      v9       wv9      z9       w z9      {9       w({9      �:       w0�:      �:       w(�:      �:       w �:      �:       w�:      �:       w�:      �:       w�:      �;       w0                p9      �9       U                p9      �9       T�9      �9       \�:      �:       \r;      �;       \                �9      �9       p �9      �9       ]�:      �:       V�:      �:       v�                �9      �9       p� �9      �9       V�9      �9       v��9      �:       V�:      ;       v�;      r;       Vr;      �;       v�                �9      �9       v  $ &3$p"�r;      v;       Q                �9      �9       } v  $ &3$p8�                y:      �:       P                �:      �:       ^                �9      �:       \;      r;       \                �:      �:       1�                �;      �;       w�;      �;       w�;      �;       w�;      �;       w �;      �;       w(�;       =       w0 =      =       w(=      =       w =      =       w=      =       w=      =       w=      �=       w0                �;      �;       U                �;      �;       T�;      <       \=      =       \�=      �=       \                �;      �;       p �;      �;       ]�<      �<       V�<      �<       v�                �;      �;       p� �;      �;       V�;      <       v�<      �<       V=      1=       v�1=      �=       V�=      �=       v�                �;      �;       v  $ &3$p"��=      �=       Q                �;      �;       } v  $ &3$p8�                �<      �<       P                �<      =       ^                <      =       \1=      �=       \                �<      =       1�                �=      �=       w�=      �=       w�=      �=       w�=      �=       w �=      �=       w(�=      �>       w0�>      �>       w(�>      �>       w �>      �>       w�>      �>       w�>      �>       w�>      �>       w0                �=      �=       U                �=      �=       T�=      ->       V�>      �>       V�>      �>       V                �=      �=       p �=      �=       \I>      v>       \v>      �>       |�                �=      �=       p� �=      �=       ]�=      3>       }�3>      �>       ]�>      �>       }�                �=      >       }  $ &3$p"��>      �>       Q                �=      �=       | }  $ &3$p8�                ->      �>       
p�                ->      �>       V                }>      �>       1�                �>      �>       w�>      �>       w�>      �>       w�>      �>       w �>      �>       w(�>      ]@       w0]@      ^@       w(^@      `@       w `@      b@       wb@      d@       wd@      h@       wh@      A       w0                �>      ?       U                �>      ?       T?      k?       \e@      s@       \�@      A       \                ?      ?       p ?      8?       ]%@      ?@       V?@      O@       v�                ?      '?       p� '?      (?       V(?      p?       v�p?      @       Ve@      �@       v��@      �@       V�@      A       v�                (?      J?       v  $ &3$p"��@      �@       Q                (?      8?       } v  $ &3$p8�                �?      @       P                �?      @       p� @      d@       ^                k?      `@       \�@      �@       \                E@      e@       1�                A      A       wA      A       wA      A       wA      A       w A      A       w(A      }B       w0}B      ~B       w(~B      �B       w �B      �B       w�B      �B       w�B      �B       w�B      !C       w0                A      $A       U                A      (A       T(A      �A       \�B      �B       \
C      !C       \                .A      2A       p 2A      XA       ]EB      _B       V_B      oB       v�                ;A      GA       p� GA      HA       VHA      �A       v��A      'B       V�B      �B       v��B      
C       V
C      !C       v�                HA      jA       v  $ &3$p"�
C      C       Q                HA      XA       } v  $ &3$p8�                B      +B       P                B      +B       p� +B      �B       ^                �A      �B       \�B      
C       \                eB      �B       1�                0C      2C       w2C      4C       w4C      5C       w5C      9C       w 9C      =C       w(=C      !D       w0!D      "D       w("D      #D       w #D      %D       w%D      'D       w'D      0D       w0D      iD       w0                0C      FC       U                0C      JC       TJC      �C       V(D      ;D       VRD      iD       V                PC      TC       p TC      {C       ]�C      �C       ]�C      'D       }�                ^C      jC       p� jC      kC       \kC      �C       |��C      D       \(D      iD       |�                kC      �C       |  $ &3$p"�RD      VD       Q                kC      {C       } |  $ &3$p8�                �C      �C       P�C      �C       ]                �C      D       V                D      (D       1�                pD      sD       U                pD      wD       T                �D      �D       U                �D      �D       T                �D      �D       Q                �D      �D       w�D      E       wE      E       wE      JE       w                �D      �D       P�D      JE       Q                PE      RE       wRE      TE       wTE      XE       wXE      YE       w YE      ]E       w(]E      �F       w0�F      �F       w(�F      �F       w �F      �F       w�F      �F       w�F      �F       w�F      �G       w0                PE      fE       U                PE      jE       TjE      �E       \�G      �G       \                pE      tE       p tE      �E       ]                }E      �E       p� �E      �E       V�E      �E       v��E      �F       V�F      �G       V�G      �G       v�                �E      �E       v  $ &3$p"��G      �G       Q                �E      �E       } v  $ &3$p8�                ?F      �F       \�F      kG       \                	G      -G       P                yF      �F       0�                �G      �G       w�G      �G       w�G      �G       w�G      �G       w �G      �G       w(�G      �I       w0�I      �I       w(�I      �I       w �I      �I       w�I      �I       w�I      �I       w�I      �J       w0                �G      �G       U                �G      �G       T�G      H       \�J      �J       \                �G      �G       p �G      �G       ]                �G      �G       p� �G      �G       V�G      	H       v�	H      YI       V�I      �J       V�J      �J       v�                �G      	H       v  $ &3$p"�	H      H       Q�J      �J       Q                �G      �G       } v  $ &3$p8�                I      )I       P�I      �I       P                pH      %I       ]�I      �I       ]�J      �J       ]                I      )I       R)I      �I       ^�I      �I       RJ      0J       ^                NH      [H       P                iI      �I       1�                 K      K       wK      �K       w �K      �K       w�K      �K       w �K      �K       w�K      NL       w                  K      "K       U"K      �K       V�K      �K       P�K      �K       V�K      NL       V                 K      &K       T&K      �K       \�K      �K       \�K      NL       \                PL      RL       wRL      TL       wTL      VL       wVL      XL       w XL      \L       w(\L      ]L       w0]L      aL       w8aL      �N       w� �N      �N       w8�N      �N       w0�N      �N       w(�N      �N       w �N      �N       w�N      �N       w�N      �N       w�N      �O       w�                 PL      jL       U                PL      nL       TnL      �L       \�M      �M       \�O      �O       \                tL      xL       p xL      �L       ]tN      �N       V�N      �N       v�                �L      �L       p� �L      �L       V�L      �L       v��L      XN       V�N      �O       V�O      �O       v�                �L      �L       v  $ &3$p"��L      �L       v  $ &3$~ "��L      �L       v $ &3$~ "��O      �O       Q�O      �O       v  $ &3$~ "�                �L      SM       ]�M      1N       ]�N      O       ]lO      �O       ]                FN      cN       U                CM      �M       ��1N      �N       ��O      lO       ��                CM      �M       ^1N      �N       ^O      lO       ^                M      �M       ��1N      lO       ���O      �O       ��                �L      �L       v 3$p "�L      M       ^M      M       PM      :M       ^�M      1N       ^�N      �N       ^�N      O       ^lO      �O       ^                iN      mN       PmN      �N       ]                �L      M       PM      �M       \�M      �N       \�N      �O       \                �N      �N       1�                 P      P       wP      P       wP      P       wP      P       w P      P       w(P      
R       w0
R      R       w(R      R       w R      R       wR      R       wR      R       wR      �R       w�                  P      P       U                 P      P       TP      �P       \WQ      kQ       \�R      �R       \                $P      (P       p (P      NP       ^�Q      �Q       V�Q      �Q       v�                1P      =P       p� =P      >P       V>P      mP       v�mP      �Q       VR      �R       V�R      �R       v�                >P      VP       v  $ &3$p"�VP      mP       v  $ &3$ "�pP      xP       v $ &3$ "��R      �R       Q�R      �R       v  $ &3$ "�                RP      �P       ^WQ      �Q       ^R      ]R       ^�R      �R       ^                �Q      �Q       U                �P      WQ       ���Q      R       ��]R      �R       ��                �P      WQ       ]�Q      �Q       ]]R      �R       ]                |P      �P       v 3$p "�P      �P       ]�P      �P       P�P      �P       ]WQ      �Q       ]R      2R       ]7R      ]R       ]�R      �R       ]                �Q      �Q       P�Q      R       ]                �P      WQ       \�Q      R       \R      �R       \                �Q      R       1�                �R      �R       w�R      �R       w�R      �R       w�R      �R       w �R      �R       w(�R      T       w0T      T       w(T      T       w T      T       wT      T       wT       T       w T      �T       w0                �R      S       U                �R      
S       T
S      �S       \T      8T       \oT      �T       \                S      S       p S      :S       ]                S      )S       p� )S      *S       V*S      TS       v�TS      T       VT      oT       VoT      �T       v��T      �T       V                *S      LS       v  $ &3$p"�oT      sT       Q                *S      :S       } v  $ &3$p8�                �S      �S       \=T      oT       \                �S      �S       |�=T      oT       ]                �S      T       0�                �T      �T       w�T      �T       w�T      �T       w�T      �T       w �T      �T       w(�T      �U       w0�U      �U       w(�U      �U       w �U      �U       w�U      �U       w�U      �U       w�U      jV       w0                �T      �T       U                �T      �T       T�T      WU       \�U      �U       \/V      jV       \                �T      �T       p �T      �T       ]                �T      �T       p� �T      �T       V�T      U       v�U      �U       V�U      /V       V/V      FV       v�FV      jV       V                �T      U       v  $ &3$p"�/V      3V       Q                �T      �T       } v  $ &3$p8�                oU      �U       \�U      /V       \                �U      �U       |��U      /V       ]                �U      �U       0�                pV      �V       w�V      aW       w� aW      hW       whW      �X       w�                 pV      �V       U�V      NW       SNW      bW       PbW      �X       S                pV      �V       T�V      XW       ]bW      �X       ]                �V      �V       0��V      �V       \�V      �V       p 
 � $0)��V      SW       \bW      �W       0��W      NX       \NX      ZX       p 
 � $0)�pX      �X       \                �X      �X       w�X      �X       w�X      �X       w�X      �X       w �X      �X       w(�X      �X       w0�X      �X       w8�X      [       w� [      [       w8[      [       w0[      [       w([      [       w [      [       w[      [       w[       [       w [      ^\       w�                 �X      �X       U                �X      �X       T�X      Y       \G\      ^\       \                �X      �X       p �X      �X       ]�Z      �Z       V�Z      �Z       v�                �X      �X       p� �X      �X       V�X      �X       v��X      �Z       V[      G\       VG\      ^\       v�                �X      �X       v  $ &3$p"��X      �X       QG\      K\       Q                �X      �X       } v  $ &3$p8�                �Z      �Z       P                7Y      [       ��<[      G\       ��                mY      [       ��<[      �[       ���[      G\       ��                �Y      �Z       ^<[      �[       ^�[      G\       ^                �Y      [       _<[      U[       _�[      G\       _                �Z      �Z       P�Z      [       ^                Z      [       \�[      G\       \                �Z      [       1�                `\      b\       wb\      d\       wd\      h\       wh\      i\       w i\      m\       w(m\      v]       w0v]      w]       w(w]      x]       w x]      z]       wz]      |]       w|]      �]       w�]      
^       w0                `\      v\       U                `\      z\       Tz\      ]       \}]      �]       \�]      
^       \                �\      �\       p �\      �\       ]                �\      �\       p� �\      �\       V�\      �\       v��\      x]       V}]      �]       V�]      �]       v��]      
^       V                �\      �\       v  $ &3$p"��]      �]       Q                �\      �\       } v  $ &3$p8�                ]      ]]       \�]      �]       \                6]      I]       |��]      �]       ]                Q]      }]       0�                ^      ^       w^      ^       w^      ^       w^      ^       w ^      ^       w(^      ^       w0^      !^       w8!^      �_       w� �_      �_       w8�_      �_       w0�_      �_       w(�_      �_       w �_      �_       w�_      �_       w�_      �_       w�_      �`       w�                 ^      *^       U                ^      .^       T.^      �^       \�_      �_       \|`      �`       \                4^      8^       p 8^      ^^       ]�_      �_       V�_      �_       v�                A^      M^       p� M^      N^       VN^      x^       v�x^      k_       V�_      |`       V|`      �`       v�                N^      p^       v  $ &3$p"�|`      �`       Q                N^      ^^       } v  $ &3$p8�                �^      u_       ^�_      |`       ^                �^      �_       _�_      F`       _                %_      �_       ���_      `       ��                u_      y_       Py_      �_       ^                X_      �_       \                �_      �_       1�                �`      �`       w�`      �`       w�`      �`       w�`      �`       w �`      �`       w(�`      �`       w0�`      �`       w8�`      ^b       w� ^b      _b       w8_b      `b       w0`b      bb       w(bb      db       w db      fb       wfb      hb       whb      pb       wpb      #c       w�                 �`      �`       U                �`      �`       T�`      2a       \ib      �b       \c      #c       \                �`      �`       p �`      �`       ]b      =b       V=b      Mb       v�                �`      �`       p� �`      �`       V�`      a       v�a      �a       Vib      c       Vc      #c       v�                �`       a       v  $ &3$p"�c      c       Q                �`      �`       } v  $ &3$p8�                Ja      b       ^�b      c       ^                }a      hb       _�b      �b       _                �a      ib       ���b      �b       ��                b      	b       P	b      fb       ^                �a      bb       \                Cb      ib       1�                0c      Pc       wPc      Md       w0Md      Pd       wPd      �d       w0                0c      Yc       U                0c      ]c       T]c      �c       VNd      [d       Vrd      �d       V                cc      gc       p gc      �c       \�c      d       \d      ?d       |�                qc      }c       p� }c      ~c       ]~c      �c       }��c      -d       ]Nd      �d       }�                ~c      �c       }  $ &3$p"��c      �c       }  $ &3$~ "�Nd      �d       }  $ &3$~ "�                ~c      �c       | }  $ &3$p8�                �c      �c       P�c      Id       ^                �c       d       V                d      Nd       1�                �d      �d       w�d      �d       w�d      �d       w�d      �d       w�d      �d       w                �d      �d       U�d      �d       S�d      �d       S                �d      �d       P                �d      �d       w�d      �d       w�d      �d       w�d      �d       w �d      �d       w(�d      zf       w0zf      {f       w({f      }f       w }f      f       wf      �f       w�f      �f       w�f      �f       w0                �d      �d       U                �d      �d       T�d      =e       \�f      �f       \                �d      �d       p �d      e       ]                �d      e       p� e      e       Ve      2e       v�2e      lf       V�f      �f       V�f      �f       v�                e      *e       v  $ &3$p"��f      �f       Q                e      e       } v  $ &3$p8�                �e      �e       P                �e      �e       p��e      7f       ]                bf      �f       1�                �f      �f       w�f      �f       w�f      �f       w�f      �f       w �f      �f       w(�f      �f       w0�f      g       w8g      Xi       w� Xi      Yi       w8Yi      Zi       w0Zi      \i       w(\i      ^i       w ^i      `i       w`i      bi       wbi      hi       whi      mj       w�                 �f      
g       U                �f      g       Tg      jg       \Vj      mj       \                g      g       p g      >g       ]                !g      -g       p� -g      .g       V.g      Zg       v�Zg      Gi       Vci      Vj       VVj      mj       v�                .g      Pg       v  $ &3$p"�Vj      Zj       Q                .g      >g       } v  $ &3$p8�                �g      �h       ]�i      )j       ]                jg      ng      	 v 3$p "#ng      
�       P
�      .�       ^T�      �       ^-�      �       ^�      ,�       P,�      b�       ^b�      n�       Pn�      �       ^��      ��       ^                ��      ��       P��      A�       VT�      ��       Vߏ      5�       V5�      9�       U9�      :�       ��H�:�      ?�       0�?�      ��       VȐ      ��       V                }�      ��       P��      ҍ       ]-�      T�       ]?�      b�       ]                ~�      ��       P��      ߏ       \��      Ȑ       \                 �      "�       w"�      $�       w$�      &�       w&�      *�       w *�      +�       w(+�      ے       w0ے      ܒ       w(ܒ      ޒ       w ޒ      ��       w��      �       w�      �       w�      w�       w0                 �      4�       U                 �      8�       T8�      ��       \`�      w�       \                >�      B�       p B�      h�       ]                K�      W�       p� W�      X�       VX�      ��       v���      ͒       V�      `�       V`�      w�       v�                X�      z�       v  $ &3$p"�`�      d�       Q                X�      h�       } v  $ &3$p8�                �      �       P�      .�       ] �      �       p �      3�       ]                #�      )�       P)�      ��       \�      -�       P-�      3�       \                Ò      �       1�                ��      ��       w��      ��       w��      ��       w��      ��       w ��      ��       w(��      ;�       w0;�      <�       w(<�      >�       w >�      @�       w@�      B�       wB�      H�       wH�      ו       w0                ��      ��       U                ��      ��       T��      �       \��      ו       \                ��      ��       p ��      ȓ       ]                ��      ��       p� ��      ��       V��      �       v��      -�       VC�      ��       V��      ו       v�                ��      ړ       v  $ &3$p"���      ĕ       Q                ��      ȓ       } v  $ &3$p8�                u�      }�       P}�      ��       ]`�      h�       p h�      ��       ]                ��      ��       P��      ��       \n�      ��       P��      ��       \                #�      C�       1�                ��      �       w�      �       w�      �       w�      �       w �      �       w(�      ��       w0��      ��       w(��      ��       w ��      ��       w��      ��       w��      ��       w��      7�       w0                ��      ��       U                ��      ��       T��      l�       \ �      7�       \                ��      �       p �      (�       ]                �      �       p� �      �       V�      B�       v�B�      ��       V��       �       V �      7�       v�                �      :�       v  $ &3$p"� �      $�       Q                �      (�       } v  $ &3$p8�                Ֆ      ݖ       Pݖ      �       ]��      ȗ       p ȗ      �       ]                �      �       P�      X�       \Η      �       P�      �       \                ��      ��       1�                @�      B�       wB�      D�       wD�      F�       wF�      K�       w K�      L�       w(L�      M�       w0M�      Q�       w8Q�      ��       w� ��      ��       w8��      ��       w0��      ��       w(��      ��       w ��      ��       w��      ��       w��      ��       w��      �       w�                 @�      Z�       U                @�      ^�       T^�      ۘ       ]��      ̚       ]�      �       ]                d�      h�       p h�      ]�       \]�      ��       |���      ��       V��      ��       p ��      ,�       \,�      қ       Vқ      ڛ       v�ڛ      ߛ       Vߛ      �       \�      "�       P"�      z�       \z�      ��       V��      ��       P��      ��       V��      �       \                q�      }�       p� }�      ~�       V~�      ��       v���      z�       V��      ,�       V�      �       v�                ~�      ��       v  $ &3$p"���      ��       v  $ &3$~ "���      ��       Q��      '�       v $ &3$~ "���      ̚       v $ &3$~ "���      '�       v $ &3$~ "��      �       Q�      �       v  $ &3$~ "�                ~�      ��       | v  $ &3$p8���      ��       | v  $ &3$~ 8��      �       | v  $ &3$~ 8�                ��      ��       } #(��      �       ��                ��      ��       ��̚      �       ��                '�       �       ^̚      ��       ^ߛ      ��       ^"�      z�       ^��      �       ^                _�      ��       ��,�      �       ��                o�      s�      	 v 3$p "#s�      �       _ߛ      ��       _"�      z�       _��      ̜       _ݜ      �       _                o�      ��       0���      ��       P��      �       ]�      �       0�ߛ      �       0��      ��       ]"�      /�       P/�      \�       ]\�      n�       Pu�      z�       w ��      ݜ       0�ݜ      �       ]                z�      ��       P��      �       Vߛ      �       P�      ��       0�"�      0�       V0�      2�       0�2�      o�       Vo�      z�       0���      �       V                ;�      ?�       P?�      ��       ^,�      T�       ^��      "�       ^                ~�      ��       P��      ߛ       \z�      ��       \                 �      E�       wE�      b�       w� b�      h�       wh�      Y�       w�                  �      N�       U                 �      R�       TR�      ��       \@�      Y�       \                X�      \�       p \�      ��       V��      "�       \2�      J�       VJ�      c�       p c�      �       \�      B�       |�G�      Q�       VQ�      ^�       \^�      ��       |���      ͢       \͢      Ң       PҢ      @�       \@�      Y�       V                f�      r�       p� r�      s�       ^s�             ~�      ҝ       ^c�      ��       ~�@�      Y�       ~�                s�      }�       ~  $ &3$p"�}�             ~  $ &3$ "�      ҝ       ~ $ &3$ "�c�      ��       ~  $ &3$ "�@�      F�       QF�      Y�       ~  $ &3$ "�                s�      }�       v ~  $ &3$p8�}�             v ~  $ &3$ 8�      ŝ       v ~ $ &3$ 8�c�      ��       v ~  $ &3$ 8�@�      Y�       v ~  $ &3$ 8�                ��      T�       ]��      @�       ]                �      c�       ����      ��       ����      @�       ��                -�      ��      
 -�     �                ҝ      �       ^2�      6�       P��      �       ^Q�      ��       ^��      �       ^'�      ��       ^��      �       ^��      z�       ^��      ��       ^��      ��       ^Ң      �       ^ �      �       ^(�      v�       ^��      ��       ^ϣ      �       ^��      �       ^.�      w�       ^��      �       ^��      .�       ^                �      ^�       _��      ��       _ɞ      @�       _                ��      c�      
 �       ��      ��      
 �       ɞ      @�      
 �                       ��      c�      
 �       ��      ��      
 �       ɞ      @�      
 �                       ��      �       ����      ��       ��ɞ      ܞ       ��Q�      ��       ����      �       ��'�      6�       ��Z�      f�       ����      ��       ����      �       ��O�      q�       ����      ��       ����      �       ����      �       ��Ң      �       �� �      �       ��(�      Y�       ��                ��      ^�       _��      ��       _ɞ      @�       _                7�      Z�      
 �       �      ��      
 �       a�      ͤ      
 �                       7�      Z�      
 �       �      ��      
 �       a�      ͤ      
 �                       7�      Z�       _�      ��       _a�      ͤ       _                g�      ��      
 �       Y�      ��      
 �       �      @�      
 �                       g�      ��       _Y�      ��       _�      @�       _                ��      �      
 �       ��      ϣ      
 �       ��      �      
 �                       ��      �       _��      ϣ       _��      �       _                �      O�      
 �       ��      ��      
 �       ͤ      ��      
 �                       �      O�       _��      ��       _ͤ      ��       _                ��      ��      
 �       ϣ      a�      
 �                       ��      ��       _ϣ      a�       _                `�      a�       wa�      e�       we�      k�       wk�      ��       w ��      ��       w��      ��       w��      ��       w                `�      k�       Uk�      ��       V                `�      k�       0�                ��      ��       w��      ��       w��      ��       w��      Ȩ       w Ȩ      ɨ       wɨ      ˨       w˨      ب       wب      �       w �      �       w�      ��       w��       �       w                ��      ��       U��      ��       Q��      Ȩ       Sը      �       S                ��      ��       T��      ��       Vը      �       V                ť      ۥ      
 	�     �                �      �      
 +�     �                �      �      
 F�     �                �      �      
 a�     �                3�      �      
 |�     �                W�      j�      
 ��     �                j�      ը      
 Ʃ     �                ��      ��      
 �     �                ��      ը      
 �     �                ̦      �      
 �     �                 �      ը      
 ��     �                �      ը      
 �     �                ,�      ը      
 2�     �                C�      ը      
 L�     �                Z�      ը      
 f�     �                q�      ը      
 ��     �                ��      ը      
 ��     �                ��      ը      
 ��     �                ��      ը      
 Ѫ     �                ٧      ը      
 �     �                �      ը      
 �     �                �      ը      
  �     �                2�      ը      
 ;�     �                O�      ը      
 T�     �                l�      ը      
 m�     �                ��      ը      
 ��     �                ��      ը      
 ��     �                ��      ը      
 ��     �                 �      �       w�      �       w�      �       w�      	�       w 	�      
 ����      c�       
 ��                ƶ      ��       U                ϶      ��       Q                ��      ��       Q��      ��       R                ��      ��       U:�      A�       Q                ��      ��       U��      ��       P�      *�       R*�      :�       P                f�      ��       1�                ��      ��       w��      ��       w��      ��       w��      ��       w ��      ��       w(��      ��       w0��      ��       w(��      ��       w ��      ��       w��      ��       w��      ��       w��      ��       w0                ��      ��       U                ��      Ÿ       T                ˸      ϸ       p ϸ      �       V                ٸ      �       \�      ��       ]��      ��       ]                �      ��       |  $ &3$p"�                ��      ��       P�      �       P                ��      κ       P                �      ��       P                L�      P�       PP�      ��       V                ��      ��       1�                                U                        &        T                                Q       
���
���                       m        Xm       �       
 x z "#����       �        Q                m       �        y 
����       �        P                       
���
���                �              U      d       Rd      �       U�      O       RO      �       Q�      �       R                �       -       T-      4       P4      :       T=      E       PE      Z       TZ      c       tp�c      �       T�      ?       T?      �       P�      �       pp��      �       P�             T             t�      !       T                �              Q      -       q��      �       Y�             Q      ?       Y�      �       y ?1��             Y                      d       Xd      �       x 
����             X             U      �       X                �      �       U�      �       U                �      �       T�      �       T                �      �       Q�      �       Q                �      �       U�      �       U                �      �       T�      �       T                �      �       Q�      �       Q                                0�                               t x "       '        P'       .        p 1%�.       C        P                               T       0        Q                               0�'       0        R                P       R        wR       V        wV       Z        wZ       d        w d       C       w�C      G       w G      H       wH      J       wJ      K       w                P       m        Um       �        S�              S4      G       SG      K       P                P       �        T�       H       V                P               Q       �        \�       �        | 1&��       4       \4      7       | 1&�7      J       \                �       �        1�                �       �        1��       �        Q                �       �        S�       �        s 1%��       �        S                �       �        W�       �        P                �       �        0��       �        Q                      (       S(      /       s 1%�/      4       S                             ��}�      4       P                             0�(      4       Q                `      f       wf      v       wv      w       w                `      u       Uu      �       X�      �       X�      �       X�      �       X�      �       X�      �       X�             X             X#      ^       Xe      u       X                `      �       T�      �       P�      �       p��      �       p��      �       p��      �       p��      �       p��             p�             p�#      4       PK      T       PT      a       Tk      m       P                `      �       Q                �      �       U                �      �       T                �      �       Q                �      �       U                �      �       T                �      �       Q                                w       	        w	               w       �        w �       �        w�       �        w�       �        w�       �        w                                 U       �        S�       �        S                        b        Tb       �        V�       �        T�       �        V                        ]        Q]       �        \�       �        Q�       �        \                        c        R�       �        R                        c        X�       �        X                d       �        P�       �        P                �       �        w�       �        w�       �        w�       �        w �       �        w(�       �        w0�       �        w8�       �       w��      �       w8�      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      �       w�                �       g       U{
      �
       U                �       g       Tg      �       ��~                �       C       QC      �       ��~                �       ;       R;      �       ��~                �       g       Xg      �       ��~                �       g       u8g      y       ]y      �      	 ��
P��      �       ]�              S       {
      	 ��
P��
      �       ]                +      {
       ���
      �       ��                V      g       u8#@g      y       ��~�      �       ��~�      �       ~�      ?       ��~?      �       \�      �       \�      �       ��
�      �       \�      ,	       ��~,	      1	       Q1	      	       ��~	      �	       \�	      {
       ��~�
      �
       ��~�
      �
       }� �
      �
       ��~�
      �       ��~�      ,       SQ      U       SU      j       }� j      �       S�             ��~             S      �       ��~                0      �       S�      =       S=      �       P�      �       P�      �       S�             P      )       P)      K       SK      �       P�      �       P�      �       S�             P             P      _       S_      g       Pg      �       S�      O       PO      
       S;
      P
       PP
      {
       S�
      �
       S�
             P      2       P2      �       S�      �       P�             P      o       So      �       P�      �       P�      f
�      �       _	      	       _	      ,	       �,	      Z	       _Z	      	       S	      �	       _�	      ;
       _�
      �
       }4�
      �
       _?
�      (       \(      �       0��      �       0��      	       \	      �	       0��	      {
       \�
      �       \�      �       \�      �       \�      �       \                0      g       0�g      y       V�      ^       V^      u       vx�u      �       V�      �       R�             R.      5       V5      8       R;      P       VP      W       R}      �       R�      �       V�      �       R�             R      %       V%      (       R0      _       V_      g       Rg      w       Vw      {       v{�{      �       vv��      �       V�      �       R      Q       RQ      
 �      �       R�      �       V�      	       v�	      �       V�      �       vx��      $       V(      �       0��      �       0��      =	       V=	      Z	       v�Z	      m	       R	      �	       0��	      �	       V�	      ;
       v�;
      U
       V\
      `
       Vc
      {
       V�
      �
       V�
      �
       V�
      �
       R             R,      2       R2      9       VH      �       V�      �       vx��      �       V�      �       vx��      
 q �q��%      )       q �q�q�)      3      	 P�T�Y�3      G       �T�Y��      �      
 q �q���      �       q �q�q��      �      	 R�T�Y��      �       �T�Y��      �       �Y�            	 R�T�Y�      O      	 P�T�Y�O      g      	 U�T�Y�g      j      	 U�X�Y�j      o       r �r�Y�o      w       r �r�r�w      �      	 P�T�Z��      �       �T�Z��      �      
 q �q���      �       q �q�q��      �      	 R�T�Z��      �       �T�Z��             �Z��      	      
 0��T�Y��	      �	      	 P�T�Y��	      �	       P��;
      P
      	 R�T�Z�P
      \
      	 P�T�Z�\
      {
       P��Z��
      �
       P��k      o      
 q �q��o      r       q �q�q�r      |      	 T�P�U�|      �      	 T�Q�U��      �      
 q �q���      �       q �q�q��      �      	 T�R�U��      �       T��U��      �       �U��            	 T�R�U�            	 T�P�U�      -      	 [�P�U�-      E       �P�U�E      H       �X�U�H      L       r �r�U�L      T       r �r�r�T      ^      	 T�P�U�^      w      	 T�X�U��      �      
 r �r���      �       r �r�r��      �      	 T�Q�U��      �       T��U��      �       �U��      �      	 T�Q�U��      )
 q �q���
 q �q���
 ����Q��      �      	 ������      �      	 T�P�U��      �       T��U��      �      	 ������      �       �S�Q��             �S��             �S�Q�      �       �S��                �      �       0��      �       Z�      �       Z�      �       0�                o      y       	��y      �       P�      �       1��      �       P5      U       1��      �       P6	      =	       1�?
      	 ��
P�                �      �       w�             w              w       &       w&      '       w                �      �       U�             S      &       S&      '       U                                w       �        w0�       �        w�       �       w0                        -        U-       �        V�       �       V                        -        T-       8        \�       �        \G      X       TX      �       \                       -        u8-       �        S�       �       S                8       f        \f       i        | } �i       �        \�       G       \                P       W        QW       �        ]�       G       ]                �      #       u8                0      W       UX      f       U                >      W       u8                p      �       w�             w0             w      E       w0E      F       w                p      �       U�      �       \�             U      F       U                p      �       T�      �       S�      �       v0      2       S                �             ]             0�      $       ]                �      �       u8�      �       |8�      �       V      $       V                P      f       wf             w0             w      '       w0                P      q       Uq      �       S      '       S                P      �       T�      �       V             T      '       V                P      �       Q             Q                P      �       R             R                �      �       P                �      �       P�      �       \      %       P%      '       \                0      >       U                0      :       T:      >       Q                0      5       Q5      >       R                @      I       U�      �       U                @      j       Qj      �      
 1t $1q ��      �       Q                N      �       U�      �       U                �      �       w�      �       w�      �       w�      �       w �      �       w(�      �       w0�      �       w8�      n       w�n      o       w8o      p       w0p      r       w(r      t       w t      v       wv      x       wx      �       w�      #       w�                �      >       U>      x       _y      #       _                �             T      #       ��~                �      >       u8>      C       ]y      6       ]X      �!       ]�!      #       ]                      C       Vy      �       V�      �       v��      �       V�      �       v��      �       V      e       Ve      n       v�n      u       Vu      ~       v�~      Z	       VZ	      b	       v�b	      e
       Ve
      n
       v�n
      B       VB      J       v�J      �       V�      �       v��      e       Ve      n       v�n      �
       SP
      k
       Rk
      n
       rx�n
      �
       R�
      :       S:      J       sx�J      �       S�      �       S�      �       S�      �       R�      �       R      %       0�4      F       SF      k       Rk      n       rx�n      u       Ru      
 q �q��C      H       T�P��H      K      	 T�P�Q�K      \       T�P����\      i      	 T�P�S�i      m       T�P��m      �       T���      �      
 q �q���      �       q �q�q��      �      	 T�P�S��      �       T�P�����      �       R�P�����      �      
 �P�����      �       ��������      �      
 r �r��}	      �	       r �r�r��	      �	      	 T�P�[��	      �	       T�P�����	      �	      
 T�����3
      8
      
 q �q��8
      ;
       q �q�q�;
      N
      	 U�P�Y�N
      P
      	 U�Q�Y�P
      Y
      	 U�S�Y�Y
      ~
       U��Y�~
      �
       q �q�Y��
      �
       q �q�q��
      �
      	 U�S�Y��
      �
      	 U�P�Y��
      �
       ���P�Y��
      �
      
      �
       r �r�Y��
      �
       r �r�r��
      5      	 U�P�Y�5      `       U��Y�`      e       r �r�Y�e      h       r �r�r�h      �      	 U�P�Y��      �       p ���      �      
 p �p���      �       p �p�p��      �       �R�Q��      �       �P�Q��      �       �S�Q��      �       �Q��      �      	 p ��Q��      �       p �p�Q��             p �p�p�      
       �S�Q�
             �T�Q�      ?       �R�Q�?      A       �U�Q�A      �       �U���      �      
 T������      �      	 U�P�Y��      �       U��Y��             �R�Q��      �       T�P����c      o      	 U�P�Y�o      �       �P�Y��      �      	 U�P�Y��      �      
 T������      �       �R�Q��      �       �U�Q��      6       �U��6      J       �U�Q�J      �       �U���      �      
 T������      �      	 T�P�[��      �       T�P��e"      }"       �U��#      #       �U��                v      �       0��      �       R�      �       Y%      Z       Yg      �       P#      L       Y�             Y.      6       R~      �       0�W!      �!       R="      }"       R                2      >       0�>      C       Xy      �       X4      �       X�      �       P�      +	       X+	      �	       ���	             X      �       ��>      Z       PZ      k       X�      �       X�      ?       X�      !       X�      4       Xj      �       X�             Xm      �       X�      �       XU      c       X�      �       ���      �       X�      �       ���       �        P�       �        X�!      �!       X"      ,"       P,"      ="       Xe"      }"       X�"      �"       P�"      �"       X�"      �"       P�"      #       X                �      %       ]}"      �"       ]                 #      $#       w$#      f#       wf#      p#       wp#      v#       wv#      w#       w                 #      )#       U)#      f#       Sg#      v#       Sv#      w#       U                ;#      I#       s8                �#      �#       w�#      +$       w� +$      0$       w0$      �$       w�                 �#      �#       U�#      $       S,$      �$       S                �#      �#       T�#      �#       ],$      ?$       T?$      h$       ]~$      �$       T                �#      �#       Q�#      $       \,$      =$       Q=$      �$       \                �#      �#       s8�#      	$       V,$      ~$       V                F$      S$       PW$      `$       P`$      h$       Q                �#      �#       s�#      	$       ^h$      ~$       ^                �#      �#       s �#      	$       _h$      ~$       _                �#      	$       Ph$      |$       P                �$      �$       u8                �$      �$       w�$      �$       w�$      �$       w�$      �$       w �$      �$       w(�$      �&       w� �&      �&       w(�&      �&       w �&      �&       w�&      �&       w�&      �&       w�&      I'       w�                 �$      �$       U�$      �&       S�&      I'       S                1%      Z%       0�'      &'       0�                }&      �&       \                �&      �&       s(�&      �&       ]                %      �&       s8�&      �&       V�&      :'       V                �%      �%       U�&      �&       U'      &'       0�                �%      �%       W�&      �&       W'      &'       W                �%      �%       s8#���&      �&       v��'      &'       v��                �%      �%       0��%      �%       Q�%      �%       P�%      �%       P�&      �&       P'      &'       0�                �%      �%       0��%      �%       R�%      �%       R'      &'       0�                �%      �&       U�&      �&       U&'      :'       U                �%      �&       s �&      �&       X&'      :'       X                �%      �&       s8#���&      �&       v���&      �&       v��&'      :'       v��                �%      &       P&      &       R&      i&       Pi&      �&       s8#��&      �&       P&'      :'       P                �%      &       0� &      (&       QN&      [&       Q&'      :'       0�                ^'      {'       u8                �'      �'       w�'      �(       w0�(      �(       w�(      2)       w0                �'      �'       U�'      �(       ]�(      2)       ]                �'      �'       T�'      �(       V�(      2)       V                �'      �'       t8�'      �'       v8�'      �(       S�(      )       S)      2)       S                 (      &(       P&(      �(       \�(      )       \)      )       P)      2)       \                (      -(       0�-(      3(       P3(      �(       ^�(      )       ^)      )       0�)      ')       P')      2)       ^                �(      �(       1s0�$�                S)      _)       u8                ~)      �)       u8                                w       	        w	               w       `        w�`       c        wc       d        wd       h        wh       �        w�                        ?        U?       U        ��                                T       c        Se       �        S                        '        Q'       U        w                         U        R                Z       \        Pe       t        Pt       z        Vz       �        P�       �        V�       �        P�       �        V�       �        P�       �        V                                w               w               w       e        w�e       h        wh       i        wi       p        wp       �        w��       �        w�       �        w�       �        w�       �        w�                        ;        U;       Z        ��                        )        T)       h        Sj       �        S�       �        S                                 Q        Z        w                         5        R                        Z        X                _       a        Pj       |        P|       �        V�       �        P�       �        V�       �        P�       �        V�       �        P                �       �        U                �       �        T                �       �        Q                �       �        R                �       �        U�       �        P                                w               w       *        w*       2        w 2       3        w(3       4        w04              w8             w0             w(      
�             ��                       "       w"      $       w$      &       w&      (       w (      )       w()      *       w0*      1       w81      �       w� �      �       w8�      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      6       w� 6      7       w87      8       w08      :       w(:      <       w <      >       w>      @       w@      H       wH      �       w�                        V       UV      �       S�      7       SA      �       S                �      �       R�      '       s� K      ^       V                9      �       T                      N       QR      �       Q                q      �       P�      �       P�      �       P�      �       P                4      V       u� V      �       V�      �       ]�      �       V�      <       ]A      �       V                �      �       P�      �       P�      �       P                �      �       q  $ %x  $ %"s� "��      �       q  $ %x  $ %"u "��      �       q  $ %x  $ %"u "�                �      �       _�      �       _A      �       _                �      �       R�      �       P�      �       P                      �       Q�      �       Q                �      �       V�             V      *       q�}�                �      �       P�      �       \      8       V                �      �       w�      �       w �      �       w�      *       w                 �      �       U�      �       S�      *       S                �      �       v(�      �       \�      *       \                �      �       u8�      �       s8�      �       V�      *       V                0      1       w1      4       w4      ;       w;      <	       w <	      =	       w=	      >	       w>	      @	       w@	             w              w      
      (
       x  $y  $)�V      e       s�-� $s�-�1 $)�                      D       Ue	      �	       U
      $
       U                      X       P                      &       q�&      z       Qe	      l	       Q                �      	       Q                %      e       P                �      �       w�      �       w�      �       w�      �
���      �       V�      �       V                3      f       R                �      �       w�      �       w�      �       w�      �       w �      �       w(�             w0             w8      m       w� m      n       w8n      o       w0o      q       w(q      s       w s      u       wu      w       ww      x       wx             w�                 �      ]       U]      o       Vx             V                �      ]       T]      s       ]x      �       ]�      �       T�             ]                �      ]       Q]      u       ^x      �       ^�      �       P�      �       Q�             ^                &      ]       u8]      i       Sx      �       S                �      �       s��             Q                �      �       U�      �       u��             U                *      ]       u8#,]      i       \x      �       \                x      �       v�      i       _                �      i       ��                             w             w             w      �       w �      �       w�      �       w�      �       w�      �       w                       "       U"      �       S�      �       S                d      �       s8�      �       V�      �       V                �      �       w�      �       w�      �       w �      �       w�      �       w                �      �       U�      �       S                �      &       P                �      �       S                0      2       w2      7       w7      <       w<      =       w =      >       w(>      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      �       w0                0      m       U�      �       U                0      F       TF      �       S�      �       s v ��      �       S�      �       S                0      T       QT      �       ]�      �       Q                O      m       u8m      �       \                �      �       V                �      �       u8                      B       U'      5       U                      �       T�      �       P�      �       R�      5       xy�                ?      B       u8B      �       R
      '       R                )      g       p�h      �       p�
      4       p�4      5       pz�                \      h       Qh      �       B��      
       Q                �      �       r0#(�      �       r0#8                @      B       wB      D       wD      F       wF      H       w H      L       w(L      P       w0P      T       w8T             w�       �       w8�      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      �       w� �      �       w8�      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      �       w� �      �       w8�      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      *)       w�                 @      �       U�      �       V�      �       V�      �       V�      *)       V                @      �       T�      {       \�      �       \�             \�      F%       \&      &       T&      *)       \                �      �       u8#@�      a       ^�      �       ^�      '       ^�             ^�      n       ^f      �       ^=!      �!       ^N"      �"       ^&#      $       ^�$      �$       ^�$      F%       ^&      �'       ^
(      b(       ^o(      *)       ^                {      �       u8�      {       S�      �       S�      �       S�      �$       S�$      *)       S                X      a       P                �      �       r  $t  $)��      �       r  $t  $)�                N      �       P                             P�       �        P                �      �       t �8$8%��      �        U�'      
(       U                �      �       t��      �       t��      �       t��      �       T�      �       Z�      �       t��      �       t��      �       t��      	        t�	               t�                t�        7        T7       <        t�<       ?        Z?       E        T                �      B        Y                �      �       Q                n       �        Q                n       �        1��       �        0�                K      n       Q                n      �       Q                �      %       R6      W       Qf      �       R                6      W       Q                j      �       R                �      �       Q                �      ?       YU      d       s(=!      R!       Y&#      B#       Y�$      �$       Q�'      �'       Y                �!      �!       T�!      �!       TN"      h"       T�$      �$       T�'      �'       T
(      (       Q                �!      �!      	 p 8$8%�N"      S"      	 p 8$8%�S"      }"       _�#      $       _�'      �'       _                �"      �"       T�"      �"       TL#      h#       T�$      �$       T�'      �'       T(      &(       Q                �"      �"      	 p 8$8%�L#      S#      	 p 8$8%�S#      }#       _�#      �#       _�'      �'       _                0)      2)       w2)      3)       w3)      4)       w4)      :)       w :)      �)       w0�)      �)       w �)      �)       w�)      �)       w�)       *       w *      W*       w0                0)      �)       U�)      :*       UJ*      W*       U                0)      C)       TC)      b)       Sb)      �)       T�)      *       S*      
*       TJ*      W*       T                0)      �)       Q�)      :*       QJ*      W*       Q                P)      �)       u8�)      �)       V�)      J*       V                �)      �)       | p "#�)      �)       T
*      2*       T                0)      �)       0��)      �)       P�)      ;*       0�;*      J*       PJ*      W*       0�                `*      a*       wa*      b*       wb*      i*       wi*      �*       w �*      �*       w�*      �*       w�*       +       w +      G+       w                 `*      r*       Ur*      �*       S�*      G+       S                �*      �*       s8#�*      �*       V�*      <+       V                P+      R+       wR+      W+       wW+      Y+       wY+      ^+       w ^+      b+       w(b+      e+       w0e+      l+       w8l+      �-       w� �-      �-       w8�-      �-       w0�-      �-       w(�-      �-       w �-      �-       w�-      �-       w�-      �-       w�-      �-       w� �-      �-       w8�-      �-       w0�-      �-       w(�-      �-       w �-      �-       w�-      �-       w�-      �-       w�-      '.       w�                 P+      ~+       U~+      �-       S�-      �-       U�-      �-       S�-      '.       S                P+      �+       T�+      �-       V�-      �-       ~��-      �-       V�-      �-       T�-      '.       V                P+      ,       Q�-      �-       Q�-      �-       Q                P+      u+       Ru+      �-       \�-      �-       \�-      '.       \                P+      P,       XP,      �-       ]�-      �-       X�-      �-       ]�-      �-       X�-      '.       ]                P+      P,       YP,      �-       _�-      �-       Y�-      �-       _�-      �-       Y�-      '.       _                W,      �,       P�,      �-       ^�-      '.       ^                P+      �+       1��+      P,       R�-      �-       2��-      �-       0��-      �-       1�                &-      �-       P�-      �-       ~�-      �-       P�-      .       ~                0.      4.       w4.      X.       w X.      Y.       w                0.      S.       U                0.      S.       T                0.      O.       QO.      S.       w                 0.      J.       RJ.      S.       �h                `.      b.       wb.      d.       wd.      e.       we.      i.       w i.      m.       w(m.      �/       w0�/      �/       w(�/      �/       w �/      �/       w�/      �/       w�/       0       w 0      '0       w0                `.      �.       U�.      �/       V�/      0       U0      '0       V                `.      �.       T�/      0       T                �.      �.       P�.      �/       S0      '0       S                �.      �.       t8�.      �/       \0      '0       \                /      V/       PV/      �/       ]0      0       P0      0       ]                                w               w               w                w         %        w(%       )        w0)       �       w8�      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      �       w8                        V        T                $       �        ]�       �        }��       u       ]u      �       }��      �       ]�      �       u 1��      �       ]�              }�       O       ]O      l       }�l      �       ]�             �@      �       ]�      �       }��      �       ]�      �       ]                :       =        P=       �       ��~                :       �       Y�      �       y��      �       Y             Y      &       S&      ?       y�?      \       S\      o       y�o      {       y�{      �       s��      �       y��      �       y��      �       Y�      �       y��      �       y��             Yu      }       S}      �       Y�      �       y��      �       Y�      �       y��      �       Y                       �        Q�       �       ��                �       �        u8#H�       �        P�       �        }�8$8%q $p "��       �        s 8$8%q $p "��       E       PE      �       T�      �       P�              }�8$8%q $p "�              s 8$8%q $p "�      �       P                �       �        u8#P�       �        Q�       �        q��       �        qx��       �       Q�      �       qx��      �       Q�      3       Q6      �       Q�      	       q�	             qx�      _       Q_      n       Rn      v       Q�      �       Q�      �       R�      �       Q                �       	      
 x �x��	             x �x�x�      <       �\�@      E       x ��E      J      
 x �x��J      ^       x �x�x�^      �       �\��      �      
 x �x���      �       x �x�x��      �       �S��      �       x ���      �      
 x �x���             x �x�x�      '       �S��      �       �\��      �       �\�      7       �\�7      T       �S�T      �       �V��      �       �V�                	      3       RM      V       SV      j       Rj      |       r ?�|      �       X�      �       R�             V             R�      �       R�      �       R�      �       X7      J       RJ      �       X�      �       X�      �       R�      �       X�             X             XF      P       u8#<}      �       X�      �       X                j      '       \,      1       R1      ;       T�             \7      /       \/      ?       |�?      �       \�      �       |��      �       \                F             V�      u       V}      �       V�      �       V                �      �       R             R      &       V&      ?       r�?      \       V�      �       r��      �       r��      �       r��      �       R�      �       r��      �       r�             Rp      u       Ru      }       V�      �       R�      �       r�                                w               w       	        w	               w                w(       
 Y�[�~��      �       ~ �[�~��      ]       ~ �~�~��      �      	 Y�[�X��      �       �[���      �      
 Y�[�~��      �       @��[�0���             �[��      1       ~ �~�~�                /      �       ��~�      �       Z�      $       ��~� $ %2$z "��      �       Z�      �       ��~�             Z      1       ��~� $ %2$z "�                '      ]       ��~�      1       ��~                '      ]       ��~�      1       ��~                '      ]       ��~�      1       ��~                                w               w               w               w                w(               w0       �        w8�       �        w0�       �        w(�       �        w �       �        w�       �        w�       �        w�       �        w8                        '        U0       �        U                                Q       !        YX       `        P                !       0       
 y 2$u "#�0       �        _�       �       
 y 2$u "#��       �        _                !       D        QD       X        PX       �        Q�       �        P�       �        Q                              w             w             w             w       	       w(	      
       w0
             w8      �       w� �      �       w8�      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w�      �       w�                        @       U@      �       S�      �       S                       #       T#      �       w �      �       ���      �       w                       #       t #             w       �       V�      �       V                #             w #E      X       T�      �       T                #             w ##      B       ]E      X       ]�      �       ]                7      R       0�      .       ^.      2       ~�2      B       ^U      Q       _�      �       0�                �      �       T                #      R       	��j      �       P�      �       \�      �       \�      E       w E      X       \�      �       	��                �      �       P�      �      
 r 2$s "#�B      �       ]                <      E       w X      �       w �      �       ��                <      E       SX      �       S                ?      E       w X      \       Q\      �       w �      �       ��                B      E       w #X      Z       PZ      �       w #�      �       ��#                I      E       w #X      �       w #�      �       ��#                M      E       w ##X      �       w ##�      �      	 ��##                Q      E       w ##X      �       w ##�      �      	 ��##                U      E       w ##X      �       w ##�      �      	 ��##                �      U       T�      E       R                �      �      
 r 2$s "#��      �       U�      C       U                �      .       r  $ &2$s "#�                U      W       0��      �       R�      �       w ##�      �       RU      i       Zi      �       T�      �       t��      �       w ##�      .       [.      6       {�6      E       [                �      �       0��             Z                �      '       x                 U      �       0��      �       ]                X      \       0�j      �       Q                X      \       1�                y      �       0�                �      �       Q                �      �       R�      �       P�      �       R                �      �       Q�      �       q�                �      �       0��      �       T�      �       P�      �       T�      �       p 1$�                �      �       w�      �       w�      �       w�      �       w                             0�                �             	��,      J       RJ      V       S�      �       R�      �       R                      �       R�      �       R                �             R      V       YV      _       R_      �       Y�      �       Y                �             0�      ,       P,      J       0�J      V       P_      y       P�      �       0��      �       P�      �       P�      �       0��      �       P                �             7�      #       ZJ      �       Z�      �       Z�      �       Z                �             4�      B       [J      �       [�      �       [                �      �       w�      �       w�      �       w�      �       w �      �       w(�      �       w0�      
       w8
      
       w0
      	
       w(	
      
       w 
      
       w
      
       w
      
       w
      Q
       S      6       S                /      =       SB      
       S
      Q
       \
      Q
       X
      �
       P             P      6       0�\      �       X�      ,       P�      �       P�      �       p�
       R             R�      �       R�      �       R                �             4�      U       Y.      \       Y�	      !
       Y             Y�      �       Y�      �       Y                �      %       Y
	      V	       ]                l	      �	       2�6      \       2�                }	      �	       x}�                !
      �
       Y�      
      �
       [                �
             3��      
      �
       x~��
      �
       p}�                             7�
 s��
 �                �      �       5�j      �       5�                �      M       s�                M      �       4�j      �       4�                V      Y       p}�Y      �       x|�                �      �       3�                �             U                �      �       0�                +      y       S�             S                �      �       3�      j       3�                      j       v�                K      ]       Q                �      9       Tb      k       Ts      �       T                �      (       Qs      �       Q                @       M        U                @       M        T                @       G        Q                p       �        Q                p       �        0�                �       �        U�       �        P�       �        U�       �        P�       �        U                �       �        T                V       }       �       O      Q      U      x      �                      �       	      �      �                      O      Q      U      l                      v      �      �      o      q      u      �                            �      )      �      �                      o      q      u      �                      �      �      �      �      �      �      �      B                            I      �                            �      �      �      �                      �      �      �      �      �      �      �      r                      2      i            E                      �      �      �      �                      �      
      �
                      b	      �	      8
      e
                      �	      �	      �	      �	                            -      0                        0      �                      �      �      X      �                                                              &
      +      �+      �+      �+      ,      �,                      b+      �+      8,      e,                      �+      �+      �+      �+                      -      --      0-      .      .      .      0.      �.                      �-      �-      X.      �.                      .      .      .      .                      &/      M/      P/      0      !0      %0      H0      �0                      �/      �/      p0      �0                      0      !0      %0      <0                      F1      m1      p1      B2      D2      H2      p2      �2                      �1      �1      �2      �2                      B2      D2      H2      _2                      f3      �3      �3      _4      a4      e4      �4      
5                      �3      4      �4      �4                      _4      a4      e4      |4                      �5      �5      �5      �6      �6      �6      �6      27                      6      96      �6      7                      �6      �6      �6      �6                      �7      �7      �7      �8      �8      �8      �8      R9                      "8      Y8      �8      %9                      �8      �8      �8      �8                      �9      �9      �9      �:      �:      �:      �:      r;                      B:      y:      ;      E;                      �:      �:      �:      �:                      �;      
C                      �A      B      �B      �B                      _B      aB      eB      |B                      �C      �C      �C      �C      �C      D      0D      RD                      �C      �C      D      D                      �E      �E      �E      yF      �F      �G                      �E      ?F      �F      �F                      	H      iI      �I      �J                      .H      0H      >H      eH      PJ      UJ      �J      �J                      �H      I      �I      �I                      �L      �L      �L      �N      �N      �N      �N      �O                      �N      �N      �N      �N                      _P      jP      mP      �Q      �Q      �Q      R      �R                      �Q      �Q      �Q      R                      HS      QS      TS      �S       T      oT      �T      �T                      TS      VS      gS      �S       T      @T                      �S      �S      @T      oT                      U      U      U      �U      �U      /V      FV      jV                      U      U      'U      oU      �U       V                      �U      �U       V      /V                      �X      �Z      �Z      �Z       [      G\                      \Z      �Z      �[      \                      �Z      �Z      �Z      [                      �\      �\      �\      Q]      �]      �]      �]      
^                      �\      �\      �\      ]      �]      �]                      6]      I]      �]      �]                      l^      u^      x^      �_      �_      �_      �_      |`                      �_      �_      �_      �_                      �`      a      a      =b      ?b      Cb      pb      c                      =b      ?b      Cb      Zb                      �c      �c      �c      d      d      d      Pd      rd                      d      d      d      1d                      �d      �d      �d      �d                      �d      �d      �d      �d                      &e      /e      2e      Uf      Wf      bf      �f      �f                      {e      �e      �f      �f                      Uf      Wf      bf      yf                      Lg      Wg      Zg      0i      2i      =i      hi      Vj                      �g      �g      hi      �i                      ph      �h      �i       j                      0i      2i      =i      Ti                      �j      �j      �j      �o      �o      p      0p      �s      �s      t                      nk      �k      �k      �k      �p      �p      �p      �p                      sn      Lo      �q      �r      �r       s      
q      q      q      `q                      �o      �o      p      !p                      ot      �v      �v      w      0w      =x                      �u      �u      �w      x                      �v      �v      w      w                      �x      �x      �x      9{      <{      G{      x{      &}      =}      k}                      2y      |y      �y      �y      x{      �{      �{      �{      �{      �{                      9{      <{      G{      c{                      �}      �}      �}      �      
�      �      @�      ��      ��      �                      P~      �~      @�      x�                      �      
�      �      1�                      у      f�      j�      ��      �      u�                      ��      م      P�      {�                      م      f�      j�      �      {�      H�                      ��      P�      �      H�                      ��      ��      �      C�      H�      P�      T�      ܍      ��      ��                      A�      C�      H�      P�      T�      ��      ��      ��      @�      h�                      K�      ��      ��      А                      v�      �      ��      ��      ��      Ò      �      `�                      ˑ      �      �       �                      ��      ��      Ò      ڒ                      ֓      ߓ      �      �      �      #�      H�      ��                      +�      u�      H�      `�                      �      �      #�      :�                      6�      ?�      B�      v�      x�      ��      ��       �                      ��      Ֆ      ��      ��                      v�      x�      ��      ��                      ��      ��      ��      ��      ��      �                      �      Q�      S�      ]�      �      (�                      K�      ��      ��      ��                      ��      ��      ��      ��            @�      h�      @�                      ��      �      ��      ��      О      ��      X�      @�      P�      -�      آ      @�                      7�      `�      �       �      �      -�      a�      Ф                      g�      ��      `�      ��      �      @�                      ��      �      ��      ϣ       �      �                      �      @�      ��      ��      Ф       �                      ��      ��      ϣ      a�                      ��      ��      ��      ��      ��      ��                      W�      j�      ب      �                      "�      .�      2�      9�                      ?�      K�      O�      V�                      \�      h�      l�      s�                      y�      ��      ��      ��                      ��      ��      ��      ��                      ��      Ǩ      ˨      ب                      \�      e�      h�      ?�      p�      M�                      ��      �      p�      ��                      ̫      ի      ث      ��      �      ��                      �      c�      �       �                      <�      E�      H�      �      P�      -�                      ��      Ӯ      P�      p�                      ��      İ      Ȱ      W�      [�      f�      ��      ��                      (�      u�      x�      {�      �      �      ��      �                      D�      H�      V�      ��                      ��      ��      (�      @�      �      0�                      N�      ��      ��      c�                      N�      ��      ��      c�                      ��      ��       �      A�                      ��      ��       �      A�                      W�      [�      f�      ��                      �	      
      
      
                      �	      
      
      
                      �%      �%      �&      �&                      �%      �%      �&      �&                      �%      �%      �%      a&      �&      �&      0'      :'                      �%      �%      �%      a&      �&      �&      0'      :'                      �      �      �      �      �      �      �      �      �      �      �      �      H      �                      �      �      �      �      �      �      �      �      �      �      �      �      H      �                            �      �                             �      �             2                      �      D      h	      �	      
      Q
                                                    �      �      �      �      �      h	      �	                      I      �      �      �      �      �      �      �                            {      �      �      �      �                  h      f      �      @!      �!      P"      $      �$      �'      (      &(      o(                      �      $      0      '      &(      b(                      �      $      0      '      &(      b(                      0      @      J      �      �      �                      '      @      h      f      �      @!      �!      B"      $      �$      �'      (                      '      @      h      f      �      @!      �!      B"      $      �$      �'      (                      �      �                                  ^       �       �       �       �       �                       @      G      K      c      g      j                      c      g      n      �                      �      �      f      �                            	      6      N      T      Z                      b      f      j      �      �      �                      �      �      �      �                      �      h      @!      a!      0#      P#      �$      �$      �$      �$      �'      �'                      �!      �!      P"      t"       $      $      �$      �$      �'      �'      (      (                      �"       #      P#      t#      �#       $      �$      �$      �'      �'      (      &(                             $      <      E      X      `                             $      <      E      X      `                      )      0      �            0
      �
      �
      �
      �      �      �      �                      0
      8
      >
      �
      �
      �
                      �
      �
      �
            �      �      �      
                 x             �<      �<                                    s             �<      �<      `                            ~              B       B      �c                            �             ��     ��                                   �              �      �     �B                              �              �      �     �                             �             ��     ��     <                             �              "                                         �             "                                        �              "                                         �             @"     @     �                               �             0"     0     �                           �             �"     �     0                            �             �"     �     �                            �             �""     �"     �                               �             @#"     @#                                   �      0               @#     *                             �                      j#     @                                                  �%     &                                                 �=                                                       �V     �[                             *     0               ��     ^H                            5                     ��     �                            @                     �     0C                                                   Z     N                                                   hd     �      #   n                 	                      �     r                                                           �                    �                    �                                        �)                    @+                    �+                    �4                   	 �<                   
 �<                     B                    ��                  
     C       f    �
     �       u   
      /    ��      d      `                     r    �u            �    `m            �                     �    @k               
	                     	                     .	                     9	    �            @	    p�     �      P	    �`     �       ]	    �d            �	    �Q            �	    P
            �	                     �	     d     �      �	    �K            �	    К     �      
    �s            @
    @Z            o
                     
    �I     ]       �
    p
            �
                     �
    ��      B      �
    ��      d          �      �      9                     L    0w     �      Z                     n    u     '      |     �      �      �    �     "       �    �a     (       �    G            �    z     )       �    �
                            (     z            Z    �#     �       h                      |    ��     �       �    @|            �                     �    ��      9      �    �"     6       �                     
# Index created by AutoSplit for blib/lib/Compress/Raw/Zlib.pm
#    (file acts as timestamp)
1;
FILE   4780e12c/auto/Digest/SHA/SHA.so ;�ELF          >    P      @       �         @ 8  @ #                                 ̲      ̲                    ��      ��      ��      �      �                    �      �      �      �      �                   �      �      �      $       $              P�td   ��      ��      ��      l      l             Q�td                                                  R�td   ��      ��      ��      @      @                      GNU �����_P>�j��-�]�pEr    %   +         @   Ȍe� ��DP$@�2�i  $    +   ,   .       /       2   4       6   7   8       9   ;   <               >       ?   @   A   E       F   H       I   K           L   N   P   a�|\���͋��|5��#MA����iHWv�Ց��Jh��Ao��wȲJq �'2�H�
           ��         =           ��                    ��         1           ��         A           ��         >           ��         
�  h   �`����%�  h	   �P����%��  h
   �@����%�  h   �0����%�  h   � ����%�  h
�  h(   �`����%�  h)   �P����%��  h*   �@����%�  h+   �0����%�  h,   � ����%�  h-   �����%ڦ  h.   � ����%Ҧ  h/   ������%ʦ  h0   ������%¦  h1   ������%��  h2   ������%��  h3   �����%��  h4   �����%��  h5   �����%��  h6   �����%��  h7   �p����%��  h8   �`����%��  h9   �P���H��H�M�  H��t��H��Ð��������U�=�   H��ATSubH�=P�   tH�=O�  �z���H�;�  L�%,�  H���  L)�H��H��H9�s D  H��H���  A��H���  H9�r��~�  [A\]�f�     H�=�   UH��tH�ã  H��t]H�=Ρ  ��@ ]Ð�����AWAVAUATUSH��H�|$�H�L$�H�~@@ ��V����	��V	��VH����	ЉH��H9�u�H�|$�D�T$�D�t$�D�d$ԋl$؋\$܋�|$�H�|$��D$��t$�������|$�H�|$�D�D$��A���|$�H�|$�D�|$���|$�H�|$�D�l$�� C��5�y�ZD�l$�D�t$�F���y�Z�|$��|$�G��/�y�ZA��D$�3D$�#D$�3D$�A��D$�D1�#D$�3D$��D�����D1���D!���A��D1�G�� �y�ZA�A�D��1�D��!�����1�.�y�ZA�A���D1�D��D!���D1�E���y�Z��A��D�؉�1���D!�A��1�A��D$�AɋL$䍔�y�ZD��D1�!���D1�E���y�Z�D�����D1���D!�A����D1�E��8�y�ZA�D��1�A�!�D����1���A��D$�Aȉ�D1ɍ��y�ZD!�D1��D��A����G��3�y�Z�t$�E��1�y�ZD��1�D!�A��1�D�A��A��D�D�L$�B��
�y�ZE��E1�A!���E1�Aщ���Aщ�D1�E��!���A��D1�A׋T$�E�D�4$E���y�Z��1�D!�A��1�B��1�y�ZD�E��A��A�D��1�D!�A��E1�1�A1�D3T$��D����ыT$A��A��A�����y�ZD��D1�D!�A��D1�G���y�Z�D��D1�D�!�A����D1�A��D�D�L$�AӉ�D1�E1�!�A1�D1�E1�E��A��A��G���y�ZA�E�A1�D3l$�D3l$��A1܉�D3d$�3l$�1�E��3l$�D!�A��A��A��1�G��(�y�ZE1�A��D1�D�B��!�y�Z��A�D��1�E��D!�A��A��1�.���n�D��D�D1�D1�A���A��D�A��3\$�3\$�D��A��D1�A��1���D1���E�����nD�D�\$�D�A��E1�A1�D3$A1����t$�3|$�1�1�E1�A��G�����nD1�E�A����A��E�D�D$�A1�D3D$A1�A��G�����nA�D����A�1�3D$��Ǎ�9���n�L$�D1�1�D1�D1���A���D����΋L$��t$������nD��1�D1�A��΋L$����D���L$��L$�D1�3L$�3t$�D1�D1�����
���n�t$���֋T$��t$��t$�3t$���D1�1��Ɖt$�E��7���n��D1�3t$�D�D�|$�A��A��t$�D�|$�D�<$D3|$���A1�A1�A��G��>���nD�|$�D�|$�D�t$�A��A1�D3t$�A��Dt$�E�D�t$�D�|$�D�|$D3|$�A��A1�A1�A��D�|$�B��:���nE��A1�D3|$�D�D�|$�A��A׋T$�D�|$�D�<$��E1�E1�D�|$�D�|$�D1|$��D$�D�|$�B��>���nA��E1�D3|$�D�D�|$�A��D�D�|$�E1�A1�A1�A��D�|$�D�|$E1�E1�E1�A1�D3L$�D�|$�D�|$�D1|$��D$�D�|$�A��G��>���nD�|$�A1�D3|$�E�A��A��E�D�t$�D�|$�D�|$�A��E1�A��D�T$�B�����nD�T$�E1�A1���AҋT$���AҋT$�F��
���n��D1�3T$�D�E��A��D�D�|$�A��A1�A1�D�|$�D3l$�A1�E1�D3d$�A��D3d$�D1�3l$�D1�3\$�A��G��.���nA��D1�E�A��B��&���nA����D1�E�D�t$���D�|$�E1�A1���D�E��A��D�D�t$�E��.���nA��E1�D3t$�E�����nE�A��A��E�D�t$�A��D�t$�A1�A1�A1�D3\$���E�E��A1�A��D3D$�1�E�D�T$�3|$�E1�D�t$�A��A1�B�����nA1�E1�A��A��D�E��D�|$�A��D�|$�1�D�D�T$���G�����nD��>ܼ�A1�D3T$�E�A��A��E�D�T$�D����A��A���D	�#t$�3D$�D�|$�A����E!�3L$�D	�D1�D�|$�D1�t$���D1�E��ܼ��D$�D��	�D1�D�|$�E��D!�A!���A��D	�D$�A��A��E��
ܼ�D�A��A��E�A��D�|$�E	�A��E!�A!���E	�D�|$�D3|$�DT$�E1�A1�A��B��:ܼ�D�|$�A��A	��T$���E!�!���A	׋T$�D�E��A��D�D�|$�D3|$�A1�D�|$�D�|$�D1|$��D$�D�|$�G��>ܼ�A��A��E�E��D�|$�A	�E��A!�A!�A��E	�D�|$�D3|$�Dt$�A1�A1�A��B��>ܼ�D�|$�A��E	׉t$���A!�D!���A	��t$�D�E��A��D�D�|$�D3|$�E1�D�|$�D�|$�D1|$��D$�D�|$�B��8ܼ�A��A��A�D��D�|$�	�E��A!�D!�A��D	�D�|$�D$�E1�E1�D�|$�D�|$�D1|$��D$�D�|$�G��:ܼ�A��E	�D�T$�A��A!�E!���E	�D�T$�E�A��A��E�D�|$�E1�A1�D�|$�D�|$�D1|$��D$�D�|$�B��:ܼ�E��A��A׉�D�|$�	�A��A!�D!�D	�D�|$�T$�E1���A1�A1�A1�D3d$�E1�D�|$�D3d$�E1�E��A��A!�A��D�L$�G��ܼ�E��A	�A��A!�E	�A��E�D�t$�A��E�E1�A��A��E!�D�l$�B��.ܼ�E��A��D�A����E	�A!�B�� ܼ�E	�E��D�E��A!�A	�E!�E	�D1�3l$�3l$�A��D�A��A��D1�D�3\$�A��A��3\$�E!���A��A1�E��*ܼ�D3\$�E�A����E	���A!Ս�ܼ�E1�E	�A��A��E�A��A!�A	���E!�G��ܼ�E	�E��D�A��D�E��A��A��D3D$�A!�D3D$�E�E��A	�A��1�A!�3|$�E	�A��E�A1�A��A��E	�E!�B��ܼ�A!�1�E	�E����A�A����8ܼ�E���E��D��A!�E�����D��A��	�D!�D	�E����t$�3t$�3t$�3L$�E	�3L$�E!�A!�E	�A��A��A��D1���D1�E��2ܼ�����
ܼ�E�A��E�E!�E��A��D�A����E	�E!�E	�E��AҋT$�3T$�A	�E!�D1�1���E��ܼ�D�L$�E��A!�E	�D�L$�E�E��A��E�D�t$�D3t$�A��A1�A1�A��D�t$�G��5��b�E��A1�E1�A��E�E��A��E�D�t$�D3t$�A1�A1�A��D�t$�B��0��b�E��E1�E1�A��A�D����AƋD$�3D$�D1�1����D$�E����b�D��D1�D1�A��A�D����D�E��D$��D$�3D$�D1�3D$�E1�E1�A����E����b�E�D�|$�A��E�D�T$�D3T$�D�|$�E��E1�D3|$�A1�D3T$�A��G����b�E�D�|$�A��E�D�L$�D�|$�A��D�L$�D�L$�D�|$�E1�A1�D3L$�E1�D3|$�A��G��
1ȋO(G$3G D�DoF��!�D7q��D!�3G$D����A�D����1�D����1ȋOAËG	�#O��!�	�����1�����
1�ȋO D�D_A��D1�A	�D#GD!�3O D����A�D����1�D����1��Aʉ���!�A	ȉ���1����
1�w A�D��E�DWD1�D���۵�E��A��D!�D��D1���A�D����1�D����1�D��A�	�D��!�!�	�D����D1�E��A��
D1�D�t$��D��D�DOD1�G��5[�V9A��D!�E��D1�A��A�D����D1�E��A��D1�A��A�E	Ɖ�A!�D!�A��A	Ή���D1�A��A��
D1�D�|$�D�D�A�D��D1�G��;��YE��D!�A��A��D1�A��A�D����D1�E��A��D1�A��A�A	���!�E!�A	։���D1�A��A��
D1�D�D�AËD$�E��A��E����?�D��D1�A��A��D!�D1�A�D����D1�E��A��D1�A��A�A	Ή�!�A!�A	Ɖ���D1�A��A��
D1�D�D�E�D�D$�E��A��A��G���^�E��E1�E!�E1�E�E��A��E1�E��A��E1�A��E�A	�A��A!�A!�A��E	�A��A��E1�A��A��
E1�E�D�t$�E�A�D��D1�E��D!�G��5���E��D1�A��A��A�D����D1�E��A��D1�E��A�A	�D��!�A!�A	�D����D1�E��A��
D1�D�|$�D�D�A�D��D1�G��;[�E��D!�A��A��D1�A��A�D����D1�E��A��D1�A��A�E	Ɖ�D!�A!�A	Ή���D1�A��A��
D1�D�D�AӋT$�E��A��A��E����1$D��D1�D!�D1�A�D����D1�E��A��D1�A��A�A	���E!�!�A��A	։���D1�A��A��
D1�D�D�t$�D�A�D��D1�A��D!�G��1�}UE��D1�A��A��A�D����D1�E��A��D1�A��A�A	Ή�!�A!�A	Ɖ���D1�A��A��
D1�D�|$�D�D�E�E��E1�G��=t]�rE��E!�A��A��E1�A��E�E��A��E1�E��A��E1�A��E�A	�A��A!�A!�E	�A��A��E1�A��A��
E1�E�E�A��t$�E��E��A��E��3��ހD��D1�D!�D1�A�D����D1�E��A��D1�E��A�A	�D��A!�!�A��A	�D����D1�E��A��
D1�D�D�t$�D�A�D��D1�A��D!�G��2�ܛE��D1�A��A��A�D����D1�E��A��D1�A��A�E	Ɖ�D!�A!�A	Ή���D1�A��A��
D1�D�|$�D�D�A�D��D1�G��9t��E��D!�A��A��D1�A��A�D����D1�E��A��D1�A��A�A	���!�E!�A	։���D1�A��A��
D1�D�|$�D�D�t$�Dt$�D�A��D$�A����D1�D�|$�A��
D1�E��A�D��A����D1�E��A��D1�D�E��E1�E���i��E��E!�A��E1�E�E��A��E1�E��A��E1�A��E�A!�A��D�t$�A��A��A	�Dd$�DD$�A!�E	�A��A��E1�A��A��
E1�D�|$�E�D�t$�Dl$�A��A��E1�D�|$�A��
E1�A��E�A��A��A��E1�A��l$�A��E1�E�E��E1�G��#�G��E��E!�A��E1�E�E��A��E1�E��A��E1�E��E�A!�E��D�t$�E��A��A	�t$�A!�E	�E��A��E1�E��A��
E1�A��E�A��A��A��D\$�E1�A��A��E1�A��D�A��A��A��\$�E1�A��A��
E1�D�E��E1�E��*Ɲ�A��A!�A��E1�E�A��A��E1�A��A��E1�E��E�E!�E��D�t$�E��A��E	�L$�A!�E	�E��A��E1�E��A��
E1�D�|$�E�D�t$�DT$�A��A��E1�D�|$�A��E1�E��D�E��A��A��E1�E��A��
E1�E��Aމ�A��D1�G��1̡$D�t$�!�A��D1�A��Aى���D1�A��A��D1�E��D�E	�E��E!�E!��E	�E��A��E1�E��A��
E1�D�|$�E�D�L$�Aދ\$�\$�A��A��E1�D�|$�A��E1�A��D�A��A��A��E1�A��A��
E1�E��Aى�E	�D�L$�G��o,�-A��A1���E!�A!�A1�E�A��A��A1ى���A1�D��E�E����E!�E�E	�E��A��A1�D����
A1؋\$�E�D�D$�E�D�L$�DL$�A����A1؋\$���A1؋\$�E�D�D$���A��A1؋\$���
A1�D��E�E��D	�D�D$�B����tJA��A1�A��D!�E!�A1�D�E��A��E1�E��A��E1�E��A�D��A��D!�	�D����D1�E��A��
D1�D�L$��t$�D�E�D�D$�A��DD$���D1�D�L$�A��D1�D�L$�A��t$�A����D1�D�L$�A��
D1�A��D�E��A���t$���1ܩ�\D��1�A��D!�1��D����D1�E��A��D1�A���E	���D!�E!�A	ȉ���D1�A��A��
D1�D�L$�A�A�L$�A��t$�A������1΋L$���1΋L$�t$���D1�D�L$��A��
D1�E���D��A	ىL$���
ڈ�vD��D1���E!�D!�D1��D����1�D����1�D���D����!�A	�D����1�D����
A�1�t$�AыT$�AɋL$�������1ыT$���1ыT$�L$���1�t$�D���
1�D������T$�A��RQ>�D��D1�E��D!�D1��D����1�D����1�D���D	�D��D!�!�	�D����A��A�D1�E��A��
D1�D�l$�֋T$�΋L$�A������1ыT$���1ыT$�L$���D1�D�l$��A��
D1�A���D���T$�E��m�1�D��D1���D!�D1�A�D����1�D����1ʉ�A�D	ɉ�D!�D!�	щ�A����D�D1�A��A��
D1�D�l$�ыT$�D�D�\$�A����A��A1ӋT$���A1ӋT$�D\$�D\$���D1�D�l$�A��
D1�A��D�A�ۉT$�E���'�D��D1�A��!�D1�A҉���D1�A��A��D1�A��A�A	��E!�!�A��A	Ӊ���D1�A��A��
D1�D�l$�D�D�\$�D�E�D�D$�A��A��A��E1�D�D$�A��E1�D�D$�D\$�D\$�A��E1�D�l$�A��
E1�E�E��D�D$�G���Y�A��E1�A��A��E!�E1�E�E��A��E1�E��A��E1�A��E�A	�A��A!�A!�A��E	�A��E�A��E1�A��A��
E1�D�t$�E�D�\$�E�D�l$�A��A��A��E1�D�\$�A��E1�D�\$�Dl$�Dl$�A��E1�D�t$�A��
E1�E��E�A��D�\$�G�����E��A1�E��E!�A1�E�E��A��E1�E��A��A��E1�E��E�A	�E��A!�A!�E	�E��A��E1�E��A��
E1�D�|$�E�D�t$�E�A��t$�A��A����A1��t$���A1��t$�Dt$�Dt$���D1�D�|$�A��
D1�E��D�E��t$���3G���D��D1�D!�D1��D����A��A��D1�E��A��D1�E���E	�D��D!�A!�A	�D����D1�E��A��
D1�D�|$�D�D�t$��ˋL$�A��A����A1΋L$���A1΋L$�Dt$�Dt$���D1�D�|$�A��
D1�A��D�A�މL$�E��
Qc�D��D1�!�D1�Aʉ�A����A��D1�A��A��D1�A��A�E	މ�D!�E!�A	Ή���D1�A��A��
D1�D�|$�D�A��D�A҉���A��A��A1։���A1֋T$�Dt$�Dt$���D1�D�|$�A��
D1�D�A��E1�E��g))E!�E1�G�<1E��E��A��A��E1�E��A��E1�A��E�A!�A��D�t$�A��A��A	�DD$�E!�E	�A��A��E1�A��A��
E1�E��E�E��A��A��DL$�E1�E��A��E1�D�|$�D�D�t$�D$�A��A��E1�D�|$�A��
E1�D�E��A1�E���
�'E��E!�A��A1�E�E��A��E1�E��A��E1�E��E�A!�E��D�t$�E��A��A	�D\$�A!�E	�E��A��E1�E��A��
E1�A��E�A��A��A��Dl$�E1�A��A��E1�A��E�A��Dd$�A��A��E1�A��A��
E1�E��E�E��A��E1�B��38!.D�t$�E!�E��E1�A��D�E��A��E1�E��A��E1�E��A�E	�D��D!�A!�D�A	�D����D1�E��A��
D1�Aދ\$�E�D�d$�E����A��D1�D�d$�A��D1�A��݉�l$�A����D1�A��A��A��
D1��D��D1�E���m,MA��!�A��D1�A����D1�A��A��D1�E��A�D��E!�D	�D�D!�D	�E��A��E1�E��A��
E1�D�|$�A�l$�E�D�d$���A��D1�D�d$�A��D1�l$�D�d$�A�l$���A��D1�D�|$�A��
D1�E��D�A��E	��l$�E��(
E1�A��E�D�D$�A�l$�A����A1�l$���A1�DD$��l$�A��D�A��A��E1�A��A��
E1�E��A�D��E	�D�D$�G��Ts
eA��A1���E!�E!�A1�E�E��A��A1�D����A1�D��E�E����E!�E�E	�E��A��A1�D����
A1�l$�E�D�D$�E�D�\$�A��A��E1�D�\$�A����E1�DD$�D�\$�E�D�D$�A��A1�l$���
A1�D��E�E��D	�D�D$�B���
jvE��A1�A��D!�E!�A1�D�E��A��E1�E��A��E1�E��A�D��A��D!�E�	�D����D1�E��A��
D1�D�\$���t$�D�D�D$���A��A��D1�D�D$�A��D1�t$�D��t$���D1�D�\$�A��
D1�A��D�E��E	�t$���1.�D��D1�A��E!�D!�D1��D����D1�E��A��D1�A����A��D!�A	����D1�A��A��
D1�D�D$�A�t$�A�D�D�T$���A��D1�D�D$�A��A��D1�t$�D��t$���D1�D�T$�A��
D1�E��D�A��A���t$�E��1�,r�D��D1�A��!�D1�A����D1�A��A��D1�E��A�A	�D��!�E!�A	�D����D1�E��A��
D1�D�T$�A��t$�E�E�D�L$�A����A��D1�D�L$�A��D1�t$�D�L$�A�t$���D1�D�T$�A��
D1�E��D�A���t$�E��5�迢��D1�E��D!�A��D1�A�D����D1�E��A��D1�E��A�E	�D��D!�A!�A	�D����D1�E��A��
D1�D�l$�A�E̋t$�E�D�L$�A����A��D1�D�L$�A��D1�t$�D��t$���D1�D�l$�A��
D1�D�E��t$�E��6Kf�D��1�A��E��D!�A��1�A�D����D1�E��A��D1�E��A�E	�D��D!�E!�A	�D����D1�E��A��
D1�D�D�t$�D�D�L$�D�D�l$�A��A��E1�D�l$�A��E1�DL$�D�l$�A��E�D�L$�A��E1�D�l$�A��
E1�E�A��D�L$�F��	p�K�E��E1���A��A!���E1�E�A��A��A1ɉ���A1ɉ�E�A��D!�E	�E!�A	ɉ���D1�A��E�A��
D1�D�t$�D�D�L$�D�D�l$�A��A��A��E1�D�l$�A��E1�DL$�D�l$�E�D�L$�A��E1�D�t$�A��
E1�E��E�A��D�L$�G���Ql�A��E1�A��E!�E1�E�E��A��E1�E��A��E1�A��E�A	�A��A!�E!�E	�A��A��A��E1�A��A��
E1�D�|$�E�D�t$�E�E�D�D$�A��A��A��E1�D�t$�A��E1�DD$�D�t$�E�D�D$�A��E1�D�|$�A��
E1�E��E�D�D$�G����E��A1�E!�A1�G�4E��E��A��A��E1�E��A��E1�E��E�A	�E��A!�A!�E	�E��A��A��E�E1�E��A��
E1�D�|$�E�D�d$�E�D�t$�A��A��A��E1�D�t$�A��E1�D�t$�E�D�d$�Dt$�A��E1�D�|$�A��
E1�E��E�E��D�d$�B��%$��E��E1�A��E!�E1�D�E��A��E1�E��A��E1�E��A�E	�D��A!�D!�A��A	�D����D1�E��A��
D1�D�|$�D�A��D�A��A����A��D1�A��A��D1�D�t$�A��t$�Dt$���D1�D�|$�A��
D1�A��D��t$�E��3�5�D��D1�D!�D1�E�43D��E��A����D1�E��A��D1�A��A�E	É�D!�E!�A��A	����D1�A��A��
D1�D�A��D�AΉ�A����A��D1�A��A��D1�D�\$�ʋL$�T$�A����D1�D�\$�A��
D1�E���D��A��D1�E��
D1�AӋT$�E�D�l$���A��D1�D�l$�A��D1�D�l$�ЋT$�D$�A����D1�D�l$�A��
D1�E���D��D1�E�����T$�D!�D��D1���A�D����1�D��A����1�D��A�	�D��!�!�E�	�D����D1�E��A��
D1�A��Љ�A��D�A����A��A��D1�A��A��D1�D�T$�A҉�DT$���D1�A��A��
D1�A�D��D1�G��l7E��D!�D1�A�D����A��A��D1�E��A��D1�A��A�E	܉�D!�A!�D�A	ԉ���D1�A��A��
D1�AԋT$�E�D�l$�E����A��D1�D�l$�A��D1�D�l$�ӋT$�\$�A����D1�D�l$�A��
D1��D��D1�E��LwH'A��!�D1�A��A��AՉ���D1�A��A��D1�E��A�A	�D��!�E!�A	�D����D1�E��A��
D1�E��D�D�t$�A��D�A��t$�A����A1��t$���A1�D��Dt$�Dt$���D1�E��A��
D1�A��D��t$�E��1���4��D1�A��D!�D1�E�41D��E��A����D1�E��A��D1�A��A�E	��D!�A!�E�A	����D1�A��A��
D1�A��A�t$�A��E�D�t$���A��A1��t$���A1���Dt$�Dt$���D1�A��A��
D1�E��D�A���t$�E��0�9D��1�D!�1�E�40D��E��A����D1�E��A��D1�E��A�A	�D��!�E!�A	�D����D1�E��A��
D1�D�|$�A��t$�E�AƋD$�A������1ƋD$���1ƋD$�t$�t$���D1�D�|$�A��
D1�E���D��A���D$���J��ND��D1���D!�D1��D����1�D����1�D���D	�D��D!�!�A�	�D����D1�E��A��
D1�D�|$�ƋD$��l$�A������1ŋD$���1ŋD$�l$����D1�D�|$�A��
D1�A���A���D$�A��Oʜ[D��D1�E��D!�A��D1��D����D1�E��A��D1�A���E	ŉ�D!�E!�A	ŉ���D1�A��A��
D1�D�|$�D�D�l$��ՋT$�A����A1ՋT$���A1ՋT$�Dl$�Dl$���A��D1�D�|$�A��
D1�A��D�A��A���T$�E���o.hD��D1�A��!�D1�AӉ���D1�A��A��D1�A��A�A	���!�E!�A	Չ���D1�A��A��
D1�D�D�l$�D�E�D�L$�A��A��E1�D�l$�A��E1�DL$�D�l$�A��E�D�L$�A��E1�D�l$�A��
E1�E�E��D�L$�G��tA��E1�A��A��E!�A��E1�E�E��A��E1�E��A��E1�A��E�A	�A��A!�A!�E	�A��A��E1�A��A��
E1�E�D�T$�E�E�D�D$�E��A��A��E1�D�T$�A��A��E1�DD$�D�T$�A��D�D�D$�A��E1�D�T$�A��
E1�E��D�E��A��A1�E��oc�xE!�A1�E�E��A��E1�E��A��E1�E��E�A	�E��A!�A!�E	�E��A��E1�E��A��
E1�D�t$�E�D�T$�E�A�t$�E����A��A��D1�D�T$�A��D1�D�T$�A��t$�Dt$�A����A1�t$���
A1�D��E�D1�F��5xȄD!�D��D1���A�D����1�D����1�D��A�D	�D��D!�!�	�D����D1�E��A��
D1�A���l$�D�AD$�A������1ŋD$���1�l$���l$�����
D1�A��1�A���\ D��D��D1���D!�E��ǌD1�A�D����1�D����1��A�D	ŉ�D!�D!�	ŉ���D1�A��A��
D1�E���l$�D�AӋT$�A������1ՋT$���1�l$�D��l$���A��
D1�A��D1�A���D��D1�E��-����E��D!�A��D1�A�D����D1�E��A��D1�A��A�A	���!�E!�A	Չ���D1�A��A��
D1�E�A��D�D�l$�A��D�D�t$�A��A��E1�D�l$�A��E1�Dt$�A��Dt$�A����
E1�A��A1�D��A��D1�E�D!�G��,�lP�D1�E��A��A�D����D1�E��A��D1�A��A�A	ĉ�!�A!�A	܉���D1�A��E�A��
D1�A��D�A��A��D�A��A��A��E1�A��A��E1�D�t$�G��&����A��Dd$�A����
E1�A1�D��D1�E�A��D!�E�E��D1�A��A�D����D1�E��A��D1�A��A��A!�	�!�D	�A��A��A��D�E1�A��A��
E1�D�D�T$�D�D�d$�A��A��E1�D�d$�A��E1�E��F���xq�D��DT$���A��A��
A1�D��E1�D1�E�!�A��D1�E�A��Aˉ�A����D1�A��A��D1�A��Aˉ�A����A1ʉ�A!���
A1ʉ�	�!�D	�D�ODىO_oG Ww$DG(DO,�_[�oAÉW]A\A]A^D�_ �w$D�G(D�O,A_�ff.�     AWL���   AVAUATUSH��@  H�L$� ��VH��8H��0H	��VH	��VH��(H	��VH�� H	��VH��H	��VH��H	��VH��H��H	�H�H��L9�u�H�D$0L��$0   L� H�p�Hp�H�H�L��M��I��H��=I��-L1�L1�I��H�H��I��?H��H��L1�H1�H�H�PH��L9�u�H�GL�E1�L�5<M  H�D$�H�G L�T$�H�D$�H�G(H�\$�H�D$�H�G0L�d$�H�D$�H�G8H�T$�H�D$�H�G@L�\$�H�D$�H�GHL�L$�H�D$�H��L��� L��M��I��L��I��L��I��H��H��H��K,H��2H��.Jl�H1�H��I��H��I��$I��H1�L��L1�H�L��H!�H!�L1�H�L��H	�I�H!�H	�H��H��L1�I��I��L1�H�H�I���  �k���H\$�Ld$�H��HD$�LT$�L�HT$�L\$�LL$�H�wH�_(L�g0H�GL�W H�W8L�_@L�OHH��@  []A\A]A^A_��     �?   H�OH���   L�GPH��6H��0f��H���ֈP��@�0����@�p����@�pH��H9�u���f�H�
H�� �ΈH��@�0����@�p����@�p�
H���ΈH��@�p����@�p����@�pH��L9�u���ffff.�     AUI��ATI��UH��SH��H�����   H9�r&�    L��H���U���   ��H)���I�H9�v�H��tH�S�H�}PL��H��H���̾�����   H��L��[]A\A]��     H�\$�H�l$�H��L�d$�L�l$�I��L�t$�L�|$�H��8���   D���   H������D��H���H9�sV1�H��u?H�|;PL���R�����   H��H�\$H�l$L�d$L�l$ L�t$(L�|$0H��8�fD  H�V�H��H���f�A)�L�kPL��E��A��L�L��M�����H��L��H��L)�I���Sǃ�       H��L��L�������v���f�AWI��AVI��AUATUSH��H  dH�%(   H��$8  1�H��H�t$ �D$,    tH��H��H�����D$,A���   �   �����A�ĉ�A����D)������A"LPA�LPA�6��D����	�H;\$ A�tPH�T$ HF��H9\$ A���   �b  A;��   �  L�|$ I)��G  �|$,   H�\$0��   D�L$,H�\$0M���A�u 1�f�     @�����A�t��D��@����	��H��H=   u�I��   �   L��IF�H��L�D$H��H�L$D�L$����D�L$H�L$I��   L�D$A��   I)�A��   �l����D$,-  ��	����H����	H��	I֋T$,�� ����D$,D�L$,A��t;D�T$,A�61�A��I���@�����A�t��D��@����	��H��L9�u�E�ɉ�L��C�L��H����B�D0�����H��$8  dH3%(   H�D$ u7H��H  []A\A]A^A_�I�pPL��L�D$A�PL�D$Aǀ�       �\����f���fD  U�F�SH��H����� �$ �D$ �D$ wHc�   H��H��H��������$H��I  �t$�|$����������?�
�������	ȉ�H�����C�����H������?	�H���C�
�C�D+ H��[]��     UH��SH��H���_���H�0H����    H�����:t�H���DN u��H��u�A��:t3H���DV u(H�����u�H9��    H�M HD�H��[]�fD  � H����H�E 1����    AWI��AVE��AUI��ATU��SH��H��h  H��$O  D�L$,dH�%(   H��$X  1�H�T$@ H��_  �:�ڸ��H��H����������  L�d$P�L;d$t1H�������A�$I��<
tH��_  �:藸��H��H���<�����t�A�$ �T$P��#t���t��T$�����T$I��H�H�D$P�f.�     H������Y���H���DQ u�H�t$8H�|$P�g���L��H��輸��1҅���   L�|$ L�|$L�|$�-���u#�T$,1�H���ݹ��H�T$�H��H�T$D  A��E����   H�|$8H�t$8�����H��H����   ����   ~���f���   ��u��D$@ �D$A E1��fD  H�|$@I���   1��[���I�H�I�$H���T$@�DQu�M�/I���m���D  1҉�H��$X  dH3%(   ucH��h  []A\A]A^A_ËT$,1�H�������H�T$ �H��H�T$ ����@ �T$,1�H���Ҹ��H�T$�H��H�T$������   �豶����H�����  =�   ��  =   �<  =�  ��  =   ��  =�� �[  = � t��f����  �J  @���(  @���N  ��1���@���H�t
�    H��@��t	f�  H����t� H������ � ǂ�      ǂ(      H�BH�
^  H�JH�
]  H�JH�
  ��1���@���H���  @����  ���w  H�������� ǂ�      ǂ(     H�BH�
�H��蚮��H��H�\$H�l$H����     ��   t����� t���   t�1�� � t���fff.�     H�\$�H�l$�H��L�d$�L�l$�L�t$�H��(H��S  �;肬���;L�(�x���H�Pp�;D�"H��H�Pp�b���H�pIcԋ;H��I)�I��A����   �?���H�@A���;Mc�J�,�    J���@
���    ���   ��t�t�����D  1��D  �s��� �����ff.�     AWAVAUATUSH��H��L�%�Q  A�<$菪��A�<$L�(胪��H�PpA�<$D�2H��H�Pp�k���H�xIc�H��A�<$I)�I��E��D����  �D���H�@A��Mc�N�4�    J��H�@H�X�C
   A�   �   H�������1ۅ�uVH��t1L�%8  A�<$����H���I���H9�tA�<$�����H��H������H��t
H��1�����H��H��[]A\�D  �|$臐��H��H��t�1ҁ|$   H�HH�5�  A�   A�   H�����`������b���D���   H�KPH�5q  A�   �   H��A���/������1���H���   H�5�  A�
   A�   �   H��� ����������D$=   �(  ���   �  �����H���   H�5L  A�
   A�   �   H�������������H���   H�5#  A�
   A�   �   H�������������H���   H�5�  A�
   A�   �   H���T������V���H���   H�5�  A�
   A�   �   H���%������'���L�%F6  A�<$�=���H���u���H9��K���A�<$�#���H��H���8����2��� H�5n  �D���H��H�������1�����=  ��������   �  �����������H�\$�H�l$�L�d$�L�l$�I��L�t$�H��(H��5  �;袎���;L�(蘎��H�Pp�;�*H��H�Pp胎��H�pHcՋ;H��I)�I��A����   �`���H�@���;Hc�L�$�    H���@
�    H����t	f�  H����t� H��H��[]A\A]�H�kD��L��H��薌������H���E  �@��t�f�  H����@��t��    ��H���x���H�{蔍��H��1��:����H�{����H�{�v���H��1������q����    H�R�׊���    H�\$�H�l$�H��L�d$�H��H��!���H�{L�c��(  �>���L��H����Hc�H��芊��H�{����H�{H�l$H�$L�d$H���֋��fD  H�������    H�释���    H������    H��SH��tKH�螌����H�ߺ�   ��   @����   @��ue��1������H�u>��u!��uH������1�[��     � �� f�  H����t����     �    H����t����    �    ��H���f�     � H�{���e���f�f�  ��H���\���ffffff.�     AWAVAUATUH��SH��(L�%�0  A�<$菉��A�<$L�(胉��H�PpA�<$HcH��H�Pp�k���A�<$H��    HPH�E D�{D�p(I)�I��A�m��?���B�\= H�@A�<$Hc�H���@
���H�xE�eN�,�;L)�����H�@Icԋ;L�,�    H��L�4��օ��H�=
  E1�H���
����;胄��H��+  L�   H�
  H�5w  E1�H��H���ۄ��H� �;�@(
   �J���L�}  H�
  H�5[  E1�H��H��规��H� �;�@(   ����L�I  H�
  H�5;  E1�H��H���s���H� �;�@(   ����L�  H�
  H�5  E1�H��H���?���H� �;�@(   讂��L��
  H�5   E1�H��H������H� �;�@(   �z���L��
  E1�H��H���׃��H� �;�@(   �F���L�y
  H��E1�H��裃��H� �;�@(   ����L�E
  E1�H��H���o���H� �;�@(   �ށ��L�
  E1�H��H���;���H� �;�@(   誁��L��  H�
  E1�H��H������H� �;�@(   �v���L��  H�
  E1�H��H���ӂ��H� �;�@(	   �B���L�u  H�
  E1�H��H��蟂��H� �;�@(   ����L�A  H�
  E1�H��H���k���H� �;�@(   �ڀ��L�
  E1�H��H���7���H� �;�@(    覀��L��  H�
���H�-�&  L�6  H�
  H�
  H�
  H�
  E1�H��H��萀��H� �;�@(   ��~��L�2
  H�
   ��~��L��	  H�
  E1�H��H���(���H� �;�@(   �~��L��	  H�
  E1�H��H������H� �;�@(   �c~��L��	  H�
H %s%02x 
block :%02x 
blockcnt:%u
 file, s Digest::SHA::shadump Digest::SHA::shaclose blockcnt lenhh lenhl lenlh lenll file v5.14.0 5.71 SHA.c Digest::SHA::shaload Digest::SHA::shaopen $$$ Digest::SHA::sha512_hex Digest::SHA::sha512_base64 Digest::SHA::sha224 Digest::SHA::sha256_hex Digest::SHA::sha384_hex Digest::SHA::sha512 Digest::SHA::sha512224 Digest::SHA::sha1_hex Digest::SHA::sha256 Digest::SHA::sha384_base64 Digest::SHA::sha1_base64 Digest::SHA::sha224_hex Digest::SHA::sha512224_hex Digest::SHA::sha512256_base64 Digest::SHA::sha384 Digest::SHA::sha256_base64 Digest::SHA::sha224_base64 Digest::SHA::sha1 Digest::SHA::sha512256 Digest::SHA::sha512224_base64 Digest::SHA::sha512256_hex Digest::SHA::hmac_sha1_base64 Digest::SHA::hmac_sha1 Digest::SHA::hmac_sha1_hex Digest::SHA::hmac_sha224 Digest::SHA::hmac_sha384_hex Digest::SHA::hmac_sha256_hex Digest::SHA::hmac_sha512224 Digest::SHA::hmac_sha512 Digest::SHA::hmac_sha512256 Digest::SHA::hmac_sha256 Digest::SHA::hmac_sha224_hex Digest::SHA::hmac_sha384 Digest::SHA::hmac_sha512_hex Digest::SHA::algorithm Digest::SHA::hashsize $;@ Digest::SHA::add Digest::SHA::digest Digest::SHA::Hexdigest Digest::SHA::B64digest lenhh:%lu
lenhl:%lu
lenlh:%lu
lenll:%lu
        Digest::SHA::hmac_sha512224_base64      Digest::SHA::hmac_sha512_base64 Digest::SHA::hmac_sha512224_hex Digest::SHA::hmac_sha512256_hex Digest::SHA::hmac_sha256_base64 Digest::SHA::hmac_sha384_base64 Digest::SHA::hmac_sha224_base64 Digest::SHA::hmac_sha512256_base64                      "�(ט/�B�e�#�D7q/;M������ۉ��۵�8�H�[�V9����Y�O���?��m��^�B���ؾopE[����N��1$����}Uo�{�t]�r��;��ހ5�%�ܛ�&i�t���J��i���%O8�G��Ռ�Ɲ�e��w̡$u+Yo,�-��n��tJ��A�ܩ�\�S�ڈ�v��f�RQ>�2�-m�1�?!���'����Y��=���%�
�G���o��Qc�pn
g))�/�F�
�'&�&\8!.�*�Z�m,M߳��
e��w<�
jv��G.�;5��,r�d�L�迢0B�Kf�����p�K�0�T�Ql�R�����eU$��* qW�5��ѻ2p�j��Ҹ��S�AQl7���LwH'�H�ᵼ�4cZ�ų9ˊA�J��Ns�cwOʜ[�����o.h���]t`/Coc�xr��xȄ�9dǌ(c#����齂��lP�yƲ����+Sr��xqƜa&��>'���!Ǹ������}��x�n�O}��or�g���Ȣ�}c
�
��<L
G       L   �  ���j   B�E�E �B(�A0�A8�G�
8A0A(B BBBA   $   �  ����    A�D�G0�AA,   $  �����    A�D�G c
AAG     L   T  ����o   B�E�E �E(�A0�C8�J��
8A0A(B BBBA      �  ����          <   �   ���~   B�B�D �A(�D0
(A ABBE       �  @����    N ��I
I $     ����w   M��S0���"
F    D  ���u           L   \  p���   B�B�B �B(�A0�A8�GP|
8A0A(B BBBI    L   �  0���   B�B�B �B(�D0�A8�DP
8A0A(B BBBC    <   �  �����   B�R�H �A(�F0�}
(A BBBI     <  ����    A�P       $   \  �����    A�D�D |AA4   �  ����    B�D�A �D0�
 AABF        �  ����           ,   �  �����   M��X@����2
I            h���           $     `���v   M��S0���
A $   D  �����    A�S
DI
G     <   l  p����   B�B�B �A(�D0�Y
(A BBBE  L   �  ����   B�B�B �B(�A0�D8�JP�
8D0A(B BBBA    L   �  �����   B�B�B �B(�D0�A8�DP�
8A0A(B BBBF       L  �����    DO
E     L   l  �����   B�B�B �B(�A0�A8�G`
8A0A(B BBBJ    <   �   ���   B�B�B �D(�A0�f
(A BBBH  4   �   ����   B�A�A �D0�
 DABF     $   4  x���u   W����I0�#
E <   \  ����	   B�E�I �H(�D0b
(D ABBA       �  ����	              �  ����j    M��I �O    �  ����	              �  ����	                ����	                �����    D�S
I   L   <  ����c   B�B�B �B(�A0�D8�D`]
8A0A(B BBBH    <   �  ����8   B�B�B �A(�A0�((A BBB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             ��������        ��������                       .             �      
             P      
       �                           �             p                                        x             �      	              ���o          ���o           ���o    p      ���o                                                                                                                                                                                                                           �                      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F      V      f      v      �      �      �      �      �      �      �      �                  &      6      F                      ��                              #Eg�����ܺ�vT2����            ؞��|6�p09Y�1��Xh���d�O��g�	j��g�r�n<:�O�RQ�h��ك��[؞�]����|6*)�b�p0ZY�9Y���/1��g&3gXh�J�����d
<�   �   
L�   8  �B   �  	�W   �}  n)  }  #  	B   �  
B    �#   f  �	  
x�  �#  
z�   # �  
{^   # �&  
B      �#�  �(  )A  # 1  *W   #@   +�  #H 	\  �  
B     �  d�  W   ^,  0]+  '	  _+  # 
B    �  U  !�  N  #W   #,  $�    
B    �  �3�  �  5W   # �   6W   #  8W   #n#  k�  # #  lK  �  W   �  �    �  �  	B   �  
B    �  4;   	  �  
B   
B    tms  #  ]  %:  # �  &:  #�  (:  #,   ):  #   �#  g  (    # t)    #3  W   #�'   �  # �    e�  +  g  # Q  h  #f  iW   #Q  jW   #�  k  # �
     ))    # G+    #�  W   #�     # �  H?  {(  J  # �!  K  #�+  LW   # �&  �  �  �   # o(  �   #~   4   #�,  !-   #�  "�  # 	  �  
B   � �  &�  �  (�   # o(  )�   #~  *4   #�,  +-   #�  ,�  # DIR �	  %  IV �^   UV �B   NV �)	  �  �  b	P  OP i	G	  op ($
  �  %7.  #   %7.  #�  %H@  #9  %�?  # Z  %;   	#  �  %;   #  T  %;   #  �  %;   #  �  %;   #  �"  %;   # n
  cop Pc  �  �7.  #   �7.  #�  �H@  #9  ��?  # Z  �;   	#  �  �;   #  T  �;   #  �  �;   #  �  �;   #  �"  �;   # n
  �  #(�)  �  #0  �+  #8�  �+  #<�  ��F  #@.  ��F  #H �  o	o  ,  X?�  �  @7.  #   @7.  #�  @H@  #9  @�?  # Z  @;   	#  �  @;   #  T  @;   #  �  @;   #  �  @;   #  �"  @;   # n
  ��*  #�	�(  �  #�	�,  ��*  #�	�)  �  #�	�   wP  #�	�  I   #�	U  +  #�	F   
W   #�	c     #�	  =.  #�	�  
g-  f+  #�
I  f+  #�
�  f+  #�
�  �Q  #�
�&  6  #�

    #�

    #�
!
    #�

    #�
�	    #�
�	    #�
c    #�
�     #�
�  +�*  #�
�  -  #�
�$  .  #�
c(  /�*  #�
E,  0  #�
   2  #�
l  3  #�
]  4  #�
�  5f+  #�
�  8E  #�
�,  9f+  #�
�
  <	+  #�
�  >	+  #�
�  B	+  #�
�'  EW   #�
�  F�  #�
<  I=.  #�
%
  NM4  #��,  Q=.  #�`'  T=.  #��  W=.  #��  X=.  #��*  p=.  #��  qf+  #�%  rf+  #�	%  sf+  #�<  tM4  #��  w�3  #�A  x�3  #��)  yf+  #�A  zM4  #��&  {M4  #��  |M4  #��  }M4  #�9
  ~M4  #�"  �3  #��  �+  #�!  �W   #�x  �	+  #��
  #�
  �+  #�Y  �W   #��  ��O  #��  
p   #�>  p   #��  p   #�8&  f+  #�D$  	+  #�N  	+  #��  	+  #��  	+  #�?  	+  #�;#  +  #��   �Q  #��,  +  #�v%  ^   #�	(  "  #�h  #P  #��  $P  #�d  %+  #�M   &  #��  0�*  #�{  6  #��  8  #�Y#  :  #��  >f+  #��  ?f+  #�b  @f+  #�m   Af+  #��  Bf+  #�T*  Cf+  #�  Df+  #�`  Ef+  #��   Ff+  #�W   Gf+  #�U  Hf+  #�<
  Of+  #��)  Pf+  #��  Qf+  #��  Rf+  #��  Sf+  #��   Tf+  #��  Uf+  #��  Vf+  #��  Wf+  #��,  Xf+  #�  Yf+  #�5!  Zf+  #��  [f+  #�  \�3  #�N  ]�9  #�U"  ^0	  #�D  _�Q  #�q-  `�*  #��%  f  #�
  �f+  #��  ��P  #��*  �f+  #�*  �f+  #�E*  �f+  #��  �f+  #�  ��P  #��  �M4  #��  �M4  #��*  �^   #�'  �+  #�3  �W   #��!  ��3  #��  �P  #��  �P  #�  �P  #�9  �&P  #��  �YP  #��  �	  #�y  �	  #�u  ��3  #��  �W   #��+  ��Q  #�   2P  #��  
�3  #�  
  �
  $"  #X%  $$w-  #`5*  $&}-  #h=  $(W   #p�  $,W   #t?  $.�   #x!#  $24   #�s	  $3I   #�  $4�-  #��  $8�-  #�C  $A�   #��   $J�   #��   $K�   #��   $L�   #��   $M�   #��+  $NP  #�*  $PW   #��  $R�-  #� %�  $�  $�w-  �   $�w-  #   $�}-  #o  $�W   # @-  l+  	  �-  
B     9-  	  �-  
B    �  %c�-    	  %e�-  �-  U  %�-  G  �  &7�    '�7.  �'  '�	+    '�    '�7.  �  '�=.  R
  '�  y&  '�	+   <	  �"    '��-  HE YX.  he !�.  �$  !=/  # �  !�3  #  !GF  # HEK Z�.  hek !�.  �  !+  # \  !	+  #j$  !�-  # s1/  `  s    s	    s	  
u4  $�  u4  $@(  �    �  y  (�4  )+  (�*  # �,  (�*  #�!  (�*  # y  ({4  �   ($5    (%	+  # -  (&	+  #  ('f+  #�  ((f+  #  ()	+  # 
B    "  (5d5    (6	+  # "end (7	+  # "  (8;5    `(z$6  �%  ({�6  # �  (|�6  #?  (7  #�&  (�77  #�&  (�N7  # -  (�t7  #(Z  (��7  #0�*  (��7  #8;  (��7  #@�  (�8  #H  (�77  #P;'  (�?8  #X *6  o5  �!  5  d5  !  (qj6  #  (s  # i  (tj6  # 	+  }  (uA6  */6  �6  Z+  �6  +   f+  {6  *	+  �6  Z+  �6        	+  f+  �   +   /6  �6  *  7  Z+  �6  f+      7  7   +  p6  �6  *f+  77  Z+  �6   "7  N7  Z+  �6   =7  o7  Z+  �6  o7  �6   	+  T7  �7  Z+  �6  o7  �7   �7  �7  p   z7  *	+  �7  Z+  �6  �7  o7   �7  *f+  �7  Z+  �6  �6  �6  7   �7  *f+  8  Z+  �6  �7  7   �7  *�   98  Z+  �6  98   �*  8  c  (1	+  '(<j8  )  (=�8  #  ]  X(3�8  Q  (4W   # L  (5  #u (�a=  # j8  '(C�8  )  (E�8  # �(  (F+  #cp (GE8  # '(K$9  )  (M�8  # �(  (N+  #cp (OE8  #�  (Q$9  # �4  'H(T�9  )  (V�8  # �(  (W+  #cp (XE8  #�  (Z+  #�  ([�9  #B (\$9  # me (]$9  #(5	  (^�9  #0�
  (_+  #8�  (`�*  #<�  (a�*  #>�  (b  #@ �*  �*  '8(g~:  )  (i�8  # �  (j�8  #  (k�8  #l  (l/6  #+  (m+  # cp (pE8  #$X+  (qE8  #(�   (r+  #,B (s$9  #0 '(v�:  )  (x�8  # V%  (y	+  #�   (z	+  #me ({$9  # ' (~	;  )  (��8  # �  (��8  #d
  (�	+  #$ '8(��<  )  (��8  # c1 (�	+  #c2 (�	+  #cp (�E8  #�   (�	+  #0  (�	+  #�  (�  #A (�$9  # B (�$9  #(me (�$9  #0 '@(�a=  �   (�+  # cp (�E8  #c1 (�	+  #c2 (�	+  #4#  (�  #a  (�  #0  (�W   # min (�W   #$max (�W   #(A (�$9  #0B (�$9  #8 )H(7�=  +yes (>Q8  $�  (I�8  $�  (R�8  $�  (c*9  $�  (t�9  $!  (|~:  $o  (��:  $�   (�	;  $V  (�";  $g)  (��;  $�
  (��<   ]  (�j8  !�  �(�E>  �  (�E>  # �*  (�U>  #��   (�U>  #� 	�=  U>  
B   - >  �  (�>  �$  �(��?  �  (�+  # �(  (�+  #�	  (�	+  #	  (�  #7   (�  #�*  (�  #s  (�  # �#  (�;6  #(�(  (��?  #0�  (��?  #82  (�  #@�  (�4  #H  (��?  #Py   (��?  #X�  (�  #`9  (�0	  #ht+  (�0	  #p  (�	+  #x_+  (�	+  #|0)  (�	+  #�~  (�+  #��  (�  #�g  (�  #� +  c  �"  PAD )�   �  )B   "@  �  "7.  �  "\)   "8@  �  "7.  �  "G4   *7.  H@  Z+   8@  )Ip@  $  J7.  $�'  L�?   )Q�@  $i  R7.  $D  T   B  0*2A  �
  *4  #   *5  #]%  *6p   #l  *7{   #�"  *8  #f  *9  # &  *:  #(    +,FA  R  +.  # ?  +/  #a  +0{   #�%  +1  # ,*"  �  ,.�A  �  ,0�A  # "sb0 ,1B  #�"sb1 ,2B  #��"sb2 ,3B  #��"sb3 ,4B  #��q  ,6�  #��y  ,7B  #���#  ,8^   #��"  ,9W   #���  ,9W   #�� 	  B  
B    	  B  -B   � 	  $B  
B    �*  H-(�B  �
  -,^   #�  --^   #�	  -.^   # O  -/^   #(�"  -1^   #0�  -3^   #8s,  -5B   #@ .�.r�E  k  .t  # �  .uP  #�
  .{�E  #�  .  #�  .�P  #    .�1  #(�  .�)	  #@�
  .�P  #��!  .�"  #��  .�  #�o  .�P  #��  .�F  #��  .�W   #�F)  .�  #�*  .�  #��  .�P  #��  .�F  #�[  .��@  #��  .�  #�$(  .�P  #�   .�F  #��  .��  #��  .�  #�t  .�P  #��,  .�#F  #�-  .�$B  #�   .�  #��   .�P  #�^  .�)F  #�  .��  #��  .�[  #�4  .�/F  #�;  .�P  #�  .�/F  #�W  .�5F  #��  .�P  #�O	  .�5F  #�V  .�  #��  .	  #�}  .
P  #��  .
"  +<I  <*  ,7.  #  )0?�I  $
  �)  P~hJ   '  �*  # 
B    		+  �O  
B    	+  /nnL  �)  �O  �  �O  �  �  ��O  �O  *W   P  Z+   d  �P  P  &P  Z+  f+   |  ��O  �'  �>P  DP  *  YP  Z+  f+   z  �eP  kP  wP  Z+   /d  ��P  
B    1  *�P  �P  �P  Z+  7.   x#  ;Q  Q  *	+  +Q  Z+  �6  �6   Z
  I�P  �  RbQ  fn S`+  # ptr T�   # r$  U7Q  6  \)  �$  K  	  �Q  
B    [>  �=  �Q  6  bQ  	�   �Q  
B    0+  	�*  �Q  
B   	 �O  *  ;F  �-  �   1SHA 0��R  "alg 0�W   # "sha 0��R  #"H 0��R  #)  0�S  #P�  0�;   #��  0�;   #�)  0�;   #�)  0�;   #�d*  0�;   #�j*  0�;   #��  0��R  #�D  0�W   #�"hex 0�S  #��*  0�#S  #� �R  �R  �R   �Q  -   �R  	-   S  
B   ? 	-   S  
B    	  #S  
B   � 	  3S  
B   V SHA 0��Q  �1S  d!  1S  # �%  1S  #  1S  #"key 1S  # 3S  �  1>S  2�  ��S  3mem ��R  3w32 �;   4i �W    5q  1�   �S  6�   1�   6x  1�  6%  1P   7B#  W   T  8�    9p    7�  
  ZT  8�  
  8h  
;   :f 
I/  9p    ;^  UB   �T  3s U  4str WB  4u XB    5�  M�   �T  6�   M�   6�  MW   6%  MP   <�+  pB   �T  8�  p�R  8  pB   :s pS   5t   W   U  3__s    6   6  = <C!  �  GU  :s �S  9i �W    5P   �  qU  6�   �  6x  �6   <�*  �  �U  :s �S  9n �W   9q ��R  9out ��U   	  �U  
B    7�&  YS  �U  :f YI/  :s YS   >�  V       �.          �V  ?s VS  =  @)  V�R  u  Aa X;   �  Ab X;     Ac X;      Ad X;     Ae X;   0  BW Y�V  ��Awp Z�V  #  BH [�V  ��#�C@      m      At ]W   �  Aq ]�V  �    	;   �V  
B    ;   >�!  ��.      %W      �  �W  Ds �S  U@)  ��R     Aa �;   K  Ab �;   �  Ac �;   �  Ad �;   4  Ae �;   �  Af �;   �  Ag �;   "  Ah �;   c  AT1 �;   �  BW ��V  ��4kp ��V  Awp ��V  �#  BH ��V  u�C�.      /      At �W   ^%  Aq ��V  �%    >�  _0W      xY      �%  �X  Ds _S  U@)  _�R  �&  Aa aB   C'  Ab aB   �'  Ac aB   �'  Ad aB   Z(  Ae aB   �(  Af aB   )  Ag aB   q)  Ah aB   �)  AT1 aB   -*  AT2 aB   c*  BW b�X  ��zBH cY  u�At dW   �*  CPW      �W      At fW   �*  Aq fY  �*    	B   Y  
B   O B   EN'  ��Y      #Z      w>Z  ?s �S  +  4i �;   Bd ��R  PAp32 ��V  @+  Ap64 �Y  c+  F�S  �Y      �Y      �Y  G�S  �+  G�S  �+  C�Y      �Y      H�S  2,    F�S  �Y      �Y      ��Y  G�S  �,  G�S  �,  C�Y      �Y      H�S  ,-    I�S  �Y      Z      �J�S  qxG�S  �-  C�Y      Z      H�S  .     K�  $B   0Z      �Z      c.  �Z  L�  $�R  O/  L  $B   �/  Ms $S  �/  N  &B   0   K�  5B   �Z      �[      M0  &[  L�  5�R  �0  L  5B   1  Ms 5S  �1  ND  7;   �1  N�  8;   2  N  9B   /2   K$  LB   �[      
^      �2  �[  L�  L�R  �3  L  LB   u4  Ms LS  5  Oi N;   X5  Ogap O;   �5  N�  PB   �5  Pbuf Q�[  ��{Q,  R;    Qa   SB    NU  T;   �5  R  UB   ��{ 	-   \  -B   � S!  �^      �^      I6  �\  Min ��R  �6  Mn �W   7  Mout �  >7  R�  ��\  �PT�S  5^      H^      �G�S  t7  G�S  �7  G�S  �7    	-   �\  
B    K8%  #  �^      I_      �7  	]  L�  #  �8  LF   #  �8  Op %  29  Ov %  �9   KA
  :W   P_      �a      �9  �^  Mf ;I/  O;  Mtag <6  �;  L�,  =W   �;  L  >�   *<  L�  ?W   �<  L[  @W   �<  Op B  =  Opr B  �=  R�  B�^  ��{Opc C�R  �=  Opi C�V  :>  Opl D�V  �>  Opq DY  p?  UT  o_          F9^  GET  �?  G9T  �?  J-T  ��{�VP   HOT  +@    U�S  `      �   Gf^  WT  V�   HT  N@    XJ`      d`      �^  Y6  IP  Y�"  IP   TZT  �`      /a      RGkT  �@  C�`      /a      ZtT  ��{HT  �@     	  �^  -B   � [  �a      �i      w_  Ms S  A   \
  ��i      >k      =A  �_  @  �Z+  =B  ?cv �A4  `B  ]	  �W   Asp �1/  �B  Aax �	+  �B  ^o  �1/  iC  ^L
  �	+  �C  _   �_  As �S  �C  V`  Atmp �	  �C    C�j      �j      ^P  ��_  D    	  `�$  S  @k      �k      *D  9`  Malg W   �D  Os S  �D   \�$  ��k      Gm      	E  a  @  �Z+  iE  ?cv �A4  �E  ]	  �W   Asp �1/  �E  Aax �	+  F  ^o  �1/  �F  ^L
  �	+  �F  _�  �`  Aalg �W   G  ^�  �S  2G   C�l      �l      ^P  ��_  hG    a�T  Pm      �m      wpa  G�T  �G  G�T  �G  G�T  H  b�T  �m      �  pG�T  gH  G�T  �H  G�T  �H    cP(  ��m      �o      	I  kb  L  �Z+  [J  Mcv �A4  ~J  d	  �W   Osp �1/  �J  Oax �	+  �J  No  �1/  �K  NL
  �	+  �K  V   Y&  �f+  Ai �W   'L  ^�  ��R  KL  Alen �0	  nL  ^X  �S  �L  C=o      Yo      ^P  ��_  �L     \�+  ��o      �r      �L  uc  @  �Z+  ?N  ?cv �A4  bN  ]	  �W   Asp �1/  �N  Aax �	+  
O  ^o  �1/  �O  ^L
  �	+  �O  _@  ^c  N�  �R  
  �	+  �\  Oix �	+  �\  V�  Y&  �f+  Alen �0	  G]  ^X  �S  �]  ^�  �  �^  C�w      �w      ^P  ��_  �^     h�*  �W   px      sx      w�g  is �S  U cf  ��x      �y      _  th  L  �Z+  h_  Mcv �A4  �_  d	  �W   Osp �1/  �_  Oax �	+  `  No  �1/  �`  NL
  �	+  �`  Oix �	+  �`  V�  Y&  �f+  ^X  �S  Ha  ^�  �W   ~a  Czy      �y      ^P  ��_  �a     `g  �S   z      �z      �a  �h  Ms �S  Mb  Pp �S  P \X  ��z      �|      �b  �i  @  �Z+  �c  ?cv �A4  �c  ]	  �W   Asp �1/  d  Aax �	+  Ld  ^o  �1/  �d  ^L
  �	+  e  _   ui  As �S  Oe  ^�  �S  re  V@  Atmp �	  Oe    C*|      C|      ^P  ��_  �e    `    �W   �|      �~      �e  j  L�)  �  g  Ms �S  gg  Oi �W   �g  Oj �W   �g  Of �I/  Fh  Op ��R  �h   \�  q�~      ,�      �h  k  @  qZ+  =j  ?cv qA4  `j  ]	  tW   Asp t1/  �j  Aax t	+  k  ^o  t1/  �k  ^L
  t	+  Ul  _p  �j  ^�)  {  �l  As |S  �l  ^�  }W   �l  ^<  ~�6  m  V�  Atmp �	  �l    V�  ^P  ��_  Pm    `�%  �W   0�      �      tm  =k  Ms �S  �m   c�   �      ݄      n  `l  L  Z+  oo  Mcv A4  �o  d	  W   Osp 1/  �o  Oax 	+  �o  No  1/  ^p  NL
  	+  �p  Oix  	+  Pq  V   Ai QW   �q  ^�  R�R  �q  Alen S0	  
r  ^X  TS  /r  ^�  U  �r  _p  =l  jP  X�_   C��      �      ^P  n�_  �r     \�%  R��      ��      s  Em  @  RZ+  t  ?cv RA4  .t  ]	  UW   Asp U1/  �t  Aax U	+  �t  ^o  U1/  �u  ^L
  U	+  �u  _�  /m  As \S  v  ^�  ]W   $v  ^<  ^�6  Zv  V   Atmp a	  v    V0  ^P  l�_  �v    `�  cS   �      ��      �v  �m  L�)  c  �w  Oalg eW   �w  Os fS  �w  Of gI/  �x  T�U  Z�      ��      {G�U  y  G�U  Jy    \�  ���      %�      my  �n  @  �Z+  �y  ?cv �A4  �y  ]	  �W   Asp �1/  9z  Aax �	+  pz  ^o  �1/  �z  ^L
  �	+  ={  _`  �n  ^�)  �  s{  ^�  �S  �{   C��      ׊      ^P  ��_  �{    k!  o  0�      9�      �{  o  ?alg W   �|  ?key �R  L}  @�  ;   �}  Ai ;   �}  Ah o  O~   �S  l�  >B   @�      I�      weo  @�  >�R  �~  @  >B   �~  ?h >o     \  DP�      ��      :  �o  ?h Do  �   l&  M�R  ��      ɍ      w�o  ?h Mo  �   l,  S  Ѝ      ٍ      w�o  ?h So  �   ld%  Y  ��      �      w*p  ?h Yo  �   k~  _W   ��      ��      %�  ]p  ?h _o  ��   c�'  MЎ      3�      ΀  �q  L  MZ+   �  Mcv MA4  C�  d	  PW   Osp P1/  y�  Oax P	+  ��  No  P1/  ��  NL
  P	+  *�  Oix T	+  s�  V�  Ai �W   �  Akey ��R  �  ^�  ��R  .�  Alen �0	  d�  ^X  �o  ��  ^�  �  
  �	+  R�)  �6  
��      �_   y  Ocv 
A4  ]�  XU�      X�      lr  O_p �   �   X��      ��      �r  O_p �   
B   ? n�  0Jy  /y  	;   _y  
B    BH01 DOy  	 �      	;   �y  
B    o�*  Jty  	 �      o�  Pty  	@�      o	
B   @ Pmap �Bz  	�      z  	W   Wz  
B    o�  lz  	@�      Gz  ]�  2�}-  ]V  2�}-  	  �z  p d|  ��z  �z  ]F  3 =+  d	  �W    %  $ >  $ >   :;I      I  :;  
  	I  
! I/  :;  :;  
  
  &   :;  
  !:;  "
  #:;  $
  ':;  (:;  ):;  *'I  +
  C  D :;I
  E.:;'@
  F1XY  G 1  H4 1  I1XY  J 1
  K.:;'I@  L :;I  M :;I  N4 :;I  O4 :;I  P4 :;I
  Q4 :;I  R4 :;I
  S.:;'@  T1XY  U1RUXY  VU  W 1  X  Y4 :;I  Z4 1
  [.?:;'@
  \.?:;'@  ]4 :;I?<  ^4 :;I  _U  `.?:;'I@  a.1@
  b1RUXY  c.?:;'@  d4 :;I?<  e1XY  f.1@  g4 1  h.?:;'I@
  i :;I
  j4 :;I  k.?:;'I@  l.?:;'I@
  m4 :;I  n4 :;I  o4 :;I
  p!    1   �  �
J�~� X � � = ;j�xXD=8;KY�� �}+ � � = ;gY;=izXB���/���.FP,Fۣv�
J�~� f � � � 9 �� �~� ���� � ?��|X�@�|X���|�� x�5)��v�
J �0 � + Y - = � + � s��v-�&�9MZ:> .���� w��KW <ew Y e qf �v&zfY+�hp �;�|$4)��y�C � ) f � �7 � | = � Y - = % " , L g n< w w0t-��K;=�{.�9��{��x@�~t ��  ? �~����~� � ./>WKsrwU3y.	����Y;��G;KY�� �~t8�Y;=rO
        w0
               w8       �       w� �      �       w8�      �       w0�      �       w(�      �       w �      �       w�      �       w�      �       w                                U       �       ��                        =        T=       H        t|�H       }        T                p              ��#      Q       Tt      �       T�      
       T&      f       Rt      �       R�      #       R5      �       R�             R$      �       R�      �       T�      "       ��~"      �       Q�      �       _�      �       ��~�      D       ^p      �       _�      �       ��~�      �       ^�      Z       ��~Z      �       ^�      �	       ^�	      B
       ^N
      0       ^R      �       Y�      %       Yk      �       Y�      �       T�      T
       Q�
      {       Q{      ~       ]�      �       Q5      
       Z�
      :       ZR      �       Z      Y       Zk      
       PN
      �       P�             P5      �       P�      (
       T�
      k       T�      �       T�      �       ]      �       T�      �       ]
(      @(       [�(      �(       Xw)      �)       R'*      _*       Y�*      +       Y�+      �+       ]O,      �,       ]-      E-       ]�-      
 �E      "E       
 �                �C      �C       \                �C      D       ��{�D      8D       P                �D      �D       P�D      E       S                �D      �D       0��D      �D       ]�D      E       ]                �E      �E       U�E      �M       Q                �M      �M       w�M      �M       w�M      �M       w�M      �M       w �M      �M       w(�M      �N       w0�N      �N       w(�N      �N       w �N      �N       w�N      �N       w�N      �N       w�N      O       w0                �M      �M       U                �M      �M       T�M      &N       \O      O       \                �M      �M       p �M      �M       ]                �M      �M       p� �M      �M       V�M      N       v�N      �N       V�N      O       VO      O       v�                �M      �M       v  $ &3$p"�O      O       Q                �M      �M       } v  $ &3$p8�                �N      �N       U                �N      �N       0�                 O      .O       w.O      wO       w wO      �O       w�O      �O       w                  O      8O       U8O      nO       SxO      �O       S                ZO      eO       PeO      fO       V                �O      �O       w�O      �P       w0�P      �P       w�P      'Q       w0                �O      �O       U                �O      �O       T�O      6P       VQ      'Q       V                �O      �O       p �O      P       ]                �O      �O       p� �O      �O       \�O      )P       |�)P      �P       \�P      Q       \Q      'Q       |�                �O       P       |  $ &3$p"�Q      Q       Q                �O      P       } |  $ &3$p8�                jP      nP       U                tP      {P       P{P      �P       ]                �P      �P       1�                0Q      �Q       U�Q      �Q       U�Q      �Q       U                0Q      �Q       T�Q      �Q       T�Q      �Q       T                0Q      �Q       Q�Q      �Q       Q�Q      �Q       Q                �Q      �Q       Q�Q      �Q       Q                �Q      �Q       T�Q      �Q       T                �Q      �Q       U�Q      �Q       U                �Q      �Q       w�Q      �Q       w�Q      �Q       w�Q      �Q       w �Q      �Q       w(�Q      �Q       w0�Q      �Q       w8�Q      =S       w� =S      >S       w8>S      ?S       w0?S      AS       w(AS      CS       w CS      ES       wES      GS       wGS      PS       wPS      �S       w�                 �Q      �Q       U                �Q      �Q       T�Q      ;R       S�S      �S       S                �Q      �Q       p �Q      R       ]                �Q      �Q       p� �Q      �Q       ^�Q      $R       ~�$R      /R       ^/R      jR       _�S      �S       _�S      �S       ~�                �Q      R       ~  $ &3$p"��S      �S       Q                R      YR       ]YR      aR       V�S      �S       V                LR      jR       1�                �R      S       _                jR      �S       ��                LR      -S       SHS      �S       S                S      HS       1�                �S      �S       w�S      �S       w�S      �S       w�S      �S       w �S      �S       w(�S      �S       w0�S      �S       w8�S      �U       w� �U      �U       w8�U      �U       w0�U      �U       w(�U      �U       w �U      �U       w�U      �U       w�U      �U       w�U      �V       w�                 �S      �S       U                �S      �S       T�S      5T       \�V      �V       \                �S      �S       p �S      T       ]�U      �U       V�U      �U       v�                �S      �S       p� �S      �S       V�S      (T       v�(T      qU       V�U      �V       V�V      �V       v�                �S       T       v  $ &3$p"��V      �V       Q                �S      T       } v  $ &3$p8�                lT      �U       _�U      �V       _                �T      �U       ���U      V       ��FV      �V       ��                aU      uU       Q                {U      U       PU      �U       ]                �T      �U       ^FV      �V       ^                �U      �U       1�                �V      �V       w�V      �V       w�V      �V       w�V      �V       w �V      �V       w(�V      pX       w0pX      qX       w(qX      sX       w sX      uX       wuX      wX       wwX      �X       w�X      �X       w0                �V      �V       U�V      pX       SpX      xX       UyX      �X       S                �W      X       s�                �W      �W       s���W      �W       s���W      �W       s���W      X       s��                �W      �W       0��W      �W       1��W      �W       2��W      X       4�                �W      X       s�                �W      �W       s���W      X       s��X      X       s��                �W      �W       0��W      X       1�X      X       2�                X      pX       s�pX      xX       u�                X      .X       s ~ "#P�.X      8X       s ~ "#Q�8X      BX       s ~ "#R�BX      pX       s ~ "#T�pX      wX       u ~ "#T�                X      .X       0�.X      8X       1�8X      BX       2�BX      yX       4�                HX      pX       s�pX      xX       u�                HX      WX       s } "#P�WX      aX       s } "#Q�aX      kX       s } "#R�kX      pX       s } "#T�pX      uX       u } "#T�                HX      WX       0�WX      aX       1�aX      kX       2�kX      yX       4�                �X      �X       w�X      �X       w�X      �X       w                �X      �X       U�X      �X       S�X      �X       p�~�                �X      �X       w�X      �X       w�X      �X       w�X      UY       w UY      VY       wVY      WY       wWY      XY       w                �X      �X       U�X      WY       V                Y      Y       0�>Y      JY       P                Y      JY      
 ��      �                Y      BY       s 1$v "#��BY      JY       s1$v "#��                `Y      bY       wbY      fY       wfY      gY       wgY      kY       w kY      6Z       w06Z      7Z       w 7Z      8Z       w8Z      :Z       w:Z      @Z       w@Z      `Z       w0                `Y      Y       UY      �Y       \�Y      Z       |�|�;Z      YZ       \YZ      [Z       |�|�                �Y      �Y       \�Y      �Y       v�~��Y      Z       |�|�                �Y      �Y       |��Y      �Y       S�Y      �Y       s��Y      Z       S                �Y      Z       V                pZ      �Z       w�Z      �[       w� �[      �[       w�[      G\       w�                 pZ      �Z       U                pZ      �Z       T�Z      
`      ,`       1�                �`      �`       w�`      �`       w�`      �`       w�`      �`       w �`      �`       w(�`      �`       w0�`      �`       w8�`      Ab       w� Ab      Eb       w8Eb      Fb       w0Fb      Hb       w(Hb      Jb       w Jb      Lb       wLb      Nb       wNb      Ob       wOb      zb       w�                 �`      �`       U�`      �`       SOb      gb       S                �`      �`       T�`      Fb       VOb      zb       V                
`      0`      z`                      m_      �_      0`      M`                      �b      �b      �b      7d      9d      =d      hd      �d                      �c      �c      �d      �d                      7d      9d      =d      Td                      8f      Vf      ^f      af      lf      �g      h      �h                      ^f      af      uf      �f      �h      �h                      i      =i      @i      j      j      j      @j      �j                      �i      �i      hj      �j                      j      j      j      0j                      �m      n      n      �n      �n      �n                      �r      �r      s      u      0u      v                      �s      �s      �s      �s      �u      v                      �v      Ӂ      Ձ      ܁                       .symtab .strtab .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .ctors .dtors .jcr .dynamic .got .got.plt .data .bss .comment .debug_aranges .debug_info .debug_abbrev .debug_line .debug_str .debug_loc .debug_ranges                                                                                 �      �      $                              .   ���o       �      �      \                            8             P      P      �                          @             �
      �
      �                             H   ���o       p      p      �                            U   ���o                   `                            d             x      x      �                           n                         p         
                 x             �      �                                    s             �      �      �                            ~             P      P      h�                             �             ��      ��                                    �             ��      ��      �	                              �             ��      ��      l                             �              �       �      �                             �             ��      ��                                    �             н      н                                    �             �      �                                    �             �      �      �                           �             h�      h�      �                             �             �      �      �                            �             ��      ��      �                              �             `�      `�                                    �      0               `�      *                             �                      ��      0                              �                      ��      �z                                                  >     9                                                  �D     5                                  0               �V     �-                            (                     ��     W�                             3                     �     P                                                   L     A                                                   P'           "   G                 	                      `5     {                                                           �                    �                    P                    �
                    p                                        x                                       	 �                   
 �                    P                    ��                   
# This file was created by configpm when Perl was built. Any changes
# made to this file will be lost the next time perl is built.

# for a description of the variables, please have a look at the
# Glossary file, as written in the Porting folder, or use the url:
# http://perl5.git.perl.org/perl.git/blob/HEAD:/Porting/Glossary

package Config;
use strict;
use warnings;
use vars '%Config';

# Skip @Config::EXPORT because it only contains %Config, which we special
# case below as it's not a function. @Config::EXPORT won't change in the
# lifetime of Perl 5.
my %Export_Cache = (myconfig => 1, config_sh => 1, config_vars => 1,
		    config_re => 1, compile_date => 1, local_patches => 1,
		    bincompat_options => 1, non_bincompat_options => 1,
		    header_files => 1);

@Config::EXPORT = qw(%Config);
@Config::EXPORT_OK = keys %Export_Cache;

# Need to stub all the functions to make code such as print Config::config_sh
# keep working

sub bincompat_options;
sub compile_date;
sub config_re;
sub config_sh;
sub config_vars;
sub header_files;
sub local_patches;
sub myconfig;
sub non_bincompat_options;

# Define our own import method to avoid pulling in the full Exporter:
sub import {
    shift;
    @_ = @Config::EXPORT unless @_;

    my @funcs = grep $_ ne '%Config', @_;
    my $export_Config = @funcs < @_ ? 1 : 0;

    no strict 'refs';
    my $callpkg = caller(0);
    foreach my $func (@funcs) {
	die qq{"$func" is not exported by the Config module\n}
	    unless $Export_Cache{$func};
	*{$callpkg.'::'.$func} = \&{$func};
    }

    *{"$callpkg\::Config"} = \%Config if $export_Config;
    return;
}

die "Perl lib version (5.14.2) doesn't match executable '$0' version ($])"
    unless $^V;

$^V eq 5.14.2
    or die "Perl lib version (5.14.2) doesn't match executable '$0' version (" .
	sprintf("v%vd",$^V) . ")";

sub FETCH {
    my($self, $key) = @_;

    # check for cached value (which may be undef so we use exists not defined)
    return exists $self->{$key} ? $self->{$key} : $self->fetch_string($key);
}

sub TIEHASH {
    bless $_[1], $_[0];
}

sub DESTROY { }

sub AUTOLOAD {
    require 'Config_heavy.pl';
    goto \&launcher unless $Config::AUTOLOAD =~ /launcher$/;
    die "&Config::AUTOLOAD failed on $Config::AUTOLOAD";
}

# tie returns the object, so the value returned to require will be true.
tie %Config, 'Config', {
    archlibexp => '/usr/lib/perl/5.14',
    archname => 'x86_64-linux-gnu-thread-multi',
    cc => 'cc',
    d_readlink => 'define',
    d_symlink => 'define',
    dlext => 'so',
    dlsrc => 'dl_dlopen.xs',
    dont_use_nlink => undef,
    exe_ext => '',
    inc_version_list => '',
    intsize => '4',
    ldlibpthname => 'LD_LIBRARY_PATH',
    libpth => '/usr/local/lib /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib /usr/lib',
    osname => 'linux',
    osvers => '2.6.42-37-generic',
    path_sep => ':',
    privlibexp => '/usr/share/perl/5.14',
    scriptdir => '/usr/bin',
    sitearchexp => '/usr/local/lib/perl/5.14.2',
    sitelibexp => '/usr/local/share/perl/5.14.2',
    so => 'so',
    useithreads => 'define',
    usevendorprefix => 'define',
    version => '5.14.2',
};
FILE   c33fbebe/Config_git.pl  �######################################################################
# WARNING: 'lib/Config_git.pl' is generated by make_patchnum.pl
#          DO NOT EDIT DIRECTLY - edit make_patchnum.pl instead
######################################################################
$Config::Git_Data=<<'ENDOFGIT';
git_commit_id=''
git_describe=''
git_branch=''
git_uncommitted_changes=''
git_commit_id_title=''

ENDOFGIT
FILE   920842a2/Config_heavy.pl  ��# This file was created by configpm when Perl was built. Any changes
# made to this file will be lost the next time perl is built.

package Config;
use strict;
use warnings;
use vars '%Config';

sub bincompat_options {
    return split ' ', (Internals::V())[0];
}

sub non_bincompat_options {
    return split ' ', (Internals::V())[1];
}

sub compile_date {
    return (Internals::V())[2]
}

sub local_patches {
    my (undef, undef, undef, @patches) = Internals::V();
    return @patches;
}

sub _V {
    my ($bincompat, $non_bincompat, $date, @patches) = Internals::V();

    my $opts = join ' ', sort split ' ', "$bincompat $non_bincompat";

    # wrap at 76 columns.

    $opts =~ s/(?=.{53})(.{1,53}) /$1\n                        /mg;

    print Config::myconfig();
    if ($^O eq 'VMS') {
        print "\nCharacteristics of this PERLSHR image: \n";
    } else {
        print "\nCharacteristics of this binary (from libperl): \n";
    }

    print "  Compile-time options: $opts\n";

    if (@patches) {
        print "  Locally applied patches:\n";
        print "\t$_\n" foreach @patches;
    }

    print "  Built under $^O\n";

    print "  $date\n" if defined $date;

    my @env = map { "$_=\"$ENV{$_}\"" } sort grep {/^PERL/} keys %ENV;
    push @env, "CYGWIN=\"$ENV{CYGWIN}\"" if $^O eq 'cygwin' and $ENV{CYGWIN};

    if (@env) {
        print "  \%ENV:\n";
        print "    $_\n" foreach @env;
    }
    print "  \@INC:\n";
    print "    $_\n" foreach @INC;
}

sub header_files {
    return qw(EXTERN.h INTERN.h XSUB.h av.h config.h cop.h cv.h
              dosish.h embed.h embedvar.h form.h gv.h handy.h hv.h intrpvar.h
              iperlsys.h keywords.h mg.h nostdio.h op.h opcode.h pad.h
              parser.h patchlevel.h perl.h perlio.h perliol.h perlsdio.h
              perlsfio.h perlvars.h perly.h pp.h pp_proto.h proto.h regcomp.h
              regexp.h regnodes.h scope.h sv.h thread.h time64.h unixish.h
              utf8.h util.h);
}

##
## This file was produced by running the Configure script. It holds all the
## definitions figured out by Configure. Should you modify one of these values,
## do not forget to propagate your changes by running "Configure -der". You may
## instead choose to run each of the .SH files by yourself, or "Configure -S".
##
#
## Package name      : perl5
## Source directory  : .
## Configuration time: Mon Mar 18 19:16:26 UTC 2013
## Configured by     : Debian Project
## Target system     : linux batsu 2.6.42-37-generic #58-ubuntu smp thu jan 24 15:28:10 utc 2013 x86_64 x86_64 x86_64 gnulinux 
#
#: Configure command line arguments.
#
#: Variables propagated from previous config.sh file.

our $summary = <<'!END!';
Summary of my $package (revision $revision $version_patchlevel_string) configuration:
  $git_commit_id_title $git_commit_id$git_ancestor_line
  Platform:
    osname=$osname, osvers=$osvers, archname=$archname
    uname='$myuname'
    config_args='$config_args'
    hint=$hint, useposix=$useposix, d_sigaction=$d_sigaction
    useithreads=$useithreads, usemultiplicity=$usemultiplicity
    useperlio=$useperlio, d_sfio=$d_sfio, uselargefiles=$uselargefiles, usesocks=$usesocks
    use64bitint=$use64bitint, use64bitall=$use64bitall, uselongdouble=$uselongdouble
    usemymalloc=$usemymalloc, bincompat5005=undef
  Compiler:
    cc='$cc', ccflags ='$ccflags',
    optimize='$optimize',
    cppflags='$cppflags'
    ccversion='$ccversion', gccversion='$gccversion', gccosandvers='$gccosandvers'
    intsize=$intsize, longsize=$longsize, ptrsize=$ptrsize, doublesize=$doublesize, byteorder=$byteorder
    d_longlong=$d_longlong, longlongsize=$longlongsize, d_longdbl=$d_longdbl, longdblsize=$longdblsize
    ivtype='$ivtype', ivsize=$ivsize, nvtype='$nvtype', nvsize=$nvsize, Off_t='$lseektype', lseeksize=$lseeksize
    alignbytes=$alignbytes, prototype=$prototype
  Linker and Libraries:
    ld='$ld', ldflags ='$ldflags'
    libpth=$libpth
    libs=$libs
    perllibs=$perllibs
    libc=$libc, so=$so, useshrplib=$useshrplib, libperl=$libperl
    gnulibc_version='$gnulibc_version'
  Dynamic Linking:
    dlsrc=$dlsrc, dlext=$dlext, d_dlsymun=$d_dlsymun, ccdlflags='$ccdlflags'
    cccdlflags='$cccdlflags', lddlflags='$lddlflags'

!END!
my $summary_expanded;

sub myconfig {
    return $summary_expanded if $summary_expanded;
    ($summary_expanded = $summary) =~ s{\$(\w+)}
		 { 
			my $c;
			if ($1 eq 'git_ancestor_line') {
				if ($Config::Config{git_ancestor}) {
					$c= "\n  Ancestor: $Config::Config{git_ancestor}";
				} else {
					$c= "";
				}
			} else {
                     		$c = $Config::Config{$1}; 
			}
			defined($c) ? $c : 'undef' 
		}ge;
    $summary_expanded;
}

local *_ = \my $a;
$_ = <<'!END!';
Author=''
CONFIG='true'
Date='$Date'
Header=''
Id='$Id'
Locker=''
Log='$Log'
PATCHLEVEL='14'
PERL_API_REVISION='5'
PERL_API_SUBVERSION='0'
PERL_API_VERSION='14'
PERL_CONFIG_SH='true'
PERL_PATCHLEVEL=''
PERL_REVISION='5'
PERL_SUBVERSION='2'
PERL_VERSION='14'
RCSfile='$RCSfile'
Revision='$Revision'
SUBVERSION='2'
Source=''
State=''
_a='.a'
_exe=''
_o='.o'
afs='false'
afsroot='/afs'
alignbytes='8'
ansi2knr=''
aphostname='/bin/hostname'
api_revision='5'
api_subversion='0'
api_version='14'
api_versionstring='5.14.0'
ar='ar'
archlib='/usr/lib/perl/5.14'
archlibexp='/usr/lib/perl/5.14'
archname64=''
archname='x86_64-linux-gnu-thread-multi'
archobjs=''
asctime_r_proto='REENTRANT_PROTO_B_SB'
awk='awk'
baserev='5.0'
bash=''
bin='/usr/bin'
bin_ELF='define'
binexp='/usr/bin'
bison='bison'
byacc='byacc'
byteorder='12345678'
c=''
castflags='0'
cat='cat'
cc='cc'
cccdlflags='-fPIC'
ccdlflags='-Wl,-E'
ccflags='-D_REENTRANT -D_GNU_SOURCE -DDEBIAN -fno-strict-aliasing -pipe -fstack-protector -I/usr/local/include -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64'
ccflags_uselargefiles='-D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64'
ccname='gcc'
ccsymbols=''
ccversion=''
cf_by='Debian Project'
cf_email='perl@packages.debian.org'
cf_time='Mon Mar 18 19:16:26 UTC 2013'
charbits='8'
charsize='1'
chgrp=''
chmod='chmod'
chown=''
clocktype='clock_t'
comm='comm'
compress=''
config_arg0='Configure'
config_arg10='-Dvendorlib=/usr/share/perl5'
config_arg11='-Dvendorarch=/usr/lib/perl5'
config_arg12='-Dsiteprefix=/usr/local'
config_arg13='-Dsitelib=/usr/local/share/perl/5.14.2'
config_arg14='-Dsitearch=/usr/local/lib/perl/5.14.2'
config_arg15='-Dman1dir=/usr/share/man/man1'
config_arg16='-Dman3dir=/usr/share/man/man3'
config_arg17='-Dsiteman1dir=/usr/local/man/man1'
config_arg18='-Dsiteman3dir=/usr/local/man/man3'
config_arg19='-Duse64bitint'
config_arg1='-Dusethreads'
config_arg20='-Dman1ext=1'
config_arg21='-Dman3ext=3perl'
config_arg22='-Dpager=/usr/bin/sensible-pager'
config_arg23='-Uafs'
config_arg24='-Ud_csh'
config_arg25='-Ud_ualarm'
config_arg26='-Uusesfio'
config_arg27='-Uusenm'
config_arg28='-Ui_libutil'
config_arg29='-DDEBUGGING=-g'
config_arg2='-Duselargefiles'
config_arg30='-Doptimize=-O2'
config_arg31='-Duseshrplib'
config_arg32='-Dlibperl=libperl.so.5.14.2'
config_arg33='-des'
config_arg3='-Dccflags=-DDEBIAN'
config_arg4='-Dcccdlflags=-fPIC'
config_arg5='-Darchname=x86_64-linux-gnu'
config_arg6='-Dprefix=/usr'
config_arg7='-Dprivlib=/usr/share/perl/5.14'
config_arg8='-Darchlib=/usr/lib/perl/5.14'
config_arg9='-Dvendorprefix=/usr'
config_argc='33'
config_args='-Dusethreads -Duselargefiles -Dccflags=-DDEBIAN -Dcccdlflags=-fPIC -Darchname=x86_64-linux-gnu -Dprefix=/usr -Dprivlib=/usr/share/perl/5.14 -Darchlib=/usr/lib/perl/5.14 -Dvendorprefix=/usr -Dvendorlib=/usr/share/perl5 -Dvendorarch=/usr/lib/perl5 -Dsiteprefix=/usr/local -Dsitelib=/usr/local/share/perl/5.14.2 -Dsitearch=/usr/local/lib/perl/5.14.2 -Dman1dir=/usr/share/man/man1 -Dman3dir=/usr/share/man/man3 -Dsiteman1dir=/usr/local/man/man1 -Dsiteman3dir=/usr/local/man/man3 -Duse64bitint -Dman1ext=1 -Dman3ext=3perl -Dpager=/usr/bin/sensible-pager -Uafs -Ud_csh -Ud_ualarm -Uusesfio -Uusenm -Ui_libutil -DDEBUGGING=-g -Doptimize=-O2 -Duseshrplib -Dlibperl=libperl.so.5.14.2 -des'
contains='grep'
cp='cp'
cpio=''
cpp='cpp'
cpp_stuff='42'
cppccsymbols=''
cppflags='-D_REENTRANT -D_GNU_SOURCE -DDEBIAN -fno-strict-aliasing -pipe -fstack-protector -I/usr/local/include'
cpplast='-'
cppminus='-'
cpprun='cc -E'
cppstdin='cc -E'
cppsymbols='_FILE_OFFSET_BITS=64 _FORTIFY_SOURCE=2 _GNU_SOURCE=1 _LARGEFILE64_SOURCE=1 _LARGEFILE_SOURCE=1 _LP64=1 _POSIX_C_SOURCE=200809L _POSIX_SOURCE=1 _REENTRANT=1 _XOPEN_SOURCE=700 _XOPEN_SOURCE_EXTENDED=1 __BIGGEST_ALIGNMENT__=16 __BYTE_ORDER__=1234 __CHAR16_TYPE__=short\ unsigned\ int __CHAR32_TYPE__=unsigned\ int __CHAR_BIT__=8 __DBL_DECIMAL_DIG__=17 __DBL_DENORM_MIN__=((double)4.94065645841246544177e-324L) __DBL_DIG__=15 __DBL_EPSILON__=((double)2.22044604925031308085e-16L) __DBL_HAS_DENORM__=1 __DBL_HAS_INFINITY__=1 __DBL_HAS_QUIET_NAN__=1 __DBL_MANT_DIG__=53 __DBL_MAX_10_EXP__=308 __DBL_MAX_EXP__=1024 __DBL_MAX__=((double)1.79769313486231570815e+308L) __DBL_MIN_10_EXP__=(-307) __DBL_MIN_EXP__=(-1021) __DBL_MIN__=((double)2.22507385850720138309e-308L) __DEC128_EPSILON__=1E-33DL __DEC128_MANT_DIG__=34 __DEC128_MAX_EXP__=6145 __DEC128_MAX__=9.999999999999999999999999999999999E6144DL __DEC128_MIN_EXP__=(-6142) __DEC128_MIN__=1E-6143DL __DEC128_SUBNORMAL_MIN__=0.000000000000000000000000000000001E-6143DL __DEC32_EPSILON__=1E-6DF __DEC32_MANT_DIG__=7 __DEC32_MAX_EXP__=97 __DEC32_MAX__=9.999999E96DF __DEC32_MIN_EXP__=(-94) __DEC32_MIN__=1E-95DF __DEC32_SUBNORMAL_MIN__=0.000001E-95DF __DEC64_EPSILON__=1E-15DD __DEC64_MANT_DIG__=16 __DEC64_MAX_EXP__=385 __DEC64_MAX__=9.999999999999999E384DD __DEC64_MIN_EXP__=(-382) __DEC64_MIN__=1E-383DD __DEC64_SUBNORMAL_MIN__=0.000000000000001E-383DD __DECIMAL_BID_FORMAT__=1 __DECIMAL_DIG__=21 __DEC_EVAL_METHOD__=2 __ELF__=1 __FINITE_MATH_ONLY__=0 __FLOAT_WORD_ORDER__=1234 __FLT_DECIMAL_DIG__=9 __FLT_DENORM_MIN__=1.40129846432481707092e-45F __FLT_DIG__=6 __FLT_EPSILON__=1.19209289550781250000e-7F __FLT_EVAL_METHOD__=0 __FLT_HAS_DENORM__=1 __FLT_HAS_INFINITY__=1 __FLT_HAS_QUIET_NAN__=1 __FLT_MANT_DIG__=24 __FLT_MAX_10_EXP__=38 __FLT_MAX_EXP__=128 __FLT_MAX__=3.40282346638528859812e+38F __FLT_MIN_10_EXP__=(-37) __FLT_MIN_EXP__=(-125) __FLT_MIN__=1.17549435082228750797e-38F __FLT_RADIX__=2 __GCC_HAVE_DWARF2_CFI_ASM=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_1=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_2=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_4=1 __GCC_HAVE_SYNC_COMPARE_AND_SWAP_8=1 __GLIBC_MINOR__=15 __GLIBC__=2 __GNUC_GNU_INLINE__=1 __GNUC_MINOR__=6 __GNUC_PATCHLEVEL__=3 __GNUC__=4 __GNU_LIBRARY__=6 __GXX_ABI_VERSION=1002 __INT16_C(c)=c __INT16_MAX__=32767 __INT16_TYPE__=short\ int __INT32_C(c)=c __INT32_MAX__=2147483647 __INT32_TYPE__=int __INT64_C(c)=cL __INT64_MAX__=9223372036854775807L __INT64_TYPE__=long\ int __INT8_C(c)=c __INT8_MAX__=127 __INT8_TYPE__=signed\ char __INTMAX_C(c)=cL __INTMAX_MAX__=9223372036854775807L __INTMAX_TYPE__=long\ int __INTPTR_MAX__=9223372036854775807L __INTPTR_TYPE__=long\ int __INT_FAST16_MAX__=9223372036854775807L __INT_FAST16_TYPE__=long\ int __INT_FAST32_MAX__=9223372036854775807L __INT_FAST32_TYPE__=long\ int __INT_FAST64_MAX__=9223372036854775807L __INT_FAST64_TYPE__=long\ int __INT_FAST8_MAX__=127 __INT_FAST8_TYPE__=signed\ char __INT_LEAST16_MAX__=32767 __INT_LEAST16_TYPE__=short\ int __INT_LEAST32_MAX__=2147483647 __INT_LEAST32_TYPE__=int __INT_LEAST64_MAX__=9223372036854775807L __INT_LEAST64_TYPE__=long\ int __INT_LEAST8_MAX__=127 __INT_LEAST8_TYPE__=signed\ char __INT_MAX__=2147483647 __LDBL_DENORM_MIN__=3.64519953188247460253e-4951L __LDBL_DIG__=18 __LDBL_EPSILON__=1.08420217248550443401e-19L __LDBL_HAS_DENORM__=1 __LDBL_HAS_INFINITY__=1 __LDBL_HAS_QUIET_NAN__=1 __LDBL_MANT_DIG__=64 __LDBL_MAX_10_EXP__=4932 __LDBL_MAX_EXP__=16384 __LDBL_MAX__=1.18973149535723176502e+4932L __LDBL_MIN_10_EXP__=(-4931) __LDBL_MIN_EXP__=(-16381) __LDBL_MIN__=3.36210314311209350626e-4932L __LONG_LONG_MAX__=9223372036854775807LL __LONG_MAX__=9223372036854775807L __LP64__=1 __MMX__=1 __ORDER_BIG_ENDIAN__=4321 __ORDER_LITTLE_ENDIAN__=1234 __ORDER_PDP_ENDIAN__=3412 __PRAGMA_REDEFINE_EXTNAME=1 __PTRDIFF_MAX__=9223372036854775807L __PTRDIFF_TYPE__=long\ int __REGISTER_PREFIX__= __SCHAR_MAX__=127 __SHRT_MAX__=32767 __SIG_ATOMIC_MAX__=2147483647 __SIG_ATOMIC_MIN__=(-2147483647\ -\ 1) __SIG_ATOMIC_TYPE__=int __SIZEOF_DOUBLE__=8 __SIZEOF_FLOAT__=4 __SIZEOF_INT128__=16 __SIZEOF_INT__=4 __SIZEOF_LONG_DOUBLE__=16 __SIZEOF_LONG_LONG__=8 __SIZEOF_LONG__=8 __SIZEOF_POINTER__=8 __SIZEOF_PTRDIFF_T__=8 __SIZEOF_SHORT__=2 __SIZEOF_SIZE_T__=8 __SIZEOF_WCHAR_T__=4 __SIZEOF_WINT_T__=4 __SIZE_MAX__=18446744073709551615UL __SIZE_TYPE__=long\ unsigned\ int __SSE2_MATH__=1 __SSE2__=1 __SSE_MATH__=1 __SSE__=1 __SSP__=1 __STDC_HOSTED__=1 __STDC__=1 __UINT16_C(c)=c __UINT16_MAX__=65535 __UINT16_TYPE__=short\ unsigned\ int __UINT32_C(c)=cU __UINT32_MAX__=4294967295U __UINT32_TYPE__=unsigned\ int __UINT64_C(c)=cUL __UINT64_MAX__=18446744073709551615UL __UINT64_TYPE__=long\ unsigned\ int __UINT8_C(c)=c __UINT8_MAX__=255 __UINT8_TYPE__=unsigned\ char __UINTMAX_C(c)=cUL __UINTMAX_MAX__=18446744073709551615UL __UINTMAX_TYPE__=long\ unsigned\ int __UINTPTR_MAX__=18446744073709551615UL __UINTPTR_TYPE__=long\ unsigned\ int __UINT_FAST16_MAX__=18446744073709551615UL __UINT_FAST16_TYPE__=long\ unsigned\ int __UINT_FAST32_MAX__=18446744073709551615UL __UINT_FAST32_TYPE__=long\ unsigned\ int __UINT_FAST64_MAX__=18446744073709551615UL __UINT_FAST64_TYPE__=long\ unsigned\ int __UINT_FAST8_MAX__=255 __UINT_FAST8_TYPE__=unsigned\ char __UINT_LEAST16_MAX__=65535 __UINT_LEAST16_TYPE__=short\ unsigned\ int __UINT_LEAST32_MAX__=4294967295U __UINT_LEAST32_TYPE__=unsigned\ int __UINT_LEAST64_MAX__=18446744073709551615UL __UINT_LEAST64_TYPE__=long\ unsigned\ int __UINT_LEAST8_MAX__=255 __UINT_LEAST8_TYPE__=unsigned\ char __USER_LABEL_PREFIX__= __USE_BSD=1 __USE_FILE_OFFSET64=1 __USE_GNU=1 __USE_LARGEFILE64=1 __USE_LARGEFILE=1 __USE_MISC=1 __USE_POSIX199309=1 __USE_POSIX199506=1 __USE_POSIX2=1 __USE_POSIX=1 __USE_REENTRANT=1 __USE_SVID=1 __USE_UNIX98=1 __USE_XOPEN=1 __USE_XOPEN_EXTENDED=1 __VERSION__="4.6.3" __WCHAR_MAX__=2147483647 __WCHAR_MIN__=(-2147483647\ -\ 1) __WCHAR_TYPE__=int __WINT_MAX__=4294967295U __WINT_MIN__=0U __WINT_TYPE__=unsigned\ int __amd64=1 __amd64__=1 __gnu_linux__=1 __k8=1 __k8__=1 __linux=1 __linux__=1 __unix=1 __unix__=1 __x86_64=1 __x86_64__=1 linux=1 unix=1'
crypt_r_proto='REENTRANT_PROTO_B_CCS'
cryptlib=''
csh='csh'
ctermid_r_proto='0'
ctime_r_proto='REENTRANT_PROTO_B_SB'
d_Gconvert='gcvt((x),(n),(b))'
d_PRIEUldbl='define'
d_PRIFUldbl='define'
d_PRIGUldbl='define'
d_PRIXU64='define'
d_PRId64='define'
d_PRIeldbl='define'
d_PRIfldbl='define'
d_PRIgldbl='define'
d_PRIi64='define'
d_PRIo64='define'
d_PRIu64='define'
d_PRIx64='define'
d_SCNfldbl='define'
d__fwalk='undef'
d_access='define'
d_accessx='undef'
d_aintl='undef'
d_alarm='define'
d_archlib='define'
d_asctime64='undef'
d_asctime_r='define'
d_atolf='undef'
d_atoll='define'
d_attribute_deprecated='define'
d_attribute_format='define'
d_attribute_malloc='define'
d_attribute_nonnull='define'
d_attribute_noreturn='define'
d_attribute_pure='define'
d_attribute_unused='define'
d_attribute_warn_unused_result='define'
d_bcmp='define'
d_bcopy='define'
d_bsd='undef'
d_bsdgetpgrp='undef'
d_bsdsetpgrp='undef'
d_builtin_choose_expr='define'
d_builtin_expect='define'
d_bzero='define'
d_c99_variadic_macros='define'
d_casti32='undef'
d_castneg='define'
d_charvspr='undef'
d_chown='define'
d_chroot='define'
d_chsize='undef'
d_class='undef'
d_clearenv='define'
d_closedir='define'
d_cmsghdr_s='define'
d_const='define'
d_copysignl='define'
d_cplusplus='undef'
d_crypt='define'
d_crypt_r='define'
d_csh='undef'
d_ctermid='define'
d_ctermid_r='undef'
d_ctime64='undef'
d_ctime_r='define'
d_cuserid='define'
d_dbl_dig='define'
d_dbminitproto='define'
d_difftime64='undef'
d_difftime='define'
d_dir_dd_fd='undef'
d_dirfd='define'
d_dirnamlen='undef'
d_dlerror='define'
d_dlopen='define'
d_dlsymun='undef'
d_dosuid='undef'
d_drand48_r='define'
d_drand48proto='define'
d_dup2='define'
d_eaccess='define'
d_endgrent='define'
d_endgrent_r='undef'
d_endhent='define'
d_endhostent_r='undef'
d_endnent='define'
d_endnetent_r='undef'
d_endpent='define'
d_endprotoent_r='undef'
d_endpwent='define'
d_endpwent_r='undef'
d_endsent='define'
d_endservent_r='undef'
d_eofnblk='define'
d_eunice='undef'
d_faststdio='define'
d_fchdir='define'
d_fchmod='define'
d_fchown='define'
d_fcntl='define'
d_fcntl_can_lock='define'
d_fd_macros='define'
d_fd_set='define'
d_fds_bits='define'
d_fgetpos='define'
d_finite='define'
d_finitel='define'
d_flexfnam='define'
d_flock='define'
d_flockproto='define'
d_fork='define'
d_fp_class='undef'
d_fpathconf='define'
d_fpclass='undef'
d_fpclassify='undef'
d_fpclassl='undef'
d_fpos64_t='undef'
d_frexpl='define'
d_fs_data_s='undef'
d_fseeko='define'
d_fsetpos='define'
d_fstatfs='define'
d_fstatvfs='define'
d_fsync='define'
d_ftello='define'
d_ftime='undef'
d_futimes='define'
d_gdbm_ndbm_h_uses_prototypes='undef'
d_gdbmndbm_h_uses_prototypes='undef'
d_getaddrinfo='define'
d_getcwd='define'
d_getespwnam='undef'
d_getfsstat='undef'
d_getgrent='define'
d_getgrent_r='define'
d_getgrgid_r='define'
d_getgrnam_r='define'
d_getgrps='define'
d_gethbyaddr='define'
d_gethbyname='define'
d_gethent='define'
d_gethname='define'
d_gethostbyaddr_r='define'
d_gethostbyname_r='define'
d_gethostent_r='define'
d_gethostprotos='define'
d_getitimer='define'
d_getlogin='define'
d_getlogin_r='define'
d_getmnt='undef'
d_getmntent='define'
d_getnameinfo='define'
d_getnbyaddr='define'
d_getnbyname='define'
d_getnent='define'
d_getnetbyaddr_r='define'
d_getnetbyname_r='define'
d_getnetent_r='define'
d_getnetprotos='define'
d_getpagsz='define'
d_getpbyname='define'
d_getpbynumber='define'
d_getpent='define'
d_getpgid='define'
d_getpgrp2='undef'
d_getpgrp='define'
d_getppid='define'
d_getprior='define'
d_getprotobyname_r='define'
d_getprotobynumber_r='define'
d_getprotoent_r='define'
d_getprotoprotos='define'
d_getprpwnam='undef'
d_getpwent='define'
d_getpwent_r='define'
d_getpwnam_r='define'
d_getpwuid_r='define'
d_getsbyname='define'
d_getsbyport='define'
d_getsent='define'
d_getservbyname_r='define'
d_getservbyport_r='define'
d_getservent_r='define'
d_getservprotos='define'
d_getspnam='define'
d_getspnam_r='define'
d_gettimeod='define'
d_gmtime64='undef'
d_gmtime_r='define'
d_gnulibc='define'
d_grpasswd='define'
d_hasmntopt='define'
d_htonl='define'
d_ilogbl='define'
d_inc_version_list='undef'
d_index='undef'
d_inetaton='define'
d_inetntop='define'
d_inetpton='define'
d_int64_t='define'
d_isascii='define'
d_isfinite='undef'
d_isinf='define'
d_isnan='define'
d_isnanl='define'
d_killpg='define'
d_lchown='define'
d_ldbl_dig='define'
d_libm_lib_version='define'
d_link='define'
d_localtime64='undef'
d_localtime_r='define'
d_localtime_r_needs_tzset='define'
d_locconv='define'
d_lockf='define'
d_longdbl='define'
d_longlong='define'
d_lseekproto='define'
d_lstat='define'
d_madvise='define'
d_malloc_good_size='undef'
d_malloc_size='undef'
d_mblen='define'
d_mbstowcs='define'
d_mbtowc='define'
d_memchr='define'
d_memcmp='define'
d_memcpy='define'
d_memmove='define'
d_memset='define'
d_mkdir='define'
d_mkdtemp='define'
d_mkfifo='define'
d_mkstemp='define'
d_mkstemps='define'
d_mktime64='undef'
d_mktime='define'
d_mmap='define'
d_modfl='define'
d_modfl_pow32_bug='undef'
d_modflproto='define'
d_mprotect='define'
d_msg='define'
d_msg_ctrunc='define'
d_msg_dontroute='define'
d_msg_oob='define'
d_msg_peek='define'
d_msg_proxy='define'
d_msgctl='define'
d_msgget='define'
d_msghdr_s='define'
d_msgrcv='define'
d_msgsnd='define'
d_msync='define'
d_munmap='define'
d_mymalloc='undef'
d_ndbm='define'
d_ndbm_h_uses_prototypes='undef'
d_nice='define'
d_nl_langinfo='define'
d_nv_preserves_uv='undef'
d_nv_zero_is_allbits_zero='define'
d_off64_t='define'
d_old_pthread_create_joinable='undef'
d_oldpthreads='undef'
d_oldsock='undef'
d_open3='define'
d_pathconf='define'
d_pause='define'
d_perl_otherlibdirs='undef'
d_phostname='undef'
d_pipe='define'
d_poll='define'
d_portable='define'
d_prctl='define'
d_prctl_set_name='define'
d_printf_format_null='undef'
d_procselfexe='define'
d_pseudofork='undef'
d_pthread_atfork='define'
d_pthread_attr_setscope='define'
d_pthread_yield='define'
d_pwage='undef'
d_pwchange='undef'
d_pwclass='undef'
d_pwcomment='undef'
d_pwexpire='undef'
d_pwgecos='define'
d_pwpasswd='define'
d_pwquota='undef'
d_qgcvt='define'
d_quad='define'
d_random_r='define'
d_readdir64_r='define'
d_readdir='define'
d_readdir_r='define'
d_readlink='define'
d_readv='define'
d_recvmsg='define'
d_rename='define'
d_rewinddir='define'
d_rmdir='define'
d_safebcpy='undef'
d_safemcpy='undef'
d_sanemcmp='define'
d_sbrkproto='define'
d_scalbnl='define'
d_sched_yield='define'
d_scm_rights='define'
d_seekdir='define'
d_select='define'
d_sem='define'
d_semctl='define'
d_semctl_semid_ds='define'
d_semctl_semun='define'
d_semget='define'
d_semop='define'
d_sendmsg='define'
d_setegid='define'
d_seteuid='define'
d_setgrent='define'
d_setgrent_r='undef'
d_setgrps='define'
d_sethent='define'
d_sethostent_r='undef'
d_setitimer='define'
d_setlinebuf='define'
d_setlocale='define'
d_setlocale_r='undef'
d_setnent='define'
d_setnetent_r='undef'
d_setpent='define'
d_setpgid='define'
d_setpgrp2='undef'
d_setpgrp='define'
d_setprior='define'
d_setproctitle='undef'
d_setprotoent_r='undef'
d_setpwent='define'
d_setpwent_r='undef'
d_setregid='define'
d_setresgid='define'
d_setresuid='define'
d_setreuid='define'
d_setrgid='undef'
d_setruid='undef'
d_setsent='define'
d_setservent_r='undef'
d_setsid='define'
d_setvbuf='define'
d_sfio='undef'
d_shm='define'
d_shmat='define'
d_shmatprototype='define'
d_shmctl='define'
d_shmdt='define'
d_shmget='define'
d_sigaction='define'
d_signbit='define'
d_sigprocmask='define'
d_sigsetjmp='define'
d_sin6_scope_id='define'
d_sitearch='define'
d_snprintf='define'
d_sockaddr_sa_len='undef'
d_sockatmark='define'
d_sockatmarkproto='define'
d_socket='define'
d_socklen_t='define'
d_sockpair='define'
d_socks5_init='undef'
d_sprintf_returns_strlen='define'
d_sqrtl='define'
d_srand48_r='define'
d_srandom_r='define'
d_sresgproto='define'
d_sresuproto='define'
d_statblks='define'
d_statfs_f_flags='define'
d_statfs_s='define'
d_static_inline='define'
d_statvfs='define'
d_stdio_cnt_lval='undef'
d_stdio_ptr_lval='define'
d_stdio_ptr_lval_nochange_cnt='undef'
d_stdio_ptr_lval_sets_cnt='define'
d_stdio_stream_array='undef'
d_stdiobase='define'
d_stdstdio='define'
d_strchr='define'
d_strcoll='define'
d_strctcpy='define'
d_strerrm='strerror(e)'
d_strerror='define'
d_strerror_r='define'
d_strftime='define'
d_strlcat='undef'
d_strlcpy='undef'
d_strtod='define'
d_strtol='define'
d_strtold='define'
d_strtoll='define'
d_strtoq='define'
d_strtoul='define'
d_strtoull='define'
d_strtouq='define'
d_strxfrm='define'
d_suidsafe='undef'
d_symlink='define'
d_syscall='define'
d_syscallproto='define'
d_sysconf='define'
d_sysernlst=''
d_syserrlst='define'
d_system='define'
d_tcgetpgrp='define'
d_tcsetpgrp='define'
d_telldir='define'
d_telldirproto='define'
d_time='define'
d_timegm='define'
d_times='define'
d_tm_tm_gmtoff='define'
d_tm_tm_zone='define'
d_tmpnam_r='define'
d_truncate='define'
d_ttyname_r='define'
d_tzname='define'
d_u32align='define'
d_ualarm='undef'
d_umask='define'
d_uname='define'
d_union_semun='undef'
d_unordered='undef'
d_unsetenv='define'
d_usleep='define'
d_usleepproto='define'
d_ustat='define'
d_vendorarch='define'
d_vendorbin='define'
d_vendorlib='define'
d_vendorscript='define'
d_vfork='undef'
d_void_closedir='undef'
d_voidsig='define'
d_voidtty=''
d_volatile='define'
d_vprintf='define'
d_vsnprintf='define'
d_wait4='define'
d_waitpid='define'
d_wcstombs='define'
d_wctomb='define'
d_writev='define'
d_xenix='undef'
date='date'
db_hashtype='u_int32_t'
db_prefixtype='size_t'
db_version_major='5'
db_version_minor='1'
db_version_patch='25'
defvoidused='15'
direntrytype='struct dirent'
dlext='so'
dlsrc='dl_dlopen.xs'
doublesize='8'
drand01='drand48()'
drand48_r_proto='REENTRANT_PROTO_I_ST'
dtrace=''
dynamic_ext='B Compress/Raw/Bzip2 Compress/Raw/Zlib Cwd DB_File Data/Dumper Devel/DProf Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA Encode Fcntl File/Glob Filter/Util/Call GDBM_File Hash/Util Hash/Util/FieldHash I18N/Langinfo IO IPC/SysV List/Util MIME/Base64 Math/BigInt/FastCalc NDBM_File ODBM_File Opcode POSIX PerlIO/encoding PerlIO/scalar PerlIO/via SDBM_File Socket Storable Sys/Hostname Sys/Syslog Text/Soundex Tie/Hash/NamedCapture Time/HiRes Time/Piece Unicode/Collate Unicode/Normalize XS/APItest XS/Typemap attributes mro re threads threads/shared'
eagain='EAGAIN'
ebcdic='undef'
echo='echo'
egrep='egrep'
emacs=''
endgrent_r_proto='0'
endhostent_r_proto='0'
endnetent_r_proto='0'
endprotoent_r_proto='0'
endpwent_r_proto='0'
endservent_r_proto='0'
eunicefix=':'
exe_ext=''
expr='expr'
extensions='B Compress/Raw/Bzip2 Compress/Raw/Zlib Cwd DB_File Data/Dumper Devel/DProf Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA Encode Fcntl File/Glob Filter/Util/Call GDBM_File Hash/Util Hash/Util/FieldHash I18N/Langinfo IO IPC/SysV List/Util MIME/Base64 Math/BigInt/FastCalc NDBM_File ODBM_File Opcode POSIX PerlIO/encoding PerlIO/scalar PerlIO/via SDBM_File Socket Storable Sys/Hostname Sys/Syslog Text/Soundex Tie/Hash/NamedCapture Time/HiRes Time/Piece Unicode/Collate Unicode/Normalize XS/APItest XS/Typemap attributes mro re threads threads/shared Archive/Extract Archive/Tar Attribute/Handlers AutoLoader B/Debug B/Deparse B/Lint CGI CPAN CPAN/Meta CPAN/Meta/YAML CPANPLUS CPANPLUS/Dist/Build Devel/SelfStubber Digest Dumpvalue Env Errno ExtUtils/CBuilder ExtUtils/Command ExtUtils/Constant ExtUtils/Install ExtUtils/MakeMaker ExtUtils/Manifest ExtUtils/ParseXS File/CheckTree File/Fetch File/Path File/Temp FileCache Filter/Simple Getopt/Long HTTP/Tiny I18N/Collate I18N/LangTags IO/Compress IO/Zlib IPC/Cmd IPC/Open2 IPC/Open3 JSON/PP Locale/Codes Locale/Maketext Locale/Maketext/Simple Log/Message Log/Message/Simple Math/BigInt Math/BigRat Math/Complex Memoize Module/Build Module/CoreList Module/Load Module/Load/Conditional Module/Loaded Module/Metadata Module/Pluggable NEXT Net/Ping Object/Accessor Package/Constants Params/Check Parse/CPAN/Meta Perl/OSType PerlIO/via/QuotedPrint Pod/Escapes Pod/Html Pod/LaTeX Pod/Parser Pod/Perldoc Pod/Simple Safe SelfLoader Shell Term/ANSIColor Term/Cap Term/UI Test Test/Harness Test/Simple Text/Balanced Text/ParseWords Text/Tabs Thread/Queue Thread/Semaphore Tie/File Tie/Memoize Tie/RefHash Time/Local Version/Requirements XSLoader autodie autouse base bignum constant encoding/warnings if lib libnet parent podlators'
extern_C='extern'
extras=''
fflushNULL='define'
fflushall='undef'
find=''
firstmakefile='makefile'
flex=''
fpossize='16'
fpostype='fpos_t'
freetype='void'
from=':'
full_ar='/usr/bin/ar'
full_csh='csh'
full_sed='/bin/sed'
gccansipedantic=''
gccosandvers=''
gccversion='4.6.3'
getgrent_r_proto='REENTRANT_PROTO_I_SBWR'
getgrgid_r_proto='REENTRANT_PROTO_I_TSBWR'
getgrnam_r_proto='REENTRANT_PROTO_I_CSBWR'
gethostbyaddr_r_proto='REENTRANT_PROTO_I_TsISBWRE'
gethostbyname_r_proto='REENTRANT_PROTO_I_CSBWRE'
gethostent_r_proto='REENTRANT_PROTO_I_SBWRE'
getlogin_r_proto='REENTRANT_PROTO_I_BW'
getnetbyaddr_r_proto='REENTRANT_PROTO_I_uISBWRE'
getnetbyname_r_proto='REENTRANT_PROTO_I_CSBWRE'
getnetent_r_proto='REENTRANT_PROTO_I_SBWRE'
getprotobyname_r_proto='REENTRANT_PROTO_I_CSBWR'
getprotobynumber_r_proto='REENTRANT_PROTO_I_ISBWR'
getprotoent_r_proto='REENTRANT_PROTO_I_SBWR'
getpwent_r_proto='REENTRANT_PROTO_I_SBWR'
getpwnam_r_proto='REENTRANT_PROTO_I_CSBWR'
getpwuid_r_proto='REENTRANT_PROTO_I_TSBWR'
getservbyname_r_proto='REENTRANT_PROTO_I_CCSBWR'
getservbyport_r_proto='REENTRANT_PROTO_I_ICSBWR'
getservent_r_proto='REENTRANT_PROTO_I_SBWR'
getspnam_r_proto='REENTRANT_PROTO_I_CSBWR'
gidformat='"u"'
gidsign='1'
gidsize='4'
gidtype='gid_t'
glibpth='/usr/shlib  /lib /usr/lib /usr/lib/386 /lib/386 /usr/ccs/lib /usr/ucblib /usr/local/lib '
gmake='gmake'
gmtime_r_proto='REENTRANT_PROTO_S_TS'
gnulibc_version='2.15'
grep='grep'
groupcat='cat /etc/group'
groupstype='gid_t'
gzip='gzip'
h_fcntl='false'
h_sysfile='true'
hint='recommended'
hostcat='cat /etc/hosts'
html1dir=' '
html1direxp=''
html3dir=' '
html3direxp=''
i16size='2'
i16type='short'
i32size='4'
i32type='int'
i64size='8'
i64type='long'
i8size='1'
i8type='signed char'
i_arpainet='define'
i_assert='define'
i_bsdioctl=''
i_crypt='define'
i_db='define'
i_dbm='define'
i_dirent='define'
i_dld='undef'
i_dlfcn='define'
i_fcntl='undef'
i_float='define'
i_fp='undef'
i_fp_class='undef'
i_gdbm='define'
i_gdbm_ndbm='define'
i_gdbmndbm='undef'
i_grp='define'
i_ieeefp='undef'
i_inttypes='define'
i_langinfo='define'
i_libutil='undef'
i_limits='define'
i_locale='define'
i_machcthr='undef'
i_malloc='define'
i_mallocmalloc='undef'
i_math='define'
i_memory='undef'
i_mntent='define'
i_ndbm='undef'
i_netdb='define'
i_neterrno='undef'
i_netinettcp='define'
i_niin='define'
i_poll='define'
i_prot='undef'
i_pthread='define'
i_pwd='define'
i_rpcsvcdbm='undef'
i_sfio='undef'
i_sgtty='undef'
i_shadow='define'
i_socks='undef'
i_stdarg='define'
i_stddef='define'
i_stdlib='define'
i_string='define'
i_sunmath='undef'
i_sysaccess='undef'
i_sysdir='define'
i_sysfile='define'
i_sysfilio='undef'
i_sysin='undef'
i_sysioctl='define'
i_syslog='define'
i_sysmman='define'
i_sysmode='undef'
i_sysmount='define'
i_sysndir='undef'
i_sysparam='define'
i_syspoll='define'
i_sysresrc='define'
i_syssecrt='undef'
i_sysselct='define'
i_syssockio='undef'
i_sysstat='define'
i_sysstatfs='define'
i_sysstatvfs='define'
i_systime='define'
i_systimek='undef'
i_systimes='define'
i_systypes='define'
i_sysuio='define'
i_sysun='define'
i_sysutsname='define'
i_sysvfs='define'
i_syswait='define'
i_termio='undef'
i_termios='define'
i_time='define'
i_unistd='define'
i_ustat='define'
i_utime='define'
i_values='define'
i_varargs='undef'
i_varhdr='stdarg.h'
i_vfork='undef'
ignore_versioned_solibs='y'
inc_version_list=''
inc_version_list_init='0'
incpath=''
inews=''
initialinstalllocation='/usr/bin'
installarchlib='/usr/lib/perl/5.14'
installbin='/usr/bin'
installhtml1dir=''
installhtml3dir=''
installman1dir='/usr/share/man/man1'
installman3dir='/usr/share/man/man3'
installprefix='/usr'
installprefixexp='/usr'
installprivlib='/usr/share/perl/5.14'
installscript='/usr/bin'
installsitearch='/usr/local/lib/perl/5.14.2'
installsitebin='/usr/local/bin'
installsitehtml1dir=''
installsitehtml3dir=''
installsitelib='/usr/local/share/perl/5.14.2'
installsiteman1dir='/usr/local/man/man1'
installsiteman3dir='/usr/local/man/man3'
installsitescript='/usr/local/bin'
installstyle='lib/perl5'
installusrbinperl='undef'
installvendorarch='/usr/lib/perl5'
installvendorbin='/usr/bin'
installvendorhtml1dir=''
installvendorhtml3dir=''
installvendorlib='/usr/share/perl5'
installvendorman1dir='/usr/share/man/man1'
installvendorman3dir='/usr/share/man/man3'
installvendorscript='/usr/bin'
intsize='4'
issymlink='test -h'
ivdformat='"ld"'
ivsize='8'
ivtype='long'
known_extensions='B Compress/Raw/Bzip2 Compress/Raw/Zlib Cwd DB_File Data/Dumper Devel/DProf Devel/PPPort Devel/Peek Digest/MD5 Digest/SHA Encode Fcntl File/Glob Filter/Util/Call GDBM_File Hash/Util Hash/Util/FieldHash I18N/Langinfo IO IPC/SysV List/Util MIME/Base64 Math/BigInt/FastCalc NDBM_File ODBM_File Opcode POSIX PerlIO/encoding PerlIO/scalar PerlIO/via SDBM_File Socket Storable Sys/Hostname Sys/Syslog Text/Soundex Tie/Hash/NamedCapture Time/HiRes Time/Piece Unicode/Collate Unicode/Normalize VMS/DCLsym VMS/Stdio Win32 Win32API/File Win32CORE XS/APItest XS/Typemap attributes mro re threads threads/shared '
ksh=''
ld='cc'
lddlflags='-shared -O2 -g -L/usr/local/lib -fstack-protector'
ldflags=' -fstack-protector -L/usr/local/lib'
ldflags_uselargefiles=''
ldlibpthname='LD_LIBRARY_PATH'
less='less'
lib_ext='.a'
libc=''
libdb_needs_pthread='N'
libperl='libperl.so.5.14.2'
libpth='/usr/local/lib /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib /usr/lib'
libs='-lgdbm -lgdbm_compat -ldb -ldl -lm -lpthread -lc -lcrypt'
libsdirs=' /usr/lib/x86_64-linux-gnu'
libsfiles=' libgdbm.so libgdbm_compat.so libdb.so libdl.so libm.so libpthread.so libc.so libcrypt.so'
libsfound=' /usr/lib/x86_64-linux-gnu/libgdbm.so /usr/lib/x86_64-linux-gnu/libgdbm_compat.so /usr/lib/x86_64-linux-gnu/libdb.so /usr/lib/x86_64-linux-gnu/libdl.so /usr/lib/x86_64-linux-gnu/libm.so /usr/lib/x86_64-linux-gnu/libpthread.so /usr/lib/x86_64-linux-gnu/libc.so /usr/lib/x86_64-linux-gnu/libcrypt.so'
libspath=' /usr/local/lib /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib /usr/lib'
libswanted='gdbm gdbm_compat db dl m pthread c crypt gdbm_compat'
libswanted_uselargefiles=''
line=''
lint=''
lkflags=''
ln='ln'
lns='/bin/ln -s'
localtime_r_proto='REENTRANT_PROTO_S_TS'
locincpth='/usr/local/include /opt/local/include /usr/gnu/include /opt/gnu/include /usr/GNU/include /opt/GNU/include'
loclibpth='/usr/local/lib /opt/local/lib /usr/gnu/lib /opt/gnu/lib /usr/GNU/lib /opt/GNU/lib'
longdblsize='16'
longlongsize='8'
longsize='8'
lp=''
lpr=''
ls='ls'
lseeksize='8'
lseektype='off_t'
mad='undef'
madlyh=''
madlyobj=''
madlysrc=''
mail=''
mailx=''
make='make'
make_set_make='#'
mallocobj=''
mallocsrc=''
malloctype='void *'
man1dir='/usr/share/man/man1'
man1direxp='/usr/share/man/man1'
man1ext='1p'
man3dir='/usr/share/man/man3'
man3direxp='/usr/share/man/man3'
man3ext='3pm'
mips_type=''
mistrustnm=''
mkdir='mkdir'
mmaptype='void *'
modetype='mode_t'
more='more'
multiarch='undef'
mv=''
myarchname='x86_64-linux'
mydomain=''
myhostname='localhost'
myuname='linux batsu 2.6.42-37-generic #58-ubuntu smp thu jan 24 15:28:10 utc 2013 x86_64 x86_64 x86_64 gnulinux '
n='-n'
need_va_copy='define'
netdb_hlen_type='size_t'
netdb_host_type='char *'
netdb_name_type='const char *'
netdb_net_type='in_addr_t'
nm='nm'
nm_opt=''
nm_so_opt='--dynamic'
nonxs_ext='Archive/Extract Archive/Tar Attribute/Handlers AutoLoader B/Debug B/Deparse B/Lint CGI CPAN CPAN/Meta CPAN/Meta/YAML CPANPLUS CPANPLUS/Dist/Build Devel/SelfStubber Digest Dumpvalue Env Errno ExtUtils/CBuilder ExtUtils/Command ExtUtils/Constant ExtUtils/Install ExtUtils/MakeMaker ExtUtils/Manifest ExtUtils/ParseXS File/CheckTree File/Fetch File/Path File/Temp FileCache Filter/Simple Getopt/Long HTTP/Tiny I18N/Collate I18N/LangTags IO/Compress IO/Zlib IPC/Cmd IPC/Open2 IPC/Open3 JSON/PP Locale/Codes Locale/Maketext Locale/Maketext/Simple Log/Message Log/Message/Simple Math/BigInt Math/BigRat Math/Complex Memoize Module/Build Module/CoreList Module/Load Module/Load/Conditional Module/Loaded Module/Metadata Module/Pluggable NEXT Net/Ping Object/Accessor Package/Constants Params/Check Parse/CPAN/Meta Perl/OSType PerlIO/via/QuotedPrint Pod/Escapes Pod/Html Pod/LaTeX Pod/Parser Pod/Perldoc Pod/Simple Safe SelfLoader Shell Term/ANSIColor Term/Cap Term/UI Test Test/Harness Test/Simple Text/Balanced Text/ParseWords Text/Tabs Thread/Queue Thread/Semaphore Tie/File Tie/Memoize Tie/RefHash Time/Local Version/Requirements XSLoader autodie autouse base bignum constant encoding/warnings if lib libnet parent podlators'
nroff='nroff'
nvEUformat='"E"'
nvFUformat='"F"'
nvGUformat='"G"'
nv_overflows_integers_at='256.0*256.0*256.0*256.0*256.0*256.0*2.0*2.0*2.0*2.0*2.0'
nv_preserves_uv_bits='53'
nveformat='"e"'
nvfformat='"f"'
nvgformat='"g"'
nvsize='8'
nvtype='double'
o_nonblock='O_NONBLOCK'
obj_ext='.o'
old_pthread_create_joinable=''
optimize='-O2 -g'
orderlib='false'
osname='linux'
osvers='2.6.42-37-generic'
otherlibdirs=' '
package='perl5'
pager='/usr/bin/sensible-pager'
passcat='cat /etc/passwd'
patchlevel='14'
path_sep=':'
perl5='/usr/bin/perl'
perl='perl'
perl_patchlevel=''
perl_static_inline='static __inline__'
perladmin='root@localhost'
perllibs='-ldl -lm -lpthread -lc -lcrypt'
perlpath='/usr/bin/perl'
pg='pg'
phostname='hostname'
pidtype='pid_t'
plibpth='/lib/x86_64-linux-gnu/4.6 /lib/x86_64-linux-gnu /lib/../lib /usr/lib/x86_64-linux-gnu/4.6 /usr/lib/x86_64-linux-gnu /usr/lib/../lib /lib /usr/lib'
pmake=''
pr=''
prefix='/usr'
prefixexp='/usr'
privlib='/usr/share/perl/5.14'
privlibexp='/usr/share/perl/5.14'
procselfexe='"/proc/self/exe"'
prototype='define'
ptrsize='8'
quadkind='2'
quadtype='long'
randbits='48'
randfunc='drand48'
random_r_proto='REENTRANT_PROTO_I_St'
randseedtype='long'
ranlib=':'
rd_nodata='-1'
readdir64_r_proto='REENTRANT_PROTO_I_TSR'
readdir_r_proto='REENTRANT_PROTO_I_TSR'
revision='5'
rm='rm'
rm_try='/bin/rm -f try try a.out .out try.[cho] try..o core core.try* try.core*'
rmail=''
run=''
runnm='false'
sGMTIME_max='67768036191676799'
sGMTIME_min='-62167219200'
sLOCALTIME_max='67768036191676799'
sLOCALTIME_min='-62167219200'
sPRIEUldbl='"LE"'
sPRIFUldbl='"LF"'
sPRIGUldbl='"LG"'
sPRIXU64='"lX"'
sPRId64='"ld"'
sPRIeldbl='"Le"'
sPRIfldbl='"Lf"'
sPRIgldbl='"Lg"'
sPRIi64='"li"'
sPRIo64='"lo"'
sPRIu64='"lu"'
sPRIx64='"lx"'
sSCNfldbl='"Lf"'
sched_yield='sched_yield()'
scriptdir='/usr/bin'
scriptdirexp='/usr/bin'
sed='sed'
seedfunc='srand48'
selectminbits='64'
selecttype='fd_set *'
sendmail=''
setgrent_r_proto='0'
sethostent_r_proto='0'
setlocale_r_proto='0'
setnetent_r_proto='0'
setprotoent_r_proto='0'
setpwent_r_proto='0'
setservent_r_proto='0'
sh='/bin/sh'
shar=''
sharpbang='#!'
shmattype='void *'
shortsize='2'
shrpenv=''
shsharp='true'
sig_count='65'
sig_name='ZERO HUP INT QUIT ILL TRAP ABRT BUS FPE KILL USR1 SEGV USR2 PIPE ALRM TERM STKFLT CHLD CONT STOP TSTP TTIN TTOU URG XCPU XFSZ VTALRM PROF WINCH IO PWR SYS NUM32 NUM33 RTMIN NUM35 NUM36 NUM37 NUM38 NUM39 NUM40 NUM41 NUM42 NUM43 NUM44 NUM45 NUM46 NUM47 NUM48 NUM49 NUM50 NUM51 NUM52 NUM53 NUM54 NUM55 NUM56 NUM57 NUM58 NUM59 NUM60 NUM61 NUM62 NUM63 RTMAX IOT CLD POLL UNUSED '
sig_name_init='"ZERO", "HUP", "INT", "QUIT", "ILL", "TRAP", "ABRT", "BUS", "FPE", "KILL", "USR1", "SEGV", "USR2", "PIPE", "ALRM", "TERM", "STKFLT", "CHLD", "CONT", "STOP", "TSTP", "TTIN", "TTOU", "URG", "XCPU", "XFSZ", "VTALRM", "PROF", "WINCH", "IO", "PWR", "SYS", "NUM32", "NUM33", "RTMIN", "NUM35", "NUM36", "NUM37", "NUM38", "NUM39", "NUM40", "NUM41", "NUM42", "NUM43", "NUM44", "NUM45", "NUM46", "NUM47", "NUM48", "NUM49", "NUM50", "NUM51", "NUM52", "NUM53", "NUM54", "NUM55", "NUM56", "NUM57", "NUM58", "NUM59", "NUM60", "NUM61", "NUM62", "NUM63", "RTMAX", "IOT", "CLD", "POLL", "UNUSED", 0'
sig_num='0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 6 17 29 31 '
sig_num_init='0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 6, 17, 29, 31, 0'
sig_size='69'
signal_t='void'
sitearch='/usr/local/lib/perl/5.14.2'
sitearchexp='/usr/local/lib/perl/5.14.2'
sitebin='/usr/local/bin'
sitebinexp='/usr/local/bin'
sitehtml1dir=''
sitehtml1direxp=''
sitehtml3dir=''
sitehtml3direxp=''
sitelib='/usr/local/share/perl/5.14.2'
sitelib_stem=''
sitelibexp='/usr/local/share/perl/5.14.2'
siteman1dir='/usr/local/man/man1'
siteman1direxp='/usr/local/man/man1'
siteman3dir='/usr/local/man/man3'
siteman3direxp='/usr/local/man/man3'
siteprefix='/usr/local'
siteprefixexp='/usr/local'
sitescript='/usr/local/bin'
sitescriptexp='/usr/local/bin'
sizesize='8'
sizetype='size_t'
sleep=''
smail=''
so='so'
sockethdr=''
socketlib=''
socksizetype='socklen_t'
sort='sort'
spackage='Perl5'
spitshell='cat'
srand48_r_proto='REENTRANT_PROTO_I_LS'
srandom_r_proto='REENTRANT_PROTO_I_TS'
src='.'
ssizetype='ssize_t'
startperl='#!/usr/bin/perl'
startsh='#!/bin/sh'
static_ext=' '
stdchar='char'
stdio_base='((fp)->_IO_read_base)'
stdio_bufsiz='((fp)->_IO_read_end - (fp)->_IO_read_base)'
stdio_cnt='((fp)->_IO_read_end - (fp)->_IO_read_ptr)'
stdio_filbuf=''
stdio_ptr='((fp)->_IO_read_ptr)'
stdio_stream_array=''
strerror_r_proto='REENTRANT_PROTO_B_IBW'
strings='/usr/include/string.h'
submit=''
subversion='2'
sysman='/usr/share/man/man1'
tail=''
tar=''
targetarch=''
tbl=''
tee=''
test='test'
timeincl='/usr/include/x86_64-linux-gnu/sys/time.h /usr/include/time.h '
timetype='time_t'
tmpnam_r_proto='REENTRANT_PROTO_B_B'
to=':'
touch='touch'
tr='tr'
trnl='\n'
troff=''
ttyname_r_proto='REENTRANT_PROTO_I_IBW'
u16size='2'
u16type='unsigned short'
u32size='4'
u32type='unsigned int'
u64size='8'
u64type='unsigned long'
u8size='1'
u8type='unsigned char'
uidformat='"u"'
uidsign='1'
uidsize='4'
uidtype='uid_t'
uname='uname'
uniq='uniq'
uquadtype='unsigned long'
use5005threads='undef'
use64bitall='define'
use64bitint='define'
usecrosscompile='undef'
usedevel='undef'
usedl='define'
usedtrace='undef'
usefaststdio='undef'
useithreads='define'
uselargefiles='define'
uselongdouble='undef'
usemallocwrap='define'
usemorebits='undef'
usemultiplicity='define'
usemymalloc='n'
usenm='false'
useopcode='true'
useperlio='define'
useposix='true'
usereentrant='undef'
userelocatableinc='undef'
usesfio='false'
useshrplib='true'
usesitecustomize='undef'
usesocks='undef'
usethreads='define'
usevendorprefix='define'
usevfork='false'
usrinc='/usr/include'
uuname=''
uvXUformat='"lX"'
uvoformat='"lo"'
uvsize='8'
uvtype='unsigned long'
uvuformat='"lu"'
uvxformat='"lx"'
vaproto='define'
vendorarch='/usr/lib/perl5'
vendorarchexp='/usr/lib/perl5'
vendorbin='/usr/bin'
vendorbinexp='/usr/bin'
vendorhtml1dir=' '
vendorhtml1direxp=''
vendorhtml3dir=' '
vendorhtml3direxp=''
vendorlib='/usr/share/perl5'
vendorlib_stem=''
vendorlibexp='/usr/share/perl5'
vendorman1dir='/usr/share/man/man1'
vendorman1direxp='/usr/share/man/man1'
vendorman3dir='/usr/share/man/man3'
vendorman3direxp='/usr/share/man/man3'
vendorprefix='/usr'
vendorprefixexp='/usr'
vendorscript='/usr/bin'
vendorscriptexp='/usr/bin'
version='5.14.2'
version_patchlevel_string='version 14 subversion 2'
versiononly='undef'
vi=''
voidflags='15'
xlibpth='/usr/lib/386 /lib/386'
yacc='yacc'
yaccflags=''
zcat=''
zip='zip'
!END!

my $i = 0;
foreach my $c (8,7,6,5,4,3,2) { $i |= ord($c); $i <<= 8 }
$i |= ord(1);
our $byteorder = join('', unpack('aaaaaaaa', pack('L!', $i)));
s/(byteorder=)(['"]).*?\2/$1$2$Config::byteorder$2/m;

my $config_sh_len = length $_;

our $Config_SH_expanded = "\n$_" . << 'EOVIRTUAL';
ccflags_nolargefiles='-D_REENTRANT -D_GNU_SOURCE -DDEBIAN -fno-strict-aliasing -pipe -fstack-protector -I/usr/local/include '
ldflags_nolargefiles=' -fstack-protector -L/usr/local/lib'
libs_nolargefiles='-lgdbm -lgdbm_compat -ldb -ldl -lm -lpthread -lc -lcrypt'
libswanted_nolargefiles='gdbm gdbm_compat db dl m pthread c crypt gdbm_compat'
EOVIRTUAL
eval {
	# do not have hairy conniptions if this isnt available
	require 'Config_git.pl';
	$Config_SH_expanded .= $Config::Git_Data;
	1;
} or warn "Warning: failed to load Config_git.pl, something strange about this perl...\n";

# Search for it in the big string
sub fetch_string {
    my($self, $key) = @_;

    return undef unless $Config_SH_expanded =~ /\n$key=\'(.*?)\'\n/s;
    # So we can say "if $Config{'foo'}".
    $self->{$key} = $1 eq 'undef' ? undef : $1;
}

my $prevpos = 0;

sub FIRSTKEY {
    $prevpos = 0;
    substr($Config_SH_expanded, 1, index($Config_SH_expanded, '=') - 1 );
}

sub NEXTKEY {
    my $pos = index($Config_SH_expanded, qq('\n), $prevpos) + 2;
    my $len = index($Config_SH_expanded, "=", $pos) - $pos;
    $prevpos = $pos;
    $len > 0 ? substr($Config_SH_expanded, $pos, $len) : undef;
}

sub EXISTS {
    return 1 if exists($_[0]->{$_[1]});

    return(index($Config_SH_expanded, "\n$_[1]='") != -1
          );
}

sub STORE  { die "\%Config::Config is read-only\n" }
*DELETE = *CLEAR = \*STORE; # Typeglob aliasing uses less space

sub config_sh {
    substr $Config_SH_expanded, 1, $config_sh_len;
}

sub config_re {
    my $re = shift;
    return map { chomp; $_ } grep eval{ /^(?:$re)=/ }, split /^/,
    $Config_SH_expanded;
}

sub config_vars {
    # implements -V:cfgvar option (see perlrun -V:)
    foreach (@_) {
	# find optional leading, trailing colons; and query-spec
	my ($notag,$qry,$lncont) = m/^(:)?(.*?)(:)?$/;	# flags fore and aft, 
	# map colon-flags to print decorations
	my $prfx = $notag ? '': "$qry=";		# tag-prefix for print
	my $lnend = $lncont ? ' ' : ";\n";		# line ending for print

	# all config-vars are by definition \w only, any \W means regex
	if ($qry =~ /\W/) {
	    my @matches = config_re($qry);
	    print map "$_$lnend", @matches ? @matches : "$qry: not found"		if !$notag;
	    print map { s/\w+=//; "$_$lnend" } @matches ? @matches : "$qry: not found"	if  $notag;
	} else {
	    my $v = (exists $Config::Config{$qry}) ? $Config::Config{$qry}
						   : 'UNKNOWN';
	    $v = 'undef' unless defined $v;
	    print "${prfx}'${v}'$lnend";
	}
    }
}

# Called by the real AUTOLOAD
sub launcher {
    undef &AUTOLOAD;
    goto \&$Config::AUTOLOAD;
}

1;
FILE   0c77a581/DynaLoader.pm  )�#line 1 "/usr/lib/perl/5.14/DynaLoader.pm"
# Generated from DynaLoader_pm.PL

package DynaLoader;

#   And Gandalf said: 'Many folk like to know beforehand what is to
#   be set on the table; but those who have laboured to prepare the
#   feast like to keep their secret; for wonder makes the words of
#   praise louder.'

#   (Quote from Tolkien suggested by Anno Siegel.)
#
# See pod text at end of file for documentation.
# See also ext/DynaLoader/README in source tree for other information.
#
# Tim.Bunce@ig.co.uk, August 1994

BEGIN {
    $VERSION = '1.13';
}

use Config;

# enable debug/trace messages from DynaLoader perl code
$dl_debug = $ENV{PERL_DL_DEBUG} || 0 unless defined $dl_debug;

#
# Flags to alter dl_load_file behaviour.  Assigned bits:
#   0x01  make symbols available for linking later dl_load_file's.
#         (only known to work on Solaris 2 using dlopen(RTLD_GLOBAL))
#         (ignored under VMS; effect is built-in to image linking)
#
# This is called as a class method $module->dl_load_flags.  The
# definition here will be inherited and result on "default" loading
# behaviour unless a sub-class of DynaLoader defines its own version.
#

sub dl_load_flags { 0x00 }

($dl_dlext, $dl_so, $dlsrc) = @Config::Config{qw(dlext so dlsrc)};

$do_expand = 0;

@dl_require_symbols = ();       # names of symbols we need
@dl_resolve_using   = ();       # names of files to link with
@dl_library_path    = ();       # path to look for files

#XSLoader.pm may have added elements before we were required
#@dl_shared_objects  = ();       # shared objects for symbols we have 
#@dl_librefs         = ();       # things we have loaded
#@dl_modules         = ();       # Modules we have loaded

# This is a fix to support DLD's unfortunate desire to relink -lc
@dl_resolve_using = dl_findfile('-lc') if $dlsrc eq "dl_dld.xs";

# Initialise @dl_library_path with the 'standard' library path
# for this platform as determined by Configure.

push(@dl_library_path, split(' ', $Config::Config{libpth}));

my $ldlibpthname         = $Config::Config{ldlibpthname};
my $ldlibpthname_defined = defined $Config::Config{ldlibpthname};
my $pthsep               = $Config::Config{path_sep};

# Add to @dl_library_path any extra directories we can gather from environment
# during runtime.

if ($ldlibpthname_defined &&
    exists $ENV{$ldlibpthname}) {
    push(@dl_library_path, split(/$pthsep/, $ENV{$ldlibpthname}));
}

# E.g. HP-UX supports both its native SHLIB_PATH *and* LD_LIBRARY_PATH.

if ($ldlibpthname_defined &&
    $ldlibpthname ne 'LD_LIBRARY_PATH' &&
    exists $ENV{LD_LIBRARY_PATH}) {
    push(@dl_library_path, split(/$pthsep/, $ENV{LD_LIBRARY_PATH}));
}

# No prizes for guessing why we don't say 'bootstrap DynaLoader;' here.
# NOTE: All dl_*.xs (including dl_none.xs) define a dl_error() XSUB
boot_DynaLoader('DynaLoader') if defined(&boot_DynaLoader) &&
                                !defined(&dl_error);

if ($dl_debug) {
    print STDERR "DynaLoader.pm loaded (@INC, @dl_library_path)\n";
    print STDERR "DynaLoader not linked into this perl\n"
	    unless defined(&boot_DynaLoader);
}

1; # End of main code

sub croak   { require Carp; Carp::croak(@_)   }

sub bootstrap_inherit {
    my $module = $_[0];
    local *isa = *{"$module\::ISA"};
    local @isa = (@isa, 'DynaLoader');
    # Cannot goto due to delocalization.  Will report errors on a wrong line?
    bootstrap(@_);
}

sub bootstrap {
    # use local vars to enable $module.bs script to edit values
    local(@args) = @_;
    local($module) = $args[0];
    local(@dirs, $file);

    unless ($module) {
	require Carp;
	Carp::confess("Usage: DynaLoader::bootstrap(module)");
    }

    # A common error on platforms which don't support dynamic loading.
    # Since it's fatal and potentially confusing we give a detailed message.
    croak("Can't load module $module, dynamic loading not available in this perl.\n".
	"  (You may need to build a new perl executable which either supports\n".
	"  dynamic loading or has the $module module statically linked into it.)\n")
	unless defined(&dl_load_file);

    
    my @modparts = split(/::/,$module);
    my $modfname = $modparts[-1];

    # Some systems have restrictions on files names for DLL's etc.
    # mod2fname returns appropriate file base name (typically truncated)
    # It may also edit @modparts if required.
    $modfname = &mod2fname(\@modparts) if defined &mod2fname;

    

    my $modpname = join('/',@modparts);

    print STDERR "DynaLoader::bootstrap for $module ",
		       "(auto/$modpname/$modfname.$dl_dlext)\n"
	if $dl_debug;

    foreach (@INC) {
	
	    my $dir = "$_/auto/$modpname";
	
	next unless -d $dir; # skip over uninteresting directories
	
	# check for common cases to avoid autoload of dl_findfile
	my $try = "$dir/$modfname.$dl_dlext";
	last if $file = ($do_expand) ? dl_expandspec($try) : ((-f $try) && $try);
	
	# no luck here, save dir for possible later dl_findfile search
	push @dirs, $dir;
    }
    # last resort, let dl_findfile have a go in all known locations
    $file = dl_findfile(map("-L$_",@dirs,@INC), $modfname) unless $file;

    croak("Can't locate loadable object for module $module in \@INC (\@INC contains: @INC)")
	unless $file;	# wording similar to error from 'require'

    
    my $bootname = "boot_$module";
    $bootname =~ s/\W/_/g;
    @dl_require_symbols = ($bootname);

    # Execute optional '.bootstrap' perl script for this module.
    # The .bs file can be used to configure @dl_resolve_using etc to
    # match the needs of the individual module on this architecture.
    my $bs = $file;
    $bs =~ s/(\.\w+)?(;\d*)?$/\.bs/; # look for .bs 'beside' the library
    if (-s $bs) { # only read file if it's not empty
        print STDERR "BS: $bs ($^O, $dlsrc)\n" if $dl_debug;
        eval { do $bs; };
        warn "$bs: $@\n" if $@;
    }

    my $boot_symbol_ref;

    

    # Many dynamic extension loading problems will appear to come from
    # this section of code: XYZ failed at line 123 of DynaLoader.pm.
    # Often these errors are actually occurring in the initialisation
    # C code of the extension XS file. Perl reports the error as being
    # in this perl code simply because this was the last perl code
    # it executed.

    my $libref = dl_load_file($file, $module->dl_load_flags) or
	croak("Can't load '$file' for module $module: ".dl_error());

    push(@dl_librefs,$libref);  # record loaded object

    my @unresolved = dl_undef_symbols();
    if (@unresolved) {
	require Carp;
	Carp::carp("Undefined symbols present after loading $file: @unresolved\n");
    }

    $boot_symbol_ref = dl_find_symbol($libref, $bootname) or
         croak("Can't find '$bootname' symbol in $file\n");

    push(@dl_modules, $module); # record loaded module

  boot:
    my $xs = dl_install_xsub("${module}::bootstrap", $boot_symbol_ref, $file);

    # See comment block above

	push(@dl_shared_objects, $file); # record files loaded

    &$xs(@args);
}

sub dl_findfile {
    # Read ext/DynaLoader/DynaLoader.doc for detailed information.
    # This function does not automatically consider the architecture
    # or the perl library auto directories.
    my (@args) = @_;
    my (@dirs,  $dir);   # which directories to search
    my (@found);         # full paths to real files we have found
    #my $dl_ext= 'so'; # $Config::Config{'dlext'} suffix for perl extensions
    #my $dl_so = 'so'; # $Config::Config{'so'} suffix for shared libraries

    print STDERR "dl_findfile(@args)\n" if $dl_debug;

    # accumulate directories but process files as they appear
    arg: foreach(@args) {
        #  Special fast case: full filepath requires no search
	
	
        if (m:/: && -f $_) {
	    push(@found,$_);
	    last arg unless wantarray;
	    next;
	}
	

        # Deal with directories first:
        #  Using a -L prefix is the preferred option (faster and more robust)
        if (m:^-L:) { s/^-L//; push(@dirs, $_); next; }

        #  Otherwise we try to try to spot directories by a heuristic
        #  (this is a more complicated issue than it first appears)
        if (m:/: && -d $_) {   push(@dirs, $_); next; }

	

        #  Only files should get this far...
        my(@names, $name);    # what filenames to look for
        if (m:-l: ) {          # convert -lname to appropriate library name
            s/-l//;
            push(@names,"lib$_.$dl_so");
            push(@names,"lib$_.a");
        } else {                # Umm, a bare name. Try various alternatives:
            # these should be ordered with the most likely first
            push(@names,"$_.$dl_dlext")    unless m/\.$dl_dlext$/o;
            push(@names,"$_.$dl_so")     unless m/\.$dl_so$/o;
	    
            push(@names,"lib$_.$dl_so")  unless m:/:;
            push(@names,"$_.a")          if !m/\.a$/ and $dlsrc eq "dl_dld.xs";
            push(@names, $_);
        }
	my $dirsep = '/';
	
        foreach $dir (@dirs, @dl_library_path) {
            next unless -d $dir;
	    
            foreach $name (@names) {
		my($file) = "$dir$dirsep$name";
                print STDERR " checking in $dir for $name\n" if $dl_debug;
		$file = ($do_expand) ? dl_expandspec($file) : (-f $file && $file);
		#$file = _check_file($file);
		if ($file) {
                    push(@found, $file);
                    next arg; # no need to look any further
                }
            }
        }
    }
    if ($dl_debug) {
        foreach(@dirs) {
            print STDERR " dl_findfile ignored non-existent directory: $_\n" unless -d $_;
        }
        print STDERR "dl_findfile found: @found\n";
    }
    return $found[0] unless wantarray;
    @found;
}

sub dl_expandspec {
    my($spec) = @_;
    # Optional function invoked if DynaLoader.pm sets $do_expand.
    # Most systems do not require or use this function.
    # Some systems may implement it in the dl_*.xs file in which case
    # this Perl version should be excluded at build time.

    # This function is designed to deal with systems which treat some
    # 'filenames' in a special way. For example VMS 'Logical Names'
    # (something like unix environment variables - but different).
    # This function should recognise such names and expand them into
    # full file paths.
    # Must return undef if $spec is invalid or file does not exist.

    my $file = $spec; # default output to input

	return undef unless -f $file;
    print STDERR "dl_expandspec($spec) => $file\n" if $dl_debug;
    $file;
}

sub dl_find_symbol_anywhere
{
    my $sym = shift;
    my $libref;
    foreach $libref (@dl_librefs) {
	my $symref = dl_find_symbol($libref,$sym);
	return $symref if $symref;
    }
    return undef;
}

__END__

FILE   037b8ac0/Errno.pm  9#line 1 "/usr/lib/perl/5.14/Errno.pm"
# -*- buffer-read-only: t -*-
#
# This file is auto-generated. ***ANY*** changes here will be lost
#

package Errno;
require Exporter;
use strict;

our $VERSION = "1.13";
$VERSION = eval $VERSION;
our @ISA = 'Exporter';

my %err;

BEGIN {
    %err = (
	EPERM => 1,
	ENOENT => 2,
	ESRCH => 3,
	EINTR => 4,
	EIO => 5,
	ENXIO => 6,
	E2BIG => 7,
	ENOEXEC => 8,
	EBADF => 9,
	ECHILD => 10,
	EWOULDBLOCK => 11,
	EAGAIN => 11,
	ENOMEM => 12,
	EACCES => 13,
	EFAULT => 14,
	ENOTBLK => 15,
	EBUSY => 16,
	EEXIST => 17,
	EXDEV => 18,
	ENODEV => 19,
	ENOTDIR => 20,
	EISDIR => 21,
	EINVAL => 22,
	ENFILE => 23,
	EMFILE => 24,
	ENOTTY => 25,
	ETXTBSY => 26,
	EFBIG => 27,
	ENOSPC => 28,
	ESPIPE => 29,
	EROFS => 30,
	EMLINK => 31,
	EPIPE => 32,
	EDOM => 33,
	ERANGE => 34,
	EDEADLOCK => 35,
	EDEADLK => 35,
	ENAMETOOLONG => 36,
	ENOLCK => 37,
	ENOSYS => 38,
	ENOTEMPTY => 39,
	ELOOP => 40,
	ENOMSG => 42,
	EIDRM => 43,
	ECHRNG => 44,
	EL2NSYNC => 45,
	EL3HLT => 46,
	EL3RST => 47,
	ELNRNG => 48,
	EUNATCH => 49,
	ENOCSI => 50,
	EL2HLT => 51,
	EBADE => 52,
	EBADR => 53,
	EXFULL => 54,
	ENOANO => 55,
	EBADRQC => 56,
	EBADSLT => 57,
	EBFONT => 59,
	ENOSTR => 60,
	ENODATA => 61,
	ETIME => 62,
	ENOSR => 63,
	ENONET => 64,
	ENOPKG => 65,
	EREMOTE => 66,
	ENOLINK => 67,
	EADV => 68,
	ESRMNT => 69,
	ECOMM => 70,
	EPROTO => 71,
	EMULTIHOP => 72,
	EDOTDOT => 73,
	EBADMSG => 74,
	EOVERFLOW => 75,
	ENOTUNIQ => 76,
	EBADFD => 77,
	EREMCHG => 78,
	ELIBACC => 79,
	ELIBBAD => 80,
	ELIBSCN => 81,
	ELIBMAX => 82,
	ELIBEXEC => 83,
	EILSEQ => 84,
	ERESTART => 85,
	ESTRPIPE => 86,
	EUSERS => 87,
	ENOTSOCK => 88,
	EDESTADDRREQ => 89,
	EMSGSIZE => 90,
	EPROTOTYPE => 91,
	ENOPROTOOPT => 92,
	EPROTONOSUPPORT => 93,
	ESOCKTNOSUPPORT => 94,
	ENOTSUP => 95,
	EOPNOTSUPP => 95,
	EPFNOSUPPORT => 96,
	EAFNOSUPPORT => 97,
	EADDRINUSE => 98,
	EADDRNOTAVAIL => 99,
	ENETDOWN => 100,
	ENETUNREACH => 101,
	ENETRESET => 102,
	ECONNABORTED => 103,
	ECONNRESET => 104,
	ENOBUFS => 105,
	EISCONN => 106,
	ENOTCONN => 107,
	ESHUTDOWN => 108,
	ETOOMANYREFS => 109,
	ETIMEDOUT => 110,
	ECONNREFUSED => 111,
	EHOSTDOWN => 112,
	EHOSTUNREACH => 113,
	EALREADY => 114,
	EINPROGRESS => 115,
	ESTALE => 116,
	EUCLEAN => 117,
	ENOTNAM => 118,
	ENAVAIL => 119,
	EISNAM => 120,
	EREMOTEIO => 121,
	EDQUOT => 122,
	ENOMEDIUM => 123,
	EMEDIUMTYPE => 124,
	ECANCELED => 125,
	ENOKEY => 126,
	EKEYEXPIRED => 127,
	EKEYREVOKED => 128,
	EKEYREJECTED => 129,
	EOWNERDEAD => 130,
	ENOTRECOVERABLE => 131,
	ERFKILL => 132,
	EHWPOISON => 133,
    );
    # Generate proxy constant subroutines for all the values.
    # Well, almost all the values. Unfortunately we can't assume that at this
    # point that our symbol table is empty, as code such as if the parser has
    # seen code such as C<exists &Errno::EINVAL>, it will have created the
    # typeglob.
    # Doing this before defining @EXPORT_OK etc means that even if a platform is
    # crazy enough to define EXPORT_OK as an error constant, everything will
    # still work, because the parser will upgrade the PCS to a real typeglob.
    # We rely on the subroutine definitions below to update the internal caches.
    # Don't use %each, as we don't want a copy of the value.
    foreach my $name (keys %err) {
        if ($Errno::{$name}) {
            # We expect this to be reached fairly rarely, so take an approach
            # which uses the least compile time effort in the common case:
            eval "sub $name() { $err{$name} }; 1" or die $@;
        } else {
            $Errno::{$name} = \$err{$name};
        }
    }
}

our @EXPORT_OK = keys %err;

our %EXPORT_TAGS = (
    POSIX => [qw(
	E2BIG EACCES EADDRINUSE EADDRNOTAVAIL EAFNOSUPPORT EAGAIN EALREADY
	EBADF EBUSY ECHILD ECONNABORTED ECONNREFUSED ECONNRESET EDEADLK
	EDESTADDRREQ EDOM EDQUOT EEXIST EFAULT EFBIG EHOSTDOWN EHOSTUNREACH
	EINPROGRESS EINTR EINVAL EIO EISCONN EISDIR ELOOP EMFILE EMLINK
	EMSGSIZE ENAMETOOLONG ENETDOWN ENETRESET ENETUNREACH ENFILE ENOBUFS
	ENODEV ENOENT ENOEXEC ENOLCK ENOMEM ENOPROTOOPT ENOSPC ENOSYS ENOTBLK
	ENOTCONN ENOTDIR ENOTEMPTY ENOTSOCK ENOTTY ENXIO EOPNOTSUPP EPERM
	EPFNOSUPPORT EPIPE EPROTONOSUPPORT EPROTOTYPE ERANGE EREMOTE ERESTART
	EROFS ESHUTDOWN ESOCKTNOSUPPORT ESPIPE ESRCH ESTALE ETIMEDOUT
	ETOOMANYREFS ETXTBSY EUSERS EWOULDBLOCK EXDEV
    )]
);

sub TIEHASH { bless \%err }

sub FETCH {
    my (undef, $errname) = @_;
    return "" unless exists $err{$errname};
    my $errno = $err{$errname};
    return $errno == $! ? $errno : 0;
}

sub STORE {
    require Carp;
    Carp::confess("ERRNO hash is read only!");
}

*CLEAR = *DELETE = \*STORE; # Typeglob aliasing uses less space

sub NEXTKEY {
    each %err;
}

sub FIRSTKEY {
    my $s = scalar keys %err;	# initialize iterator
    each %err;
}

sub EXISTS {
    my (undef, $errname) = @_;
    exists $err{$errname};
}

tie %!, __PACKAGE__; # Returns an object, objects are true.

__END__

# ex: set ro:
FILE   2b1a9457/Fcntl.pm  #line 1 "/usr/lib/perl/5.14/Fcntl.pm"
package Fcntl;

use strict;
our($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);

require Exporter;
require XSLoader;
@ISA = qw(Exporter);
$VERSION = '1.11';

XSLoader::load();

# Named groups of exports
%EXPORT_TAGS = (
    'flock'   => [qw(LOCK_SH LOCK_EX LOCK_NB LOCK_UN)],
    'Fcompat' => [qw(FAPPEND FASYNC FCREAT FDEFER FDSYNC FEXCL FLARGEFILE
		     FNDELAY FNONBLOCK FRSYNC FSYNC FTRUNC)],
    'seek'    => [qw(SEEK_SET SEEK_CUR SEEK_END)],
    'mode'    => [qw(S_ISUID S_ISGID S_ISVTX S_ISTXT
		     _S_IFMT S_IFREG S_IFDIR S_IFLNK
		     S_IFSOCK S_IFBLK S_IFCHR S_IFIFO S_IFWHT S_ENFMT
		     S_IRUSR S_IWUSR S_IXUSR S_IRWXU
		     S_IRGRP S_IWGRP S_IXGRP S_IRWXG
		     S_IROTH S_IWOTH S_IXOTH S_IRWXO
		     S_IREAD S_IWRITE S_IEXEC
		     S_ISREG S_ISDIR S_ISLNK S_ISSOCK
		     S_ISBLK S_ISCHR S_ISFIFO
		     S_ISWHT S_ISENFMT		
		     S_IFMT S_IMODE
                  )],
);

# Items to export into callers namespace by default
# (move infrequently used names to @EXPORT_OK below)
@EXPORT =
  qw(
	FD_CLOEXEC
	F_ALLOCSP
	F_ALLOCSP64
	F_COMPAT
	F_DUP2FD
	F_DUPFD
	F_EXLCK
	F_FREESP
	F_FREESP64
	F_FSYNC
	F_FSYNC64
	F_GETFD
	F_GETFL
	F_GETLK
	F_GETLK64
	F_GETOWN
	F_NODNY
	F_POSIX
	F_RDACC
	F_RDDNY
	F_RDLCK
	F_RWACC
	F_RWDNY
	F_SETFD
	F_SETFL
	F_SETLK
	F_SETLK64
	F_SETLKW
	F_SETLKW64
	F_SETOWN
	F_SHARE
	F_SHLCK
	F_UNLCK
	F_UNSHARE
	F_WRACC
	F_WRDNY
	F_WRLCK
	O_ACCMODE
	O_ALIAS
	O_APPEND
	O_ASYNC
	O_BINARY
	O_CREAT
	O_DEFER
	O_DIRECT
	O_DIRECTORY
	O_DSYNC
	O_EXCL
	O_EXLOCK
	O_LARGEFILE
	O_NDELAY
	O_NOCTTY
	O_NOFOLLOW
	O_NOINHERIT
	O_NONBLOCK
	O_RANDOM
	O_RAW
	O_RDONLY
	O_RDWR
	O_RSRC
	O_RSYNC
	O_SEQUENTIAL
	O_SHLOCK
	O_SYNC
	O_TEMPORARY
	O_TEXT
	O_TRUNC
	O_WRONLY
     );

# Other items we are prepared to export if requested
@EXPORT_OK = (qw(
	DN_ACCESS
	DN_ATTRIB
	DN_CREATE
	DN_DELETE
	DN_MODIFY
	DN_MULTISHOT
	DN_RENAME
	F_GETLEASE
	F_GETSIG
	F_NOTIFY
	F_SETLEASE
	F_SETSIG
	LOCK_MAND
	LOCK_READ
	LOCK_RW
	LOCK_WRITE
	O_IGNORE_CTTY
	O_NOATIME
	O_NOLINK
	O_NOTRANS
), map {@{$_}} values %EXPORT_TAGS);

1;
FILE   6f095d2b/File/Glob.pm  �#line 1 "/usr/lib/perl/5.14/File/Glob.pm"
package File::Glob;

use strict;
our($VERSION, @ISA, @EXPORT_OK, @EXPORT_FAIL, %EXPORT_TAGS, $DEFAULT_FLAGS);

require XSLoader;
use feature 'switch';

@ISA = qw(Exporter);

# NOTE: The glob() export is only here for compatibility with 5.6.0.
# csh_glob() should not be used directly, unless you know what you're doing.

%EXPORT_TAGS = (
    'glob' => [ qw(
        GLOB_ABEND
	GLOB_ALPHASORT
        GLOB_ALTDIRFUNC
        GLOB_BRACE
        GLOB_CSH
        GLOB_ERR
        GLOB_ERROR
        GLOB_LIMIT
        GLOB_MARK
        GLOB_NOCASE
        GLOB_NOCHECK
        GLOB_NOMAGIC
        GLOB_NOSORT
        GLOB_NOSPACE
        GLOB_QUOTE
        GLOB_TILDE
        glob
        bsd_glob
    ) ],
);

@EXPORT_OK   = (@{$EXPORT_TAGS{'glob'}}, 'csh_glob');

$VERSION = '1.13';

sub import {
    require Exporter;
    local $Exporter::ExportLevel = $Exporter::ExportLevel + 1;
    Exporter::import(grep {
	my $passthrough;
	given ($_) {
	    $DEFAULT_FLAGS &= ~GLOB_NOCASE() when ':case';
	    $DEFAULT_FLAGS |= GLOB_NOCASE() when ':nocase';
	    when (':globally') {
		no warnings 'redefine';
		*CORE::GLOBAL::glob = \&File::Glob::csh_glob;
	    }
	    $passthrough = 1;
	}
	$passthrough;
    } @_);
}

XSLoader::load();

$DEFAULT_FLAGS = GLOB_CSH();
if ($^O =~ /^(?:MSWin32|VMS|os2|dos|riscos)$/) {
    $DEFAULT_FLAGS |= GLOB_NOCASE();
}

# File::Glob::glob() is deprecated because its prototype is different from
# CORE::glob() (use bsd_glob() instead)
sub glob {
    splice @_, 1; # don't pass PL_glob_index as flags!
    goto &bsd_glob;
}

## borrowed heavily from gsar's File::DosGlob
my %iter;
my %entries;

sub csh_glob {
    my $pat = shift;
    my $cxix = shift;
    my @pat;

    # glob without args defaults to $_
    $pat = $_ unless defined $pat;

    # extract patterns
    $pat =~ s/^\s+//;	# Protect against empty elements in
    $pat =~ s/\s+$//;	# things like < *.c> and <*.c >.
			# These alone shouldn't trigger ParseWords.
    if ($pat =~ /\s/) {
        # XXX this is needed for compatibility with the csh
	# implementation in Perl.  Need to support a flag
	# to disable this behavior.
	require Text::ParseWords;
	@pat = Text::ParseWords::parse_line('\s+',0,$pat);
    }

    # assume global context if not provided one
    $cxix = '_G_' unless defined $cxix;
    $iter{$cxix} = 0 unless exists $iter{$cxix};

    # if we're just beginning, do it all first
    if ($iter{$cxix} == 0) {
	if (@pat) {
	    $entries{$cxix} = [ map { doglob($_, $DEFAULT_FLAGS) } @pat ];
	}
	else {
	    $entries{$cxix} = [ doglob($pat, $DEFAULT_FLAGS) ];
	}
    }

    # chuck it all out, quick or slow
    if (wantarray) {
        delete $iter{$cxix};
        return @{delete $entries{$cxix}};
    }
    else {
        if ($iter{$cxix} = scalar @{$entries{$cxix}}) {
            return shift @{$entries{$cxix}};
        }
        else {
            # return undef for EOL
            delete $iter{$cxix};
            delete $entries{$cxix};
            return undef;
        }
    }
}

1;
__END__

FILE   e04372d0/PerlIO/scalar.pm   �#line 1 "/usr/lib/perl/5.14/PerlIO/scalar.pm"
package PerlIO::scalar;
our $VERSION = '0.11_01';
require XSLoader;
XSLoader::load();
1;
__END__

#line 42
FILE   !f0c778a4/Tie/Hash/NamedCapture.pm   �#line 1 "/usr/lib/perl/5.14/Tie/Hash/NamedCapture.pm"
use strict;
package Tie::Hash::NamedCapture;

our $VERSION = "0.08";

require XSLoader;
XSLoader::load(); # This returns true, which makes require happy.

__END__

#line 50
FILE   5f358da5/attributes.pm  
�#line 1 "/usr/lib/perl/5.14/attributes.pm"
package attributes;

our $VERSION = 0.14;

@EXPORT_OK = qw(get reftype);
@EXPORT = ();
%EXPORT_TAGS = (ALL => [@EXPORT, @EXPORT_OK]);

use strict;

sub croak {
    require Carp;
    goto &Carp::croak;
}

sub carp {
    require Carp;
    goto &Carp::carp;
}

my %deprecated;
$deprecated{CODE} = qr/\A-?(locked)\z/;
$deprecated{ARRAY} = $deprecated{HASH} = $deprecated{SCALAR}
    = qr/\A-?(unique)\z/;

sub _modify_attrs_and_deprecate {
    my $svtype = shift;
    # Now that we've removed handling of locked from the XS code, we need to
    # remove it here, else it ends up in @badattrs. (If we do the deprecation in
    # XS, we can't control the warning based on *our* caller's lexical settings,
    # and the warned line is in this package)
    grep {
	$deprecated{$svtype} && /$deprecated{$svtype}/ ? do {
	    require warnings;
	    warnings::warnif('deprecated', "Attribute \"$1\" is deprecated");
	    0;
	} : 1
    } _modify_attrs(@_);
}

sub import {
    @_ > 2 && ref $_[2] or do {
	require Exporter;
	goto &Exporter::import;
    };
    my (undef,$home_stash,$svref,@attrs) = @_;

    my $svtype = uc reftype($svref);
    my $pkgmeth;
    $pkgmeth = UNIVERSAL::can($home_stash, "MODIFY_${svtype}_ATTRIBUTES")
	if defined $home_stash && $home_stash ne '';
    my @badattrs;
    if ($pkgmeth) {
	my @pkgattrs = _modify_attrs_and_deprecate($svtype, $svref, @attrs);
	@badattrs = $pkgmeth->($home_stash, $svref, @pkgattrs);
	if (!@badattrs && @pkgattrs) {
            require warnings;
	    return unless warnings::enabled('reserved');
	    @pkgattrs = grep { m/\A[[:lower:]]+(?:\z|\()/ } @pkgattrs;
	    if (@pkgattrs) {
		for my $attr (@pkgattrs) {
		    $attr =~ s/\(.+\z//s;
		}
		my $s = ((@pkgattrs == 1) ? '' : 's');
		carp "$svtype package attribute$s " .
		    "may clash with future reserved word$s: " .
		    join(' : ' , @pkgattrs);
	    }
	}
    }
    else {
	@badattrs = _modify_attrs_and_deprecate($svtype, $svref, @attrs);
    }
    if (@badattrs) {
	croak "Invalid $svtype attribute" .
	    (( @badattrs == 1 ) ? '' : 's') .
	    ": " .
	    join(' : ', @badattrs);
    }
}

sub get ($) {
    @_ == 1  && ref $_[0] or
	croak 'Usage: '.__PACKAGE__.'::get $ref';
    my $svref = shift;
    my $svtype = uc reftype($svref);
    my $stash = _guess_stash($svref);
    $stash = caller unless defined $stash;
    my $pkgmeth;
    $pkgmeth = UNIVERSAL::can($stash, "FETCH_${svtype}_ATTRIBUTES")
	if defined $stash && $stash ne '';
    return $pkgmeth ?
		(_fetch_attrs($svref), $pkgmeth->($stash, $svref)) :
		(_fetch_attrs($svref))
	;
}

sub require_version { goto &UNIVERSAL::VERSION }

require XSLoader;
XSLoader::load();

1;
__END__
#The POD goes here

FILE   2b6b1843/auto/Fcntl/Fcntl.so  H�ELF          >    0      @       �A          @ 8  @                                 �.      �.                    H2      H2      H2      �      �                    0>      0>      0>      �      �                   �      �      �      $       $              P�td   -      -      -      D       D              Q�td                                                  R�td   H2      H2      H2      �
           @@                    H@         
   �@����%2&  h   �0����%*&  h   � ����%"&  h
&  h   ������%&  h   ������%�%  h   ������%�%  h   �����%�%  h   �����%�%  h   �����%�%  h   �����%�%  h   �p����%�%  h   �`����%�%  h   �P����%�%  h   �@����%�%  h   �0���H��H��$  H��t��H��Ð��������U�=�%   H��ATSubH�=x$   tH�=o%  ����H��  L�%�  H�e%  L)�H��H��H9�s D  H��H�E%  A��H�:%  H9�r��&%  [A\]�f�     H�=�   UH��tH��#  H��t]H�=v  ��@ ]Ð�����UH�5�
  �   SH��H��(����H��  E1�A�0   �   H��H���$    �_���H��H��tgH� �@
H�H�x tTH�L��L��H���"���H�H�r(H��t�V���[  ���҉V�m  H�f�b\�H�H�B0    H� H�@(    I�D$H�t$(1�H��Lc@H�HF�L 	� L�l$�$   �D$�{���H���>  H��H�g  H��H)�H�j  H�T�H��th�KE1�A�   L��H���$    �R���H��I���  H�p�F�Ѓ������H�V�B �  �����H�@  1�H���!����=���@ L��H���=���H�
        %-p is not a valid Fcntl macro at %s line %d
   Couldn't add key '%s' to %%Fcntl::      Couldn't add key '%s' to missing_hash   Fcntl v5.14.0 1.11 Fcntl.c Fcntl::AUTOLOAD Fcntl::S_IMODE Fcntl::S_IFMT Fcntl:: Fcntl::S_ISREG Fcntl::S_ISDIR Fcntl::S_ISLNK Fcntl::S_ISSOCK Fcntl::S_ISBLK Fcntl::S_ISCHR Fcntl::S_ISFIFO DN_ACCESS DN_MODIFY DN_CREATE DN_DELETE DN_RENAME DN_ATTRIB DN_MULTISHOT FAPPEND FASYNC FD_CLOEXEC FNDELAY FNONBLOCK F_DUPFD F_EXLCK F_GETFD F_GETFL F_GETLEASE F_GETLK F_GETLK64 F_GETOWN F_GETSIG F_NOTIFY F_RDLCK F_SETFD F_SETFL F_SETLEASE F_SETLK F_SETLK64 F_SETLKW F_SETLKW64 F_SETOWN F_SETSIG F_SHLCK F_UNLCK F_WRLCK LOCK_MAND LOCK_READ LOCK_WRITE LOCK_RW O_ACCMODE O_APPEND O_ASYNC O_BINARY O_CREAT O_DIRECT O_DIRECTORY O_DSYNC O_EXCL O_LARGEFILE O_NDELAY O_NOATIME O_NOCTTY O_NOFOLLOW O_NONBLOCK O_RDONLY O_RDWR O_RSYNC O_SYNC O_TEXT O_TRUNC O_WRONLY S_IEXEC S_IFBLK S_IFCHR S_IFDIR S_IFIFO S_IFLNK S_IFREG S_IFSOCK S_IREAD S_IRGRP S_IROTH S_IRUSR S_IRWXG S_IRWXO S_IRWXU S_ISGID S_ISUID S_ISVTX S_IWGRP S_IWOTH S_IWRITE S_IWUSR S_IXGRP S_IXOTH S_IXUSR LOCK_SH LOCK_EX LOCK_NB LOCK_UN SEEK_SET SEEK_CUR SEEK_END _S_IFMT FCREAT FDEFER FDSYNC FEXCL FLARGEFILE FRSYNC FTRUNC F_ALLOCSP F_ALLOCSP64 F_COMPAT F_DUP2FD F_FREESP F_FREESP64 F_FSYNC F_FSYNC64 F_NODNY F_POSIX F_RDACC F_RDDNY F_RWACC F_RWDNY F_SHARE F_UNSHARE F_WRACC F_WRDNY O_ALIAS O_DEFER O_EXLOCK O_IGNORE_CTTY O_NOINHERIT O_NOLINK O_NOTRANS O_RANDOM O_RAW O_RSRC O_SEQUENTIAL O_SHLOCK O_TEMPORARY S_ENFMT S_IFWHT S_ISTXT   ;D      H���`   �����   �����   �����   ����  (���8  (���X             zR x�  $      �����   FJw� ?;*3$"    4   D   X����    A�M�G@E
AADj
AAD $   |   ����   M��S0����
H  $   �   ����   M��S0����
E  $   �   ����D   M��S0����
D     �   �����    M��I@�     L     ����2   B�G�E �B(�A0�A8�D��
8A0A(B BBBF                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           ��������        ��������                                s(      	              }(      	              �(      	              �(      	              �(      	              �(      	               �(                �    �(                    �(                     �(      
              �(                    �(      	              �(                     �(                    �(                     )                    )      
             )                    )      	              %)             	       .)                    7)                   @)                     H)                    P)                    X)      
              c)                    k)      	              u)                    ~)      
              �)                    �)             
       �)                    �)                    �)                    �)      	               �)      	       @       �)      
       �       �)             �       �)      	              �)                    �)                     �)                     �)             @       *              @      *                    *                    #*             �       **                     6*                    ?*      	              I*                    R*      
              ]*      
              h*                     q*                    x*                   �*                   �*                     �*                    �*                    �*             @       �*              `      �*                     �*              @      �*                    �*              �      �*              �      �*              �      �*                    �*                     �*                    �*                     +             8       +                    +             �      +                     +                    (+                    0+                    8+                    @+             �       I+             �       Q+                    Y+                    a+             @       i+                    q+                    y+                    �+                    �+                     �+                    �+                    �+              �                                                      �+             �+             �+             �+             �+      
       �+             ,             �+             �+      	       �+             �+             �+             ,             ,      
       ,             $,      	       .,             6,             >,             F,             N,             V,             ^,             f,      	       p,             x,             �,             �,             �,             �,      
       �                           �?             �                           �             (	             �
                 h             H      H                                    c             `      `      �                            n             0      0      �                             t             �&      �&                                    z      2       �&      �&      N                            �             -      -      D                              �             `-      `-      d                             �             H2      H2                                    �             X2      X2                                    �             h2      h2                                    �             �2      �2      �                              �             0>      0>      �                           �             �?      �?      8                             �             �?      �?      �                             �             �@      �@                                    �             �@      �@                                    �                      �@                                                          �@      �                              FILE   73d73815/auto/File/Glob/Glob.so  Y`ELF          >    �      @       �R          @ 8  @                                 �=      �=                    hL      hL      hL      <      P                     N       N       N      �      �                   �      �      �      $       $              P�td   08      08      08      �       �              Q�td                                                  R�td   hL      hL      hL      �      �                      GNU ہZaN�0��L��1���Wva       8         ��`�@-8   :   ?   BE���|���qX<���B��^����%@����:� ��^�q                             	 P              6                     �                     u                     �                      Y                     '                     �                     J                     �                                           D                     2                     �                      =                                          [                     �                     k                     G                     �                                           k                      �                      -                                            �                     �                     �                      �                     i                     �                      �                     �                     �                     �                     �                     �                     �                      W                                           M                      ~                      %                       3                     �                                           �                     9                     &                     |                        "                   �                     9                                           �   ���Q              �   ���Q              �    p0      �       �   ���Q              c    �/      �       V     /      ^       �   	 P                   1      h           H6              �    p3      �      M    �-             __gmon_start__ _fini __cxa_finalize _Jv_RegisterClasses __ctype_tolower_loc readdir64 Perl_safesysrealloc Perl_safesysmalloc sysconf __errno_location Perl_safesysfree PL_memory_wrap Perl_croak_nocontext strcmp PL_charclass __lxstat64 __stack_chk_fail __xstat64 Perl_my_strlcpy closedir opendir qsort getpwnam getenv getuid getpwuid bsd_glob bsd_globfree XS_File__Glob_GLOB_ERROR Perl_sv_setiv Perl_mg_set Perl_sv_newmortal Perl_croak_xs_usage XS_File__Glob_AUTOLOAD Perl_newSVpvn_flags Perl_newSVpvf_nocontext Perl_sv_2mortal Perl_croak_sv XS_File__Glob_doglob strlen Perl_sv_magic Perl_sv_2pv_flags Perl_stack_grow Perl_get_sv Perl_sv_2iv_flags boot_File__Glob Perl_xs_apiversion_bootcheck Perl_xs_version_bootcheck Perl_newXS Perl_newXS_flags Perl_my_cxt_init PL_thr_key pthread_getspecific Perl_get_hv Perl_newSViv Perl_hv_common_key_len Perl_newCONSTSUB Perl_sv_upgrade Perl_mro_method_changed_in Perl_call_list Perl_croak libc.so.6 _edata __bss_start _end GLIBC_2.3 GLIBC_2.4 GLIBC_2.2.5                                                                                                             �         ii
           HP                    PP                    XP         
   �@����%";  h   �0����%;  h   � ����%;  h
;  h   � ����%;  h   ������%�:  h   ������%�:  h   ������%�:  h   ������%�:  h   �����%�:  h   �����%�:  h   �����%�:  h   �����%�:  h   �p����%�:  h   �`����%�:  h   �P����%�:  h   �@����%�:  h   �0����%�:  h   � ����%�:  h   �����%�:  h   � ����%�:  h   ������%z:  h    ������%r:  h!   ������%j:  h"   ������%b:  h#   �����%Z:  h$   �����%R:  h%   �����%J:  h&   �����%B:  h'   �p����%::  h(   �`����%2:  h)   �P����%*:  h*   �@����%":  h+   �0����%:  h,   � ����%:  h-   �����%
:  h.   � ����%:  h/   ������%�9  h0   ������%�9  h1   ������%�9  h2   �����H��H�8  H��t��H��Ð��������U�=�9   H��ATSubH�=�7   tH�=�9  �z���H��4  L�%t4  H��9  L)�H��H��H9�s D  H��H��9  A��H�z9  H9�r��f9  [A\]�f�     H�=04   UH��tH�s7  H��t]H�=4  ��@ ]Ð�����AWAVI��AUI��ATA��UH��SH��HH9�s]H�O�   E�>H�i�I�^fA��?��   fA��[���   fA��*�t<D�q�H��fE9���E���  ��uVI��H��M9�w�1�f�}  ���@�     L9�   t.fD  D��L��H��H���O�������  �E H��f��u�1�H��H[]A\A]A^A_�f�     �q�H��f��t�A�F1�f=!��T$<��  D��Ic�E���   H��H�T$0D�L$81���   f�     f9�A��E����   �؍��   =  w=�T$(H�L$Hcۉt$ �|$D�D$����H�8D�D$�t$ H�L$�T$(H���|$��|$8  D��w=�T$(H�L$�t$ �|$D�D$�[���L�L$0H� D�D$�|$�t$ H�L$B��T$(9�A��E��E�D��L��f=]�L�s�a  D�{fA��-��(���E���  D��A���   =  w>�T$(H�L$Mc��t$ �|$D�D$�����L�D�D$�|$�t$ H�L$�T$(O�4�E�6�|$8  D��w=�T$(H�L$�t$ �|$D�D$����L�L$0H� D�D$�|$�t$ H�L$B��T$(A9�g�|$8  E��w=�T$(H�L$�t$ �|$D�D$�8���L�L$0H� D�D$�|$�t$ H�L$F�<�T$(D�sA���   =  ��   E9�N�L�sD�{���� f9�r�f;sF���f.�     f�y� H���"����s���D  ;T$<�����_���f�     E��A���   =  w$H�L$�|$����H�0Ic֋|$H�L$H��D�2E��A���   =  w$H�L$�|$�J���H�Ic׋|$H��H�L$D�:E9�������f�     I�^A�F����f��T$(H�L$�t$ �|$D�D$�����L� Mc΋|$�t$ H�L$�T$(O��D�D$E�1�����D  H��H�   []A\A]A^A_�@ �����ff.�     AWAVAUI��ATUH��SH��H��D�&H�~A��DfMc�I��H����  M���1  �I*��X$  f.$  �  J�4�    �I���H��H�CH��H���  H���}  H�SI��fD  A�I��f��u�I)�H�T$I��Mu L������I��1�H�T$M����  f�     I9�t{�LE A�H����u��K���Hc�L�<ʉCH�H��    �C
���I��fA�  A�   H�T$(L���B@�i��������b����     H�D$HL�L$@I�V�H�t$8H�|$0M��H��H�D$H�D$(H�$�   ������A���f�����H�L$I���$���H�T$(E1�H�BH�������1�H�|$0�
H��I9�w�f�  �kM���T$�����@ H�������A��!f�[�H�Q��   �?��    ��H����]tIH��f��� H�Jf�:�8f��-u��xf��]tBf��� f�B-�H�Jf�z�xH��H������]u�f�]��K   H���q���fD  H���-   �D  f�A!�H�Q�e����H��$@  H��$   H��$@  M���  M��H�$H��H��H�D$���������   �kH�� @  []A\A]A^��    �u��   ��   �����H��$@  �kH��L����������D  H�=  �4���H���T��������������H���;����kA�U M���O����E H��f�H��f���M���fD  L9��>����E H��f�H��f��u�f�  �kM���T$������3�����ffffff.�     ATI��UH��SH���f��{tbH���@ H���f��{t#f��u�L��H���s���H��[]A\�f.�     H��t�H�L$L��H��H���(   ��u��D$H��[]A\�f�}u�f� u���    AWI��AVAUATUSH��H��   H9�I��t6H�FH��H)�H��H��L�@1�K� �    �f�H��H9�u�N�4D�wfA�  f����   H����E1�H���+f.�     f��{��   f��}��   �MH��f��t_f��[u��ML�Ef����   f��]��   L���f�     f��]tH���f��u�f��L��t��HH�hf��u�f�     H��H������A�H��   1�[]A\A]A^A_�fD  �MA��H���c����    E��tA���F���f���L���H9�I��s"�O�    f��,tNI�L$H9�w8A�t$I��f��[��   v�f��{��   f��}u�E��tI�L$A��H9�v�A�    �R���E��u�I9�L��v)H��L���H��f�
H��L9�r�H��J�'H��I�LF1�@ �Tf�H��f��u�H��H���[���I�|$A�H���N���A���@���f�A�D$I�L$H��f��u� H���f��tf��]u�f������H�JI�������H����H��   ��������   �    H�A    �A    �yH�Q�A    ucD� H��E��t1L��$�  H��H���     fD�H��L9�s
H��L��L9�s�E�I��E��t�A��\u�D�XA�\@  E��t�E��L�@fA�� @�fD  �����H��   �ff.�     ATI��USH�H��tIA�$A�T$��t.Hc҃�H��H�l�@ H�;H��t�S���H��H9�u�I�|$�@���I�D$    []A\Ð���t��
      Couldn't add key '%s' to %%File::Glob:: ;�      @����   P����   ����X  ����p  @����  P���  P���0  ����P  p���p  �����  `���  ����p  @����  ����  ����(  0���X  P���p  @����  �����  @���              zR x�  $      p���@   FJw� ?;*3$"    d   D   X���\   B�B�E �E(�D0�D8�D��
8A0A(B BBBJl8F0A(B BBB        �   P���           |   �   H����   B�B�B �E(�A0�D8�GP�
8A0A(B BBBHt
8F0A(B BBBE{
8A0A(B BBBK        D  H���           $   \  @����    D��
MA
G        �  ����    G� b
G       �  �����    G� b
G    L   �  ����<   B�E�H �B(�D0�D8�J�A�
8A0A(B BBBK   L     �����   B�H�B �B(�F0�D8�J�`
8A0A(B BBBD    \   d  H���A   B�B�E �D(�A0�JЀ=
0A(A BBBC
0A(A BBBH   D   �  8����    B�D�D �D0s
 AABKd
 AABA       L     ����o   B�E�B �B(�A0�A8�J�@�
8C0A(B BBBG       \  ����   L�@�
Gt,   |  ����^    B�D�A �SAB         �  ����           $   �  �����    M��S0����
F     �  �����    A�  L     ���h   B�B�E �B(�A0�A8�G�f
8A0A(B BBBD   L   T  8����   B�G�E �B(�A0�A8�Dpi
8A0A(B BBBA                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                            ��������        ��������                                7      
       ��������#7                     27             @       B7      
       �       M7                    V7      
        @      a7      	              k7                    w7                    �7                    �7                     �7             ���������7      
              �7      
              �7             �.                                     �             P      
       �                           �O             �                           �             0
                 h             P      P                                    c             p      p      @                            n             �      �      �                             t             H6      H6                                    z             X6      X6      �                             �             08      08      �                              �             �8      �8      �                             �             hL      hL                                    �             xL      xL                                    �             �L      �L                                    �             �L      �L      �                              �              N       N      �                           �             �O      �O      H                             �             �O      �O      �                            �             �Q      �Q                                    �             �Q      �Q                                    �                      �Q                                                          �Q      �                              FILE   %035edc9b/auto/PerlIO/scalar/scalar.so  9pELF          >    �      @       �2          @ 8  @                                 �$      �$                    .      .      .      �      �                    @.      @.      @.      �      �                   �      �      �      $       $              P�td   h!      h!      h!      �       �              Q�td                                                  R�td   .      .      .      �      �                      GNU ך^�>B^�"wx�u*�Y�<       (         ���� B�(�  F  *   	 0�    (   *   -   /       1   2   3   5   6   7   9   :   =   >   @   ����++v>��9))v����:�;�qXDO�f��|�CE����:ij�ǋ�� /ϧn	�9�+v�$v�s:z���=�p���`�����*v                             	 h              ;                                          c                     �                     �                                           ]                                          �                     �                     �                     �                     �                      �                     �                      `                     �                     �                     �                                            �                      �                                          �                     w                                          K                     x                     �                     >                     �                     �                      +                                            �                     =                        "                   �                          (!              �    �      {      �     �      Y       �           �           	 h              �    �      L      �   �� 2              U     1      �           ��2              J          �       �   �� 2              w     �             �    �      C       &    �      D       )    �      �      �     �             S     `             e     p             �    @             r    �             
            �       ?     P             �    `      G       �    P      2       �    0      �        __gmon_start__ _init _fini __cxa_finalize _Jv_RegisterClasses PerlIOScalar_fileno PerlIOScalar_tell PerlIOScalar_fill PerlIOScalar_flush PerlIOScalar_dup PerlIOBase_dup PerlIOScalar_arg Perl_newRV_noinc PerlIO_sv_dup Perl_newSVsv PerlIOScalar_open PerlIO_push PerlIO_arg_fetch PerlIO_allocate PerlIOScalar_set_ptrcnt Perl_mg_get PerlIOScalar_get_base Perl_sv_2pv_flags PerlIOScalar_get_ptr PerlIOScalar_seek memset Perl_sv_grow Perl_ckwarn Perl_warner __errno_location PerlIOScalar_close PerlIOBase_close PerlIOScalar_popped Perl_sv_free Perl_sv_free2 PerlIOScalar_pushed Perl_newSVpvn PerlIOBase_pushed Perl_sv_force_normal_flags Perl_mg_set Perl_sv_upgrade Perl_get_sv PL_no_modify PerlIOScalar_bufsiz PerlIOScalar_get_cnt PerlIOScalar_write memmove PerlIOScalar_read memcpy boot_PerlIO__scalar Perl_xs_apiversion_bootcheck Perl_xs_version_bootcheck PerlIO_scalar PerlIO_define_layer Perl_call_list PerlIOBase_binmode PerlIOBase_eof PerlIOBase_error PerlIOBase_clearerr PerlIOBase_setlinebuf libc.so.6 _edata __bss_start _end GLIBC_2.14 GLIBC_2.2.5                                                                                                         �         ���        ui	          1              1      (1             _!      �/         /           �/         
           `1         *           h1         =           p1         7           x1         @           �1         -           �1         )           �1         8           �1         :           �1         3           �1         9           �1         '           �1                    �1                    �1                    �1         1           �1         ?           �1         ;           �1         4           �1         5            0                    0                    0                    0                     0                    (0                    00                    80         	           @0                    H0                    P0                    X0                    `0                    h0                    p0                    x0                    �0                    �0                    �0         1           �0                    �0                    �0                    �0                    �0                    �0                    �0                     �0         !           �0         #           �0         $           �0         %           �0         &           H���  �  �u
   �@����%  h   �0����%
  h   � ����%  h
H��J    H�\$H�l$ L�d$(L�l$0H��8�H��H���E���I���H��L�D$�S���L�D$H���f�     H�l$�H�\$�H��H�H��H�s �F t	�-���H�s H�H�@H)�H�C(H�\$H�l$H���fff.�     H�\$�H�l$�H��H�.H���EtVH�u �F�    u��t$H�FH�\$H�l$H�������H�u �F��u�H��H�l$H�\$�   1�H�������f�1�H�\$H�l$H���ffffff.�     SH�1��Ct	�����HC([�f�     H�\$�H�l$�H��L�d$�L�l$�H��8L�&H��I�t$ �F ��   H���L�h��   ����   ��ukI�\$(H����   I9�r0H�~ ��   �N D  1�H�\$H�l$ L�d$(L�l$0H��8� H�H;XwgL��H~H��1�L)������I�t$ �@ I�\$(듐�L$����I�t$ �L$H���L�h�^���I\$(I�\$(�a����    L��M���H��H�������I�t$ �fD  H�H�x �E����   H������I�t$ �.����   H���F�����tH�!  �   H��1�����������    H�����������D  SH���'���H��b����[�ff.�     SH�H�s H��t�F��t�����Ft"H�C     1�[�fD  ������f�     ������f�     H�\$�H�l$�H��L�d$�L�l$�I��L�t$�H��(H��I��H��M��I�$t�A<��   �����   H�5V  1�H���V���H�C �P���e  1�L��L��M��H�������H�s I�ŋF<td���ul1�H������H�C H� H�@    I�$H�s �@�� uTH�C(    �F@tH������L��H�$H�l$L�d$L�l$L�t$ H��(�H�F�@ �  t�I�$�@��u��� t�1�H���(���H�s H�H�@H�C(��    H�Q�B �  ��������   H�F�P��   tM��t��   	��   	tA�} r��   �@H�C �H��    ��   �������������   ������������1ҹ    H��H�������H�C �P�����   H��H���������� ��t#H�v�   H������H���S����@�J����   1�H������H����@ H��H���-���H�C �H�O����   H���T�����tH�
H�H�@[Ð����H�s H�H�@��fffff.�     SH�1��Ct$H�s �F u"H�H�S(H�H1�H��H)�H9�HG�[�fD  �C���H�s ��ffff.�     H�\$�H�l$�1�L�d$�L�|$�H��L�l$�L�t$�H��8L�6H��I��I��A�FtxM�n A�E ��   1�L��H������H��@ tyI�E H�xI�?H9P��   I�EI�V(H�L��L������I�E I�V(H;PvH�PA�E��D�  @ A�EuqL��H�\$H�l$L�d$L�l$ L�t$(L�|$0H��8� I�~(I�E I�?H;Pv�H;Pv�H��L������I�~(I�?�q����     L�������,��� L��H�������� H��L���u���I�U H�zI�?�-���@ H�l$�L�d$�H��L�l$�H�\$�E1�H��8H��I��tRH��C��tgH�s �F
NL
LL   $   �   ����    M��N@��d
A         ����D    N ��u     $   4  �����    N ��q
Ai
GP    \  (���    A�U       $   |  (���{   M��N@��q
D       �  ����    A�S          �  ����G    A�h
G    $   �  �����   M��M��I0��
A      (���2    A�]
B       ,  H���C    A�p
G    $   L  x���L   Y����N@���
D$   t  �����    M��M��D@u
E   $   �  H����    nP�������                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    ��������        ��������                       �             h      
                                  �/             �                           �             �
                 h             h      h                                    c             �      �                                   n             �      �      �                             t             (!      (!                                    z      2       6!      6!      0                             �             h!      h!      �                              �             "      "      �                             �             .      .                                    �             (.      (.                                    �             8.      8.                                    �             @.      @.      �                           �             �/      �/      (                             �             �/      �/                                  �              1       1                                     �              2       2                                    �                       2                                                          2      �                              FILE   3cff5d8fd/auto/Tie/Hash/NamedCapture/NamedCapture.so  (@ELF          >    �
           H                     P          
   �@����%�  h   �0����%�  h   � ����%�  h
  J�,��    �}HE��E�A����E�A���A��A9���   A��Mc�J��    H�H����   H�
�A
HCH���D  �   H���������M���H�  H�5  A��H��HE�����fD  H�\$�H�l$�1�L�l$�L�d$�H��L�t$�L�|$�H��8H�GpL�7�H��M��H�GpH�GHc�H��I)�H�I��D�a(H���  H��tH�y8H��0
  H�,��    �}HE�D����A9��r  ��H����   Lc�J���A
H  $   l   `����    A�A�G �AA,   �   �����   M��Z@����2
G       ,   �   X���.   L��[@����U
D       L   �   X���   B�B�B �B(�A0�D8�D`a
8A0A(B BBBD    L   D  (���X   B�N�B �B(�D0�A8�GP-8A0A(B BBB                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                               ��������        ��������                       f             �      
       �                           �             @                           �	             �             �       	              ���o    �      ���o           ���o    d      ���o                                                                                                                                                   0                                  &      6      F      V      f      v      �      �      �      �      �      �      �      �      
                 h             �      �                                    c             �      �      �                            n             �
����):h�}v�+�                �� �PP	         BE��*����|tè\y���qX�ac1����������                                 	 
              �                     
                     U                      e                      =                     6                                            �                      �                      O                     �                     �                     j                     s                      �                     �                      +                       �                         "                                         �   ���               �     �      {      �   ���               ?     0      J      �     �
                   (              Z    �      n       __gmon_start__ _init _fini __cxa_finalize _Jv_RegisterClasses XS_attributes_reftype Perl_sv_reftype Perl_sv_setpv Perl_mg_set Perl_sv_newmortal Perl_mg_get Perl_croak_xs_usage XS_attributes__guess_stash Perl_sv_setpvn XS_attributes__fetch_attrs Perl_newSVpvn_flags Perl_stack_grow XS_attributes__modify_attrs memcmp Perl_sv_2pv_flags Perl_croak boot_attributes Perl_xs_apiversion_bootcheck Perl_xs_version_bootcheck Perl_newXS Perl_newXS_flags Perl_call_list libc.so.6 _edata __bss_start _end GLIBC_2.2.5                                                             �         ui	   �      �              �       �                    �                    �                    �                    �                    �                    �                                                                                                                               (                     0          	           8          
           @                     H                     P          
  H���        �5�  �%�  @ �%�  h    ������%�  h   ������%�  h   ������%�  h   �����%�  h   �����%�  h   �����%�  h   �����%�  h   �p����%z  h   �`����%r  h	   �P����%j  h
   �@����%b  h   �0����%Z  h   � ����%R  h
H��H�WpH�WHc�H�<�H)�H����A����  ��Hc�L�$�H�L$I�<$�O����  �����  ����  A��L�H�L$u!H�D��I�H��8[]A\A]A^A_�f.�     L�l����D$    I�mH�D� H�D$�gH�H�{H�@H�D$(�?-�D$u
H�l$(H��A�
D  <   l   ����   B�B�A �A(�G@�
(A ABBD     $   �   ����{   M��N0���
C    d   �   ����a   B�B�E �B(�A0�A8�Dpz
8A0A(B BBBK�
8A0A(B BBBD    $   <   ���n   nP������?                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                           ��������        ��������                       �             
      
       �                           �             �                           `             �             �       	              ���o    �      ���o           ���o    :      ���o                                                                                                                                                   0                      F
      V
      f
      v
      �
      �
      �
      �
      �
      �
      �
      �
                  &      6      F      V      �       attributes.so   �҉� .shstrtab .note.gnu.build-id .gnu.hash .dynsym .dynstr .gnu.version .gnu.version_r .rela.dyn .rela.plt .init .text .fini .rodata .eh_frame_hdr .eh_frame .ctors .dtors .jcr .dynamic .got .got.plt .data .bss .gnu_debuglink                                                                                    �      �      $                                 ���o       �      �      L                             (             @      @                                 0             @      @      �                             8   ���o       :      :      @                            E   ���o       �      �                                   T             �      �      �                            ^             `      `      �         
                 h             
      
                                    c             0
      0
      0                            n             `      `      �	                             t             (      (                                    z      2       8      8      �                             �                           <                              �             @      @      d                             �                                                       �                                                       �             (      (                                    �             0      0      �                           �             �      �      8                             �             �      �      �                             �             �       �                                     �             �       �                                     �                      �                                                           �       �                              FILE   55b87960/lib.pm  	#line 1 "/usr/lib/perl/5.14/lib.pm"
package lib;

# THIS FILE IS AUTOMATICALLY GENERATED FROM lib_pm.PL.
# ANY CHANGES TO THIS FILE WILL BE OVERWRITTEN BY THE NEXT PERL BUILD.

use Config;

use strict;

my $archname         = $Config{archname};
my $version          = $Config{version};
my @inc_version_list = reverse split / /, $Config{inc_version_list};

our @ORIG_INC = @INC;	# take a handy copy of 'original' value
our $VERSION = '0.63';

sub import {
    shift;

    my %names;
    foreach (reverse @_) {
	my $path = $_;		# we'll be modifying it, so break the alias
	if ($path eq '') {
	    require Carp;
	    Carp::carp("Empty compile time value given to use lib");
	}

	if ($path !~ /\.par$/i && -e $path && ! -d _) {
	    require Carp;
	    Carp::carp("Parameter to use lib must be directory, not file");
	}
	unshift(@INC, $path);
	# Add any previous version directories we found at configure time
	foreach my $incver (@inc_version_list)
	{
	    my $dir = "$path/$incver";
	    unshift(@INC, $dir) if -d $dir;
	}
	# Put a corresponding archlib directory in front of $path if it
	# looks like $path has an archlib directory below it.
	my($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir)
	    = _get_dirs($path);
	unshift(@INC, $arch_dir)         if -d $arch_auto_dir;
	unshift(@INC, $version_dir)      if -d $version_dir;
	unshift(@INC, $version_arch_dir) if -d $version_arch_dir;
    }

    # remove trailing duplicates
    @INC = grep { ++$names{$_} == 1 } @INC;
    return;
}

sub unimport {
    shift;

    my %names;
    foreach my $path (@_) {
	my($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir)
	    = _get_dirs($path);
	++$names{$path};
	++$names{$arch_dir}         if -d $arch_auto_dir;
	++$names{$version_dir}      if -d $version_dir;
	++$names{$version_arch_dir} if -d $version_arch_dir;
    }

    # Remove ALL instances of each named directory.
    @INC = grep { !exists $names{$_} } @INC;
    return;
}

sub _get_dirs {
    my($dir) = @_;
    my($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir);

    $arch_auto_dir    = "$dir/$archname/auto";
    $arch_dir         = "$dir/$archname";
    $version_dir      = "$dir/$version";
    $version_arch_dir = "$dir/$version/$archname";

    return($arch_auto_dir, $arch_dir, $version_dir, $version_arch_dir);
}

1;
__END__

FILE   cbf6b855/Cwd.pm  B�#line 1 "/usr/local/lib/perl/5.14.2/Cwd.pm"
package Cwd;

#line 169

use strict;
use Exporter;
use vars qw(@ISA @EXPORT @EXPORT_OK $VERSION);

$VERSION = '3.33';
my $xs_version = $VERSION;
$VERSION = eval $VERSION;

@ISA = qw/ Exporter /;
@EXPORT = qw(cwd getcwd fastcwd fastgetcwd);
push @EXPORT, qw(getdcwd) if $^O eq 'MSWin32';
@EXPORT_OK = qw(chdir abs_path fast_abs_path realpath fast_realpath);

# sys_cwd may keep the builtin command

# All the functionality of this module may provided by builtins,
# there is no sense to process the rest of the file.
# The best choice may be to have this in BEGIN, but how to return from BEGIN?

if ($^O eq 'os2') {
    local $^W = 0;

    *cwd                = defined &sys_cwd ? \&sys_cwd : \&_os2_cwd;
    *getcwd             = \&cwd;
    *fastgetcwd         = \&cwd;
    *fastcwd            = \&cwd;

    *fast_abs_path      = \&sys_abspath if defined &sys_abspath;
    *abs_path           = \&fast_abs_path;
    *realpath           = \&fast_abs_path;
    *fast_realpath      = \&fast_abs_path;

    return 1;
}

# Need to look up the feature settings on VMS.  The preferred way is to use the
# VMS::Feature module, but that may not be available to dual life modules.

my $use_vms_feature;
BEGIN {
    if ($^O eq 'VMS') {
        if (eval { local $SIG{__DIE__}; require VMS::Feature; }) {
            $use_vms_feature = 1;
        }
    }
}

# Need to look up the UNIX report mode.  This may become a dynamic mode
# in the future.
sub _vms_unix_rpt {
    my $unix_rpt;
    if ($use_vms_feature) {
        $unix_rpt = VMS::Feature::current("filename_unix_report");
    } else {
        my $env_unix_rpt = $ENV{'DECC$FILENAME_UNIX_REPORT'} || '';
        $unix_rpt = $env_unix_rpt =~ /^[ET1]/i; 
    }
    return $unix_rpt;
}

# Need to look up the EFS character set mode.  This may become a dynamic
# mode in the future.
sub _vms_efs {
    my $efs;
    if ($use_vms_feature) {
        $efs = VMS::Feature::current("efs_charset");
    } else {
        my $env_efs = $ENV{'DECC$EFS_CHARSET'} || '';
        $efs = $env_efs =~ /^[ET1]/i; 
    }
    return $efs;
}


# If loading the XS stuff doesn't work, we can fall back to pure perl
eval {
  if ( $] >= 5.006 ) {
    require XSLoader;
    XSLoader::load( __PACKAGE__, $xs_version);
  } else {
    require DynaLoader;
    push @ISA, 'DynaLoader';
    __PACKAGE__->bootstrap( $xs_version );
  }
};

# Must be after the DynaLoader stuff:
$VERSION = eval $VERSION;

# Big nasty table of function aliases
my %METHOD_MAP =
  (
   VMS =>
   {
    cwd			=> '_vms_cwd',
    getcwd		=> '_vms_cwd',
    fastcwd		=> '_vms_cwd',
    fastgetcwd		=> '_vms_cwd',
    abs_path		=> '_vms_abs_path',
    fast_abs_path	=> '_vms_abs_path',
   },

   MSWin32 =>
   {
    # We assume that &_NT_cwd is defined as an XSUB or in the core.
    cwd			=> '_NT_cwd',
    getcwd		=> '_NT_cwd',
    fastcwd		=> '_NT_cwd',
    fastgetcwd		=> '_NT_cwd',
    abs_path		=> 'fast_abs_path',
    realpath		=> 'fast_abs_path',
   },

   dos => 
   {
    cwd			=> '_dos_cwd',
    getcwd		=> '_dos_cwd',
    fastgetcwd		=> '_dos_cwd',
    fastcwd		=> '_dos_cwd',
    abs_path		=> 'fast_abs_path',
   },

   # QNX4.  QNX6 has a $os of 'nto'.
   qnx =>
   {
    cwd			=> '_qnx_cwd',
    getcwd		=> '_qnx_cwd',
    fastgetcwd		=> '_qnx_cwd',
    fastcwd		=> '_qnx_cwd',
    abs_path		=> '_qnx_abs_path',
    fast_abs_path	=> '_qnx_abs_path',
   },

   cygwin =>
   {
    getcwd		=> 'cwd',
    fastgetcwd		=> 'cwd',
    fastcwd		=> 'cwd',
    abs_path		=> 'fast_abs_path',
    realpath		=> 'fast_abs_path',
   },

   epoc =>
   {
    cwd			=> '_epoc_cwd',
    getcwd	        => '_epoc_cwd',
    fastgetcwd		=> '_epoc_cwd',
    fastcwd		=> '_epoc_cwd',
    abs_path		=> 'fast_abs_path',
   },

   MacOS =>
   {
    getcwd		=> 'cwd',
    fastgetcwd		=> 'cwd',
    fastcwd		=> 'cwd',
    abs_path		=> 'fast_abs_path',
   },
  );

$METHOD_MAP{NT} = $METHOD_MAP{MSWin32};


# Find the pwd command in the expected locations.  We assume these
# are safe.  This prevents _backtick_pwd() consulting $ENV{PATH}
# so everything works under taint mode.
my $pwd_cmd;
foreach my $try ('/bin/pwd',
		 '/usr/bin/pwd',
		 '/QOpenSys/bin/pwd', # OS/400 PASE.
		) {

    if( -x $try ) {
        $pwd_cmd = $try;
        last;
    }
}
my $found_pwd_cmd = defined($pwd_cmd);
unless ($pwd_cmd) {
    # Isn't this wrong?  _backtick_pwd() will fail if somenone has
    # pwd in their path but it is not /bin/pwd or /usr/bin/pwd?
    # See [perl #16774]. --jhi
    $pwd_cmd = 'pwd';
}

# Lazy-load Carp
sub _carp  { require Carp; Carp::carp(@_)  }
sub _croak { require Carp; Carp::croak(@_) }

# The 'natural and safe form' for UNIX (pwd may be setuid root)
sub _backtick_pwd {
    # Localize %ENV entries in a way that won't create new hash keys
    my @localize = grep exists $ENV{$_}, qw(PATH IFS CDPATH ENV BASH_ENV);
    local @ENV{@localize};
    
    my $cwd = `$pwd_cmd`;
    # Belt-and-suspenders in case someone said "undef $/".
    local $/ = "\n";
    # `pwd` may fail e.g. if the disk is full
    chomp($cwd) if defined $cwd;
    $cwd;
}

# Since some ports may predefine cwd internally (e.g., NT)
# we take care not to override an existing definition for cwd().

unless ($METHOD_MAP{$^O}{cwd} or defined &cwd) {
    # The pwd command is not available in some chroot(2)'ed environments
    my $sep = $Config::Config{path_sep} || ':';
    my $os = $^O;  # Protect $^O from tainting


    # Try again to find a pwd, this time searching the whole PATH.
    if (defined $ENV{PATH} and $os ne 'MSWin32') {  # no pwd on Windows
	my @candidates = split($sep, $ENV{PATH});
	while (!$found_pwd_cmd and @candidates) {
	    my $candidate = shift @candidates;
	    $found_pwd_cmd = 1 if -x "$candidate/pwd";
	}
    }

    # MacOS has some special magic to make `pwd` work.
    if( $os eq 'MacOS' || $found_pwd_cmd )
    {
	*cwd = \&_backtick_pwd;
    }
    else {
	*cwd = \&getcwd;
    }
}

if ($^O eq 'cygwin') {
  # We need to make sure cwd() is called with no args, because it's
  # got an arg-less prototype and will die if args are present.
  local $^W = 0;
  my $orig_cwd = \&cwd;
  *cwd = sub { &$orig_cwd() }
}


# set a reasonable (and very safe) default for fastgetcwd, in case it
# isn't redefined later (20001212 rspier)
*fastgetcwd = \&cwd;

# A non-XS version of getcwd() - also used to bootstrap the perl build
# process, when miniperl is running and no XS loading happens.
sub _perl_getcwd
{
    abs_path('.');
}

# By John Bazik
#
# Usage: $cwd = &fastcwd;
#
# This is a faster version of getcwd.  It's also more dangerous because
# you might chdir out of a directory that you can't chdir back into.
    
sub fastcwd_ {
    my($odev, $oino, $cdev, $cino, $tdev, $tino);
    my(@path, $path);
    local(*DIR);

    my($orig_cdev, $orig_cino) = stat('.');
    ($cdev, $cino) = ($orig_cdev, $orig_cino);
    for (;;) {
	my $direntry;
	($odev, $oino) = ($cdev, $cino);
	CORE::chdir('..') || return undef;
	($cdev, $cino) = stat('.');
	last if $odev == $cdev && $oino == $cino;
	opendir(DIR, '.') || return undef;
	for (;;) {
	    $direntry = readdir(DIR);
	    last unless defined $direntry;
	    next if $direntry eq '.';
	    next if $direntry eq '..';

	    ($tdev, $tino) = lstat($direntry);
	    last unless $tdev != $odev || $tino != $oino;
	}
	closedir(DIR);
	return undef unless defined $direntry; # should never happen
	unshift(@path, $direntry);
    }
    $path = '/' . join('/', @path);
    if ($^O eq 'apollo') { $path = "/".$path; }
    # At this point $path may be tainted (if tainting) and chdir would fail.
    # Untaint it then check that we landed where we started.
    $path =~ /^(.*)\z/s		# untaint
	&& CORE::chdir($1) or return undef;
    ($cdev, $cino) = stat('.');
    die "Unstable directory path, current directory changed unexpectedly"
	if $cdev != $orig_cdev || $cino != $orig_cino;
    $path;
}
if (not defined &fastcwd) { *fastcwd = \&fastcwd_ }


# Keeps track of current working directory in PWD environment var
# Usage:
#	use Cwd 'chdir';
#	chdir $newdir;

my $chdir_init = 0;

sub chdir_init {
    if ($ENV{'PWD'} and $^O ne 'os2' and $^O ne 'dos' and $^O ne 'MSWin32') {
	my($dd,$di) = stat('.');
	my($pd,$pi) = stat($ENV{'PWD'});
	if (!defined $dd or !defined $pd or $di != $pi or $dd != $pd) {
	    $ENV{'PWD'} = cwd();
	}
    }
    else {
	my $wd = cwd();
	$wd = Win32::GetFullPathName($wd) if $^O eq 'MSWin32';
	$ENV{'PWD'} = $wd;
    }
    # Strip an automounter prefix (where /tmp_mnt/foo/bar == /foo/bar)
    if ($^O ne 'MSWin32' and $ENV{'PWD'} =~ m|(/[^/]+(/[^/]+/[^/]+))(.*)|s) {
	my($pd,$pi) = stat($2);
	my($dd,$di) = stat($1);
	if (defined $pd and defined $dd and $di == $pi and $dd == $pd) {
	    $ENV{'PWD'}="$2$3";
	}
    }
    $chdir_init = 1;
}

sub chdir {
    my $newdir = @_ ? shift : '';	# allow for no arg (chdir to HOME dir)
    $newdir =~ s|///*|/|g unless $^O eq 'MSWin32';
    chdir_init() unless $chdir_init;
    my $newpwd;
    if ($^O eq 'MSWin32') {
	# get the full path name *before* the chdir()
	$newpwd = Win32::GetFullPathName($newdir);
    }

    return 0 unless CORE::chdir $newdir;

    if ($^O eq 'VMS') {
	return $ENV{'PWD'} = $ENV{'DEFAULT'}
    }
    elsif ($^O eq 'MacOS') {
	return $ENV{'PWD'} = cwd();
    }
    elsif ($^O eq 'MSWin32') {
	$ENV{'PWD'} = $newpwd;
	return 1;
    }

    if (ref $newdir eq 'GLOB') { # in case a file/dir handle is passed in
	$ENV{'PWD'} = cwd();
    } elsif ($newdir =~ m#^/#s) {
	$ENV{'PWD'} = $newdir;
    } else {
	my @curdir = split(m#/#,$ENV{'PWD'});
	@curdir = ('') unless @curdir;
	my $component;
	foreach $component (split(m#/#, $newdir)) {
	    next if $component eq '.';
	    pop(@curdir),next if $component eq '..';
	    push(@curdir,$component);
	}
	$ENV{'PWD'} = join('/',@curdir) || '/';
    }
    1;
}


sub _perl_abs_path
{
    my $start = @_ ? shift : '.';

    {
	return '';
    }

	
