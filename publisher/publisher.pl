#!/usr/bin/perl
use warnings;
use strict;

use lib 'lib';
use PubSub::Util;

use Pod::Usage;
use Getopt::Long qw( :config auto_version auto_help no_ignore_case bundling);
use IPC::Run qw( start  );
use Net::oRTP;
use Try::Tiny;

use Net::SDP;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use IO::Async::Stream;

use Data::Dumper;
# Test node
#
# Author:     Mathias Neerup
# Created:    2018-09-04
# Last Edit:  
#=============== OPTIONS, GLOBALS, DEFAULTS ===============

$::VERSION = "0.1";

use Data::GUID;
my $guid = Data::GUID->new;
our $verbose = 0;
my $exec = "";
my $errors = 0;
my $executable_path = undef;
my $data_pipe_path = undef;
my $metadata_pipe_path = undef;
my $pub_uuid = substr($guid->as_string, 0, 13);
my $producer_parameters = ();

my $multicast_addr = "ff15::5";

my $buffer_size = 4096;
my $wellknown_address = "ff15::beef";

my @stream_descriptions = ();

#================ Defaults ==============#
my @def_metadata_pipe_path = ($ENV{'METADATA_PIPE_PATH'}, "/tmp/pipe_publisher_metadata");
my @def_data_pipe_path = ($ENV{'DATA_PIPE_PATH'}, "/tmp/pipe_publisher_data");
my @def_executable_path = ($ENV{'PRODUCER_EXECUTABLE'}, "./");

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
	PubSub::Util::error("\"$exec\" does not exist") unless -e $exec;

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
# Porpulate variables with values in order Parameter, environment, default
$metadata_pipe_path = PubSub::Util::apply_defaults($metadata_pipe_path, @def_metadata_pipe_path);
$data_pipe_path = PubSub::Util::apply_defaults($data_pipe_path, @def_data_pipe_path);
$executable_path = PubSub::Util::apply_defaults($executable_path, @def_executable_path);

print "Data pipe: ". $data_pipe_path." metadata pipe:".$metadata_pipe_path."\n";

#========== Param. check $ARGV ========#
#
@{$producer_parameters} = @ARGV;

#========= Create RTP session =========#
# Create a send/receive object
my $rtp_session = new Net::oRTP('SENDONLY');

# Set it up
$rtp_session->set_blocking_mode( 0 );
$rtp_session->set_remote_addr( $multicast_addr, 5004, 5005);
$rtp_session->set_multicast_ttl(10);
$rtp_session->set_multicast_loopback(1);
$rtp_session->set_send_payload_type( 0 );

# Create RTP session for Well-known RTP session
my $wk_rtp_session = new Net::oRTP('SENDONLY');

$wk_rtp_session->set_blocking_mode( 0 );
$wk_rtp_session->set_remote_addr( $wellknown_address, 5004, 5005);
$wk_rtp_session->set_multicast_ttl(10);
$wk_rtp_session->set_multicast_loopback(1);
$wk_rtp_session->set_send_payload_type( 0 );

#===== Create session description =====#

my $example_sdp = Net::SDP->new();

if(!-r 'example_session.sdp') {
	print "Example session does not exists\n";
}
#$example_sdp->parse_file( 'example_session.sdp' );
$example_sdp->session_name("My Session");
$example_sdp->session_info("A fun session");
$example_sdp->session_uri("http://www.ecs.soton.ac.uk/fun/");
$example_sdp->session_attribute('tool', "publisher.pl uuid: $pub_uuid");
 
 
# Add a Time Description
my $time = $example_sdp->new_time_desc();
$time->start_time_unix( time() );            # Set start time to now
$time->end_time_unix( time()+3600 ); # Finishes in one hour
 
 
# Add an Audio Media Description
my $audio = $example_sdp->new_media_desc( 'audio' );
$audio->address($multicast_addr);
$audio->address_type("IP6");
$audio->port(5004);
$audio->attribute('quality', 5);
 
# Add payload ID 96 with 16-bit, PCM, 22kHz, Mono
$audio->add_format( 96, 'audio/L16/220500/1' );
 
# Set the default payload ID to 0
$audio->default_format_num( 96 );
@stream_descriptions = ( $example_sdp );

#========== Create media stream FIFO =====#
PubSub::Util::create_named_pipe($data_pipe_path);

#========= Create metadata FIFO =======#
PubSub::Util::create_named_pipe($metadata_pipe_path);

#=========== Producer start ===========#
my @command_prod = ($executable_path.$exec, $data_pipe_path, $metadata_pipe_path);

# Add additional parameters specified to the producer
push(@command_prod, @{$producer_parameters});

my ($in_prod, $out_prod, $err_prod);
my $h_prod = start(\@command_prod, \$in_prod, \$out_prod, \$err_prod) or error("Unable to start producer");

my $callback_data = sub {
	my ( $self, $buffref, $eof ) = @_;
	$rtp_session->raw_rtp_send(123456, $$buffref);
	print "data incomming from data pipe\n" if $verbose > 1;
	undef $$buffref;
#	while( $$buffref =~ s/^(.*\n)// ) {
#	   print "From : $1";
#	}
	if( $eof ) {
	   print "EOF; last partial line is $$buffref\n";
	}
	return 0;
};

my $callback_metadata = sub {
	my ( $self, $buffref, $eof ) = @_;
	while( $$buffref =~ s/^(.*\n)// ) {
	   print "[ Producer (metadata)]: $1";
	}
	if( $eof ) {
	   print "EOF; last partial line is $$buffref\n";
	}
	return 0;
};
my $data_stream = PubSub::Util::create_pipe_stream($data_pipe_path, $callback_data, $buffer_size);
my $metadata_stream= PubSub::Util::create_pipe_stream($metadata_pipe_path, $callback_metadata, $buffer_size);

#============= MAIN ==============#
PubSub::Util::exit_on_error(2);

our $loop = IO::Async::Loop->new;

PubSub::Util::periodic_timer(1, \&callback_1sec);

# Periodically 
PubSub::Util::periodic_timer(1, \&callback_1sec_stream_advertisement);


print "Running main\n";

register_signal_handler();

$loop->add( $data_stream);
$loop->add( $metadata_stream );
$loop->run;

#============= Routines ===========#
sub callback_1sec {
	print "Tick!\n" if $main::verbose > 2;
	$out_prod = "";
	$h_prod->pump_nb;
	return unless $out_prod;
#	chomp $out_prod;
	my @lines =  split(/\n/,$out_prod);
	print "[ Producer (stdout) ]: $_\n" for @lines;
}

sub callback_1sec_stream_advertisement {
	print "Tick!\n" if $main::verbose > 2;
	for my $stream_description (@stream_descriptions){
		announce_stream($stream_description);
	}
}

sub announce_stream {
	my ($sdp) = @_;
	# Pack into SDP
	# Write SDP to wk_rtp_session
	
	# Generate SDP file
	my $sdp_encoded = $sdp->generate();

	# Send SDP encoded description to Wellknown RTP session
	$wk_rtp_session->raw_rtp_send(123456, $sdp_encoded);
}

sub register_signal_handler {
	$SIG{INT}=\&sigint_handler;
}

sub sigint_handler {
    print "Shutting down...\n";
    print "Killing producer...\n";
    my $retval = $h_prod->kill_kill || 2;
    print "Producer killed gracefully\n" if $retval eq 1;
    print "Producer killed\n" if $retval eq 0;
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
