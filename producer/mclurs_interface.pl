#!/usr/bin/perl

use warnings;
use strict;
use ZMQ;
use ZMQ::Constants qw(:all);
use MCLURS::Snap;

my $snap = "tcp://10.10.10.46:7777";
my $zmq_ctx = ZMQ::Context->new();

# Set up ZMQ socket to talk to snapshotter
my $zmq_snapshot = $zmq_ctx->socket(ZMQ_REQ) or error("Unable to create ZMQ request socket to talk to snapshotter");

if ( defined($zmq_snapshot) ) {
    $zmq_snapshot->connect($snap) >= 0 or error("Cannot connect to snapshotter at $snap");
}

my $SNAP = MCLURS::Snap->new( skt => $zmq_snapshot, timeout => 3000 );

print "Probing the snapshotter\n";
unless ( $SNAP->probe() ) {
      print "Cannot talk to snapshotter: " . $SNAP->error()."\n"
      unless ( $SNAP->busy() );
}

die($SNAP->error()) unless ( $SNAP->setup() );     # Initialise the snapshotter
die($SNAP->error())  unless ( $SNAP->start() );  # Start capture

my $args = {};
$args->{start}  = 0;
$args->{length} = 1024;
$args->{count} = 1;
$args->{stream} = "test/test-stream-file";

# Send command to snapshot process
my $snap_name = $SNAP->snap( %{$args} );
unless ($snap_name) {
     "snapshot X snap command failed: " . $SNAP->error() . "\n";
     print $SNAP->error() . "\n";
}

#========== SUB ROUTINES =========#
sub get_time_offset {
	my $now_s_start = send1("Ztatus");
	print $now_s_start."\n";
	my $now_offset = time();
	my $now_s_end = send1("Ztatus");
	print $now_s_end."\n";
	
	my $offset = $now_offset-($now_s_end + $now_s_start)/2;
	
	print "offset: ".$offset."\n";
	my $now_test = send1("Ztatus");
	my $datestring = localtime($offset + $now_test);
	print "datetime from Ztatus test: $datestring\n";
	
	sleep 5;
	
	$now_test = send1("Ztatus");
	my $datestring = localtime($offset + $now_test);
	print "datetime from Ztatus test: $datestring\n";


}
