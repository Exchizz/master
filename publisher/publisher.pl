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

our $verbose = 0;
my $exec = "";
my $errors = 0;
my $executable_path = undef;
my $data_pipe_path = undef;
my $metadata_pipe_path = undef;
my $producer_parameters = ();

#================ Defaults ==============#
my @def_metadata_pipe_path = ($ENV{'METADATA_PIPE_PATH'}, "/tmp/pipe_publisher_metadata");
my @def_data_pipe_path = ($ENV{'DATA_PIPE_PATH'}, "/tmp/pipe_publisher_data");
my @def_executable_path = ($ENV{'PRODUCER_EXECUTABLE'}, "./producer.sh");

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
print Dumper PubSub::Util::apply_defaults($metadata_pipe_path, @def_metadata_pipe_path);
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
$rtp_session->set_remote_addr( 'ff15::5', 1337, 1338);
$rtp_session->set_multicast_ttl(10);
$rtp_session->set_multicast_loopback(1);
$rtp_session->set_send_payload_type( 0 );

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
	print "sends RAW RTP packet\n" if $verbose > 1;
	$rtp_session->raw_rtp_send(123456, $$buffref);
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
my $data_stream = PubSub::Util::create_pipe_stream($data_pipe_path, $callback_data);
my $metadata_stream= PubSub::Util::create_pipe_stream($metadata_pipe_path, $callback_metadata);

#============= MAIN ==============#
PubSub::Util::exit_on_error(2);

our $loop = IO::Async::Loop->new;

PubSub::Util::periodic_timer(1, \&callback_1sec);


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
