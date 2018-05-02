#!/usr/bin/perl
use warnings;
use strict;

use Pod::Usage;
use Getopt::Long qw( :config auto_version auto_help no_ignore_case bundling);
use lib 'lib';
use PubSub::Util;
use POSIX qw(mkfifo);
use IPC::Run qw( start  );
use Try::Tiny;
use lib 'lib';
use Net::RTCP::Packet;
use Net::RTP::Packet;
use Net::oRTP;
use IO::Handle;
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

our $verbose = 0;
my $errors = 0;
my $executable_path = undef;
my $data_pipe_path = undef;
my $metadata_pipe_path = undef;
my $consumer_parameters = ();

my $rtp_lport = 1337;
my $rtp_laddr = '127.0.0.1';

#================ Defaults ==============#
my @def_metadata_pipe_path = ($ENV{'METADATA_PIPE_PATH'}, "/tmp/pipe_subscriber_metadata");
my @def_data_pipe_path = ($ENV{'DATA_PIPE_PATH'}, "/tmp/pipe_subscriber_data");
my @def_executable_path = ($ENV{'PRODUCER_EXECUTABLE'}, "./consumer.sh");

GetOptions(
    'verbose|v+' =>\$verbose,
    'exec|e=s' => \$executable_path,
    'data_pipe|dp=s' => \$data_pipe_path,
    'metadata_pipe|mp=s' => \$metadata_pipe_path,
) or usage();

print "Verbose: $verbose\n" if $verbose > 0;

#============ Param. check ===========#
if ($executable_path){
	print "Executable: $executable_path\n" if $verbose > 0;
	error("\"$executable_path\" does not exist") unless -e $executable_path;

	if(-r $executable_path){
		print "\"$executable_path\" is readable\n" if $verbose > 0;
		if(-x $executable_path){
			print "\"$executable_path\" is exeutable\n" if $verbose > 0;
			
		} else {
			error("\"$executable_path\" is not executable\n");
		}
	} else {
		error("\"$executable_path\" is not readable\n");
	}

}

$metadata_pipe_path = PubSub::Util::apply_defaults($metadata_pipe_path, @def_metadata_pipe_path);
$data_pipe_path = PubSub::Util::apply_defaults($data_pipe_path, @def_data_pipe_path);
$executable_path = PubSub::Util::apply_defaults($executable_path, @def_executable_path);


#========== Param. check $ARGV ========#
#
@{$consumer_parameters} = @ARGV;

#========== Create media stream FIFO =====#
PubSub::Util::create_named_pipe($data_pipe_path);

#========= Create metadata FIFO =======#
PubSub::Util::create_named_pipe($metadata_pipe_path);

#=========== consumer start ===========#
my @command_prod = ($executable_path, $data_pipe_path, $metadata_pipe_path);

# Add additional parameters specified to the consumer
push(@command_prod, @{$consumer_parameters});

my $process = IO::Async::Process->new(
   command => \@command_prod,
   stdout => {
      on_read => sub {
         my ( $stream, $buffref ) = @_;
         while( $$buffref =~ s/^(.*)\n// ) {
            print "[ Consumer (stdout)]: '$1'\n";
         }

         return 0;
      },
   },

   on_finish => sub {
	my $exitcode = $_[1];
	print "Consumer stopped exitcode: $exitcode\n";
   },
);


#my $data_stream = PubSub::Util::create_pipe_stream($data_pipe_path, $callback_data);
#my $metadata_stream= PubSub::Util::create_pipe_stream($metadata_pipe_path, $callback_data);

#========== Open pipes ===========#
open(my $data_pipe_fh, "+< $data_pipe_path") or die "The FIFO file \"$data_pipe_path\" is missing\n";
$data_pipe_fh->autoflush(1);
#=========== Connect to RTCP socket ========="

# Create a receive object
my $rtp_session = new Net::oRTP('RECVONLY');

# Set it up
$rtp_session->set_blocking_mode( 0 );
$rtp_session->set_local_addr( "ff15::5", 1337, 1338);
$rtp_session->set_recv_payload_type( 0 );

open(my $fh, "<&=", $rtp_session->get_rtp_fd()) or die "Can't open RTP file descripter. $!";
$fh->blocking(0);

my $rtp_handler = IO::Async::Stream->new(
    read_handle  => $fh,
    on_read => sub {
	my ( $self, $buffref, $eof ) = @_;
	my $packet = new Net::RTP::Packet($$buffref);
	my $payload = $packet->{'payload'};
	print Dumper $payload;
	$payload = $payload =~ s/\n*$//r;
	print "[ Producer ]: ".$payload."\n";
	print $data_pipe_fh $packet->{payload};
	undef $$buffref;

	if( $eof ) {
	   print "EOF; last partial line is $$buffref\n";
	}
	
	return 0;
    }
);

open(my $fh1, "<&=", $rtp_session->get_rtcp_fd()) or die "Can't open RTCP file descripter. $!";
$fh->blocking(0);

my $rtcp_handler = IO::Async::Stream->new(
    read_handle  => $fh1,
    on_read => sub {
	my ( $self, $buffref, $eof ) = @_;
	my $packet = new Net::RTCP::Packet($$buffref);
	print Dumper $packet->{payload};
	undef $$buffref;

	if( $eof ) {
	   print "EOF; last partial line is $$buffref\n";
	}
	
	return 0;
    }
);

#============= MAIN ==============#
PubSub::Util::exit_on_error(2);

my $loop = IO::Async::Loop->new;
print "Running main\n";

register_signal_handler();

$loop->add( $process );
#$loop->add( $data_stream);
#$loop->add( $metadata_stream );
$loop->add( $rtp_handler );
$loop->add( $rtcp_handler );
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
    print "Deleting pipes\n";
    unlink $data_pipe_path if -p $data_pipe_path;
    unlink $metadata_pipe_path if -p $metadata_pipe_path;
exit(0);
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
