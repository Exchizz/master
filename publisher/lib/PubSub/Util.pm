package PubSub::Util;
use strict;
use warnings;
use Fcntl qw(F_GETPIPE_SZ O_NONBLOCK  O_WRONLY F_SETPIPE_SZ O_RDONLY);
 
use POSIX qw(mkfifo);

sub rnd_str {
	my ($len) = @_;
	my @chars = ("A".."Z", "a".."z");
	my $string;
	$string .= $chars[rand @chars] for 1..$len;
	return $string;
}


# Wait for a condition to become true
sub waitfor {
    my ( $cond, $duration, $interval ) = @_;
    my $elapsed = 0;
    my $stop    = 0;

    return undef unless ( defined($cond) and ref($cond) eq 'CODE' );
    $duration ||= 5.0;          # Max waiting time in seconds, default 5s
    $interval ||= $duration /
      100.0;    # Interval between checks of condition, default duration/10.

    debug( 3,
        sprintf( "Waitfor: duration %f and interval %f", $duration, $interval )
    );
    until ( $elapsed >= $duration or $stop ) {
        $elapsed += $interval;
        $stop = &{$cond}();
        sleep($interval);
        debug( 4,
            sprintf( "Waitfor: wake from sleep at elapsed %f", $elapsed ) );
    }
    debug(
        3,
        sprintf(
            "Waitfor: loop completed, elapsed %f of %f",
            $elapsed, $duration
        )
    );
    return $stop;
}

sub debug {
    local $| = 1;
    my $lvl = shift;

    print @_, "\n" if ( $lvl < $main::verbose );
}


sub apply_defaults {
	my $res = undef;
	for my $s (@_) {
		$res = $res || $s;
		last if ( defined $res );
	}
	return $res;
}

sub default {
	my ($str_ptr, $new_val) = @_;
	$$str_ptr = $new_val if $$str_ptr eq "" or $$str_ptr eq undef;
}

sub create_pipe_stream {
	my ($pipe_path,$callback, $readlen) = @_;

#	open(my $fh, "+< $pipe_path") or die "The FIFO file \"$pipe_path\" is missing\n";
	sysopen(my $fh, $pipe_path, O_RDONLY | O_NONBLOCK)         or die $!;

	my $pipe_sz = fcntl($fh,F_GETPIPE_SZ,0);
	print "data pipe size: $pipe_sz\n" if $main::verbose > 0;

	print "Setting pipe to $readlen\n" if $main::verbose > 0;
	my $new = fcntl($fh, F_SETPIPE_SZ, int($readlen));
	print "New pipe size: $new\n" if $main::verbose > 0;

	my $stream = IO::Async::Stream->new(
	   read_handle  => $fh,
	   read_len => $readlen,
	   on_read => $callback,
	);
	undef $fh;
	return $stream;
}

sub create_named_pipe {
	my ($pipe_path) = @_;
	my $mode = "0666";
	# Check if pipe exists and is readable + writeable
	if(-p $pipe_path){
		print "$pipe_path exists\n";
	} else {
		if (mkfifo($pipe_path, $mode)) {
			print "Pipe successfully created at $pipe_path\n" if $main::verbose > 0;
		} else {
			print "Unable to create data pipe";
		}
	}
	chmod 0777, $pipe_path;
}
sub periodic_timer {
	my ($interval, $callback) = @_;
	my $timer = IO::Async::Timer::Periodic->new(
	   interval => $interval,
	   on_tick => $callback,
	);
	$timer->start;
	$main::loop->add( $timer );
}

sub error {
    local $| = 1;
    my $msg = join( '', @_ );

    $msg .= ": $!\n" if ( $msg !~ m/\n/m and $! );

    print STDERR $msg if ( $main::verbose >= 0 );
    $main::errors++;
}
sub exit_on_error {
    my $with_usage = $_[1];

    if ($main::errors) {
    	print "errors: $main::errors\n";
        if ($with_usage) {
            pod2usage(
                -exitval => $_[0],
                -verbose => ( $main::verbose > 2 ? 2 : $main::verbose ),
                -output  => \*STDERR
            );
        }
        else {
            print STDERR "Exiting $$ due to errors\n";
        }
        exit $_[0];
    }
}

1;
