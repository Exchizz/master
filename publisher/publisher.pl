#!/usr/bin/perl
use warnings;
use strict;
use Data::Dumper;
use lib 'lib';
use PubSub::Util;

use Pod::Usage;
use Getopt::Long qw( :config auto_version auto_help no_ignore_case bundling);
use IPC::Run qw( start  );
use Net::oRTP;
use Try::Tiny;

use JSON;

use DateTime;
use Net::SDP;
use Net::RTP::Packet;
use Net::RTCP::Packet;
use IO::Async::Loop;
use IO::Async::Timer::Periodic;
use IO::Async::Stream;

use Storable qw(nfreeze); 
use IO::Select;

# Test node
#
# Author:     Mathias Neerup
# Created:    2018-09-04
# Last Edit:  
#=============== Workflow ===============
#
#
#        init parameters
#	       |
#	       v
#     setup wellknown address 
#              |
#  	       v
#   waitfor publishers to register(10 seconds) 
#	       |
#              v
# Setup RTP session for HB-data 
#              |
#              v
#         run producer
#              |
#              v
#	run event loop.
#
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
my %known_occupied_groups = ();
my $wait_for_announcements = 5; # seconds
my $autogen_ip = 1;

# Generate random integer between 0 and 2^32
my $rtp_rnd_offset = int(rand(2**32));
my $rtp_clockrate = 2048; # block size = 4096, each sample is 2 bytes = 2048 samples pr. cunk = pr. packet
my $rtp_timestamp = $rtp_rnd_offset;

my $snap_time_offset = undef;

# Generate random ip(length 4, prepend 0)
my $rand_ip = sprintf("%04x",int(rand(2**16)));
my $nonessential = ""; 
my $essential = {};
my $scope = "ff15";
my $multicast_addr = "${scope}::1234";

#sprintf("%s::%s", $scope, $rand_ip);
print "Random ip: ".$multicast_addr."\n";

my $buffer_size = 4096;
my $wellknown_address = "ff15::beef";

my @stream_descriptions = ();
my $metadatafmt = "json";

#================ Defaults ==============#
my @def_metadata_pipe_path = ($ENV{'METADATA_PIPE_PATH'}, "/tmp/pipe_publisher_metadata");
my @def_data_pipe_path = ($ENV{'DATA_PIPE_PATH'}, "/tmp/pipe_publisher_data");
my @def_executable_path = ($ENV{'PRODUCER_EXECUTABLE'}, "./");

GetOptions(
    'verbose|v' => sub {$verbose++; print "verbose increased \n"},
    'exec|e=s' => \$exec,
    'autogen_ip=s' => \$autogen_ip,
    'metadatafmt=s' => \$metadatafmt,
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


# Create RTP session for Well-known RTP session
my $wk_rtp_session = new Net::oRTP('SENDRECV');

$wk_rtp_session->set_blocking_mode( 0 );
$wk_rtp_session->set_remote_addr( $wellknown_address, 5004, 5005);
$wk_rtp_session->set_multicast_ttl(10);
$wk_rtp_session->set_multicast_loopback(1);
$wk_rtp_session->set_send_payload_type( 0 );

$wk_rtp_session->set_local_addr( $wellknown_address, 5004, 5005);
$wk_rtp_session->set_recv_payload_type( 0 );

$wk_rtp_session->set_sdes_items('suas@batbox3');

# Open file descripter
open(my $fh1, "<&=", $wk_rtp_session->get_rtp_fd()) or die "Can't open RTP file descripter. $!";
open(my $wk_rtcp_fh, "<&=", $wk_rtp_session->get_rtcp_fd()) or die "Can't open RTP file descripter. $!";


if($autogen_ip){
	while( is_ipv6_taken($fh1, $multicast_addr) ){
		# Generate random ip(length 4, prepend 0)
		$rand_ip = sprintf("%04x",int(rand(2**16)));
	
		$multicast_addr = sprintf("ff15::%s",$rand_ip);
		print "New random IPv6 multicast ip: $multicast_addr\n";
	}
}

##========= Create RTP session =========#
# Create a send/receive object
my $rtp_session = new Net::oRTP('SENDONLY');
$rtp_session->set_sdes_items('suas@batbox3');

# Set it up
$rtp_session->set_blocking_mode( 0 );
$rtp_session->set_remote_addr( $multicast_addr, 5004, 5005);
$rtp_session->set_multicast_ttl(10);
$rtp_session->set_multicast_loopback(1);
$rtp_session->set_send_payload_type( 0 );
#===== Create session description =====#

my $example_sdp = Net::SDP->new();

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


sub callback_5sec{
	# Return if no nonessential data is available
	return unless($nonessential ne "");

	# Pr. custom metadata profile, set markbit to 1
	$wk_rtp_session->raw_rtp_send(0, $nonessential, 1); 
	print "Non-essential metadata sent to well known multicast group\n" if $verbose > 2;
};

sub unix_to_ntp {
	my $in_unix = shift;
#	my $epoch = 1527354387;

	my $ntp_epoch = DateTime->new(
	      year       => 1900,
	      month      => 1,
	      day        => 1,
	      hour       => 0,
	      minute     => 0,
	      second     => 0,
	  );  
	
	my $dt = DateTime->from_epoch( epoch => $in_unix );
	
	my $seconds = $ntp_epoch->subtract_datetime_absolute($dt)->seconds();
	my $sec_fraction = $ntp_epoch->subtract_datetime_absolute($dt)->nanoseconds();
	print "fraction:".$sec_fraction."\n";
	my $diff = $seconds<<32 + 1/$sec_fraction;
	print "diff: $diff\n";
	return $diff;
}

sub callback_1sec_sr_send {
	unless(exists $essential->{'hix'} && exists $essential->{'isp'}) {return};

#	my $hix = $essential->{'hix'};
#	my $now_s = $essential->{'now_ns'}/1e9;
#	my $snap_isp = $essential->{'isp'};
#	my $rtcp_sr_timestamp = get_64bit_ntp_from_sample($rtp_timestamp, $now_s, $hix, $snap_isp);
#	my $a = unix_to_ntp($rtcp_sr_timestamp);
#	print "Sent rtcp timestamp: $a\n";
#	$rtp_session->raw_rtcp_sr_send($a);
}


my $callback_data = sub {
	my ( $self, $buffref, $eof ) = @_;
	if( $eof ) {
	   print "EOF from datapipe\n";
	   return 0;
	}

	if(length($$buffref) > 0){
		$rtp_session->raw_rtp_send($rtp_timestamp, $$buffref);
		$rtp_timestamp += $rtp_clockrate;
		print "data incomming from data pipe\n" if $verbose > 5;
	} else {
		print "No data from datapipe\n";
	}

	undef $$buffref;
	return 0;
};

my $callback_metadata = sub {
	my ( $self, $buffref, $eof ) = @_;
	if( $eof ) {
	   print "EOF from medata pipe\n";
	   return 0;
	}

	#my $data = thaw($$buffref);

	my $data;
	my $essential_md;
	my $nonessential_md;

	print "Metadata format: $metadatafmt\n" if $verbose > 2;

	if($metadatafmt eq "json"){
		try {
			$data = decode_json($$buffref);
		} catch {
			print "Unable to decode json metadata: $_"; # not $@
		};
	} elsif($metadatafmt eq "yaml") {
		print "YAML NOT IMPLEMENTED\n";
		undef $$buffref;
		return 0;
	}
	
	if($data->{'nonessential'}){
		$nonessential = nfreeze($data->{'nonessential'});
	}

	if(exists $data->{'essential'}){
		my $essentialTmp = $data->{'essential'};

		# Merge new essential metadata into existing essential metadata
		$essential = {%$essentialTmp, %$essential};

		print Dumper $essential;
		if(exists $essential->{'hix'} && exists $essential->{'now_ns'}){
			print "Hix: ".$essential->{'hix'}." - now_ns:".$essential->{'now_ns'}."\n";
		}

		if(exists $essential->{'snap_time_offset'}){
			$snap_time_offset = $essential->{'snap_time_offset'};
			print "Setting snap_time_offset: $snap_time_offset\n";
		}

	}

	undef $$buffref;
	return 0;
};


my $wk_rtcp_handler = IO::Async::Stream->new(
    read_handle  => $wk_rtcp_fh,
    on_read => sub {
       my ( $self, $buffref, $eof ) = @_;
       my $packet = new Net::RTCP::Packet($$buffref);
       if($packet->{'bye'}){
              print "Receiving RTCP BYE from node ssrc: ".%{$packet->{'bye'}->{'ssrc'}}[0]."\n"
       }
       if(keys %{$packet->{'sdes'}}){
	      my ($ssrc) = %{$packet->{'sdes'}};
	      print "Receiving RTCP SDES from node ssrc: $ssrc\n";
       }
#       print Dumper $packet;
       undef $$buffref;

       if( $eof ) {
          print "EOF; last partial line is $$buffref\n";
       }
       return 0;
    }
);

my $data_stream = PubSub::Util::create_pipe_stream($data_pipe_path, $callback_data, $buffer_size);
my $metadata_stream= PubSub::Util::create_pipe_stream($metadata_pipe_path, $callback_metadata, $buffer_size);

#============= MAIN ==============#
PubSub::Util::exit_on_error(2);

our $loop = IO::Async::Loop->new;

PubSub::Util::periodic_timer(1, \&callback_1sec);
PubSub::Util::periodic_timer(5, \&callback_5sec);

# Periodically 
PubSub::Util::periodic_timer(1, \&callback_1sec_stream_advertisement);
PubSub::Util::periodic_timer(1, \&callback_1_sec_sdes_send);
PubSub::Util::periodic_timer(1, \&callback_1sec_sr_send);


print "Running main\n";

register_signal_handler();

$loop->add( $data_stream);
$loop->add( $metadata_stream );
$loop->add( $wk_rtcp_handler );
$loop->run;

#============= Routines ===========#
# This routine calculates the 64 bit timestamp using the snap_time_offset(calculated during startup), the random rtp_time, hix(high index) and the now, which is the time where hix-sample was in the buffer.


sub get_64bit_ntp_from_sample {
	my ($rtp_time, $now_s, $hix, $snap_isp) = @_;
	$snap_isp = $snap_isp/1e9;
	$hix = bighex($hix);
	print "hix dec: $hix\n";
	print "snap_time_offset: $snap_time_offset\n";
	print "rtp_rnd_offset: $rtp_rnd_offset\n";
	print "rtp_time: $rtp_time\n";
	my $rtcp_time = $now_s + $snap_isp*(($rtp_time - $rtp_rnd_offset) - $hix) + $snap_time_offset;
	print "RTCP time: $rtcp_time\n";
	return $rtcp_time;
}
sub bighex {
	my $hex = shift;

	print "Param hex: $hex\n";
	my $part = qr/[0-9a-fA-F]{8}/;
	print "$hex is not a 64-bit hex number\n"
	  unless my ($high, $low) = $hex =~ /^0x($part)($part)$/;

	return hex("0x$low") + (hex("0x$high") << 32);
}
sub is_ipv6_taken {
	my ($fh, $needle) = @_;


	sub check_wellknown_session {
		my ($fh, $needle) = @_;
		print "Callback invoked...\n" if $verbose > 3;
		my @ready = IO::Select->new($fh)->can_read(1);
	
		if(@ready){
			# This works as we've only added one fh to watch..
			my ($ready_fd) = @ready;
			my $bytes_read = sysread($ready_fd, my $buffer,4096);
			my $packet = new Net::RTP::Packet($buffer);
		        my $payload = $packet->{'payload'};
		
			my $sdp = Net::SDP->new($payload);
			my $media_list = $sdp->media_desc_arrayref();
		        for my $media (@$media_list){
				my $multicastaddress = $media->address;
				my $multicastport = $media->port;
		
				# We got a conflict
				print "$multicastaddress vs. $needle\n" if $verbose >3;
				if($multicastaddress eq $needle){
					return 1;
				}
			}
		}	
		return 0;
	}
	
	if(PubSub::Util::waitfor( sub { check_wellknown_session($fh1, $needle) } , $wait_for_announcements, 1.0 )){
		print "Ipv6 multicast group conflict\n";
		return 1;
	} else {
		print "No IPv6 multicast conflict\n";
		return 0;
	}
}


sub callback_1sec {
	print "Tick!\n" if $main::verbose > 2;
	$out_prod = "";
	$h_prod->pump_nb;
	return unless $out_prod;
#	chomp $out_prod;
	my @lines =  split(/\n/,$out_prod);
	print "[ Producer (stdout) ]: $_\n" for @lines;

}
sub callback_1_sec_sdes_send {
	print "Sends RTCP SDES \n" if $verbose > 3;
	$wk_rtp_session->raw_rtcp_sdes_send();
	$rtp_session->raw_rtcp_sdes_send();
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

	print $sdp_encoded."\n";
	# Send SDP encoded description to Wellknown RTP session
	$wk_rtp_session->raw_rtp_send(123456, $sdp_encoded);
}

sub register_signal_handler {
	$SIG{INT}=\&sigint_handler;
}

sub sigint_handler {
    print "Shutting down...\n";
    print "Sending bye to multicast group\n" if $verbose > 2;
    $wk_rtp_session->raw_rtcp_bye_send("Gracefully shutdown");
    $rtp_session->raw_rtcp_bye_send("Gracefully shutdown");
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
