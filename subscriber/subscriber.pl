#!/usr/bin/perl
use warnings;
use strict;

use Pod::Usage;
use Getopt::Long qw( :config auto_version auto_help no_ignore_case bundling);
use POSIX qw(mkfifo);
use IPC::Run qw( start  );
use Try::Tiny;
use lib 'lib';
use Net::RTCP;
use Data::Dumper;

use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use IO::Async::Stream;
use IO::Async::Process;
use IO::Async::Socket;

# Test node
#
# Author:     Mathias Neerup
# Created:    2018-09-04
# Last Edit:  
#=============== OPTIONS, GLOBALS, DEFAULTS ===============

$::VERSION = "0.1";

my $verbose = 0;
my $exec = "";
my $errors = 0;
my $executable_path = "./";
my $data_pipe_path = "";
my $metadata_pipe_path = "";
my $consumer_parameters = ();

my $rtcp_lport = 1338;
my $rtcp_laddr = '127.0.0.1';


GetOptions(
    'verbose|v+' =>\$verbose,
    'exec|e=s' => \$exec,
    'data_pipe|dp=s' => \$data_pipe_path,
    'metadata_pipe|mp=s' => \$metadata_pipe_path,
) or usage();

print "Verbose: $verbose\n" if $verbose > 0;

#============ Param. check ===========#
if ($exec){
	print "Executable: $exec\n" if $verbose > 0;
	error("\"$exec\" does not exist") unless -e $exec;

	if(-r $exec){
		print "\"$exec\" is readable\n" if $verbose > 0;
		if(-x $exec){
			print "\"$exec\" is exeutable\n" if $verbose > 0;
			
		} else {
			error("\"$exec\" is not executable\n");
		}
	} else {
		error("\"$exec\" is not readable\n");
	}

}
#========== Param. check $ARGV ========#
#
@{$consumer_parameters} = @ARGV;

#========== Create media stream FIFO =====#
create_named_pipe($data_pipe_path);

#========= Create metadata FIFO =======#
create_named_pipe($metadata_pipe_path);

#=========== consumer start ===========#
my @command_prod = ($executable_path.$exec, $data_pipe_path, $metadata_pipe_path);

# Add additional parameters specified to the consumer
push(@command_prod, @{$consumer_parameters});

my $process = IO::Async::Process->new(
   command => \@command_prod,
   stdout => {
      on_read => sub {
         my ( $stream, $buffref ) = @_;
         while( $$buffref =~ s/^(.*)\n// ) {
            print "consumer: '$1'\n";
         }

         return 0;
      },
   },

   on_finish => sub {
	print "Consumer stopped\n";
   },
);


my $data_stream = create_pipe_stream($data_pipe_path);
my $metadata_stream= create_pipe_stream($metadata_pipe_path);


#=========== Connect to RTCP socket ========="
my $rtcp = new Net::RTCP(
	LocalPort=>$rtcp_lport,
	LocalAddr=>$rtcp_laddr,
) || error("Unable to connect to socket: $rtcp_lport, laddr: $rtcp_laddr");

my $rtcp_handle = IO::Async::Handle->new(
   read_handle => $rtcp,
   on_read_ready  => sub {
	print Dumper @_;
	print "data...\n";
   },
);
#============= MAIN ==============#
exit_on_error(2);

my $loop = IO::Async::Loop->new;

#periodic_timer(1, \&callback_1sec);


print "Running main\n";

register_signal_handler();

$loop->add( $process );
$loop->add( $data_stream);
$loop->add( $metadata_stream );
$loop->add( $rtcp_handle );
$loop->run;
#============= Routines ===========#

sub register_signal_handler {
	$SIG{INT}=\&sigint_handler;
}

sub sigint_handler {
    print "Shutting down...\n";
    #print "Killing consumer...\n";
    #my $retval = $h_prod->kill_kill || 2;
    #print "consumer killed gracefully\n" if $retval eq 1;
    #print "consumer killed\n" if $retval eq 0;
    exit(0);
}

sub create_pipe_stream {
	my ($pipe_path,$fh) = @_;

	open($fh, "+< $pipe_path") or die "The FIFO file \"$pipe_path\" is missing\n";
	my $stream = IO::Async::Stream->new(
	   read_handle  => $fh,
	   on_read => sub {
	      my ( $self, $buffref, $eof ) = @_;
	      while( $$buffref =~ s/^(.*\n)// ) {
	         print "From \"$pipe_path\": $1";
	      }
	      if( $eof ) {
	         print "EOF; last partial line is $$buffref\n";
	      }
	
	      return 0;
	   }
	);
	return $stream;
}

sub create_named_pipe {
	my ($pipe_path) = @_;
	my $mode = "0600";
	# Check if pipe exists and is readable + writeable
	if(-p $pipe_path){
		print "$pipe_path exists\n";
	} else {
		if (mkfifo($pipe_path, $mode)) {
			print "Pipe successfully created at $pipe_path\n" if $verbose > 0;
		} else {
			error("Unable to create data pipe");
		}
	}
}
sub callback_1sec {
	print "Tick!\n" if $verbose > 2;
	#$out_prod = "";
	#$h_prod->pump_nb;
	#return unless $out_prod;
#	chomp $out_prod;
	#my @lines =  split(/\n/,$out_prod);
	#print "[ consumer ]: $_\n" for @lines;
}


sub periodic_timer {
	my ($interval, $callback) = @_;
	my $timer = IO::Async::Timer::Periodic->new(
	   interval => $interval,
	   on_tick => $callback,
	);
	$timer->start;
	$loop->add( $timer );
}

sub error {
    local $| = 1;
    my $msg = join( '', @_ );

    $msg .= ": $!\n" if ( $msg !~ m/\n/m and $! );

    print STDERR $msg if ( $verbose >= 0 );
    $errors++;
}
sub exit_on_error {
    my $with_usage = $_[1];

    if ($errors) {
        if ($with_usage) {
            pod2usage(
                -exitval => $_[0],
                -verbose => ( $verbose > 2 ? 2 : $verbose ),
                -output  => \*STDERR
            );
        }
        else {
            print STDERR "Exiting $$ due to errors\n";
        }
        exit $_[0];
    }
}

sub usage {
    pod2usage(
        -exitval => 1,
        -verbose => ( $verbose > 2 ? 2 : $verbose ),
        -output  => \*STDERR
    ) if ( $verbose >= 0 );
    exit 1;
}

=head1 NAME

array-cmd -- listener daemon for commands from the array master.

=head1 SYNOPSIS

	script.pl --stuff
