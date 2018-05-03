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


use lib 'lib';
use Net::RTCP::Packet;
use Net::RTP::Packet;


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

our $verbose = 0;
my $errors = 0;

my $wellknown_address = "ff15::beef";

#================ Defaults ==============#

GetOptions(
    'verbose|v+' =>\$verbose,
) or usage();

print "Verbose: $verbose\n" if $verbose > 0;

#========= Create RTP session =========#
# Create RTP session for Well-known RTP session
my $wk_rtp_session = new Net::oRTP('RECVONLY');

$wk_rtp_session->set_blocking_mode( 0 );
$wk_rtp_session->set_local_addr( $wellknown_address, 5004, 5005);
$wk_rtp_session->set_recv_payload_type( 0 );

open(my $fh, "<&=", $wk_rtp_session->get_rtp_fd()) or die "Can't open RTP file descripter. $!";
$fh->blocking(0);

my $wk_rtp_handler = IO::Async::Stream->new(
	read_handle  => $fh,
	on_read => sub {
		my ( $self, $buffref, $eof ) = @_;
		my $packet = new Net::RTP::Packet($$buffref);
		my $payload = $packet->{'payload'};
		undef $$buffref;
		
		if( $eof ) {
		   print "EOF; last partial line is $$buffref\n";
		}
		 
		my $sdp = Net::SDP->new($payload);
		my $tool = $sdp->session_attribute( 'tool' );
		my $out = "";
		my $media_list = $sdp->media_desc_arrayref();
		for my $media (@$media_list){
			$out.= $media->default_format().", ";
			$out.= "Multicast: ". $media->address().":".$media->port()."\n";
		}
		my $mg = "";
		print "SDP from '$tool', format: $out";
		print $sdp->generate() if $verbose > 0;
		print "-"x100;
		print "\n";
		return 0;
	}
);
#============= MAIN ==============#
PubSub::Util::exit_on_error(2);

our $loop = IO::Async::Loop->new;



print "Running main\n";

register_signal_handler();

$loop->add( $wk_rtp_handler  );
$loop->run;

#============= Routines ===========#
sub register_signal_handler {
	$SIG{INT}=\&sigint_handler;
}

sub sigint_handler {
    print "Shutting down...\n";
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
