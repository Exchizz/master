#!/usr/bin/perl
use warnings;
use strict;
use Getopt::Long;
use Data::Dumper;
use IO::Async::Timer::Periodic;
use IO::Async::Loop;
use Fcntl qw(F_GETPIPE_SZ O_NONBLOCK  O_WRONLY F_SETPIPE_SZ);
use Storable qw(freeze);
use IO::Handle;

use ZMQ;
use ZMQ::Constants qw(:all);

# Flush stdout
$| = 1;


#============= Workflow ====================#
#      Init parameters
#	     |
#  	     v
#   create ZMQ to snapshot
#            |
#            v
#     Start snapshot
#	     |
#	     v
#    Get time offset from status       
#	     |
#            v
#      start eventloop

#      callback_metadata:
#		get timestamp(Ztatus)
#	        	
#		collect 

# Generate x kb/sek of chunksize
my $chunksize = 4096; # bytes
my $bandwidth = 4096; # bytes/sec
my $timer_send;
my $new_pipe_size = 4096;
my $get_metadata_interval = 1; # sec
my $numb = 0;
my $zero_mem;
my $sleep_s;
my $snap = "tcp://127.0.0.1:7777";
my $snap_length = 2048; # in samples
my $snap_count = 200;
my $snap_time_offset;

my $mode = "snapshot";
my $verbose = 0;
GetOptions ("chunksize=i"   => \$chunksize,
            "bandwidth=i"   => \$bandwidth,
            "metadata_interval=f"   => \$get_metadata_interval,
            "pipesize=i"   => \$new_pipe_size,
            "mode=s"   => \$mode,
            "verbose|v+"  => \$verbose) or die("Error in command line arguments\n");

print "Verbose: $verbose\n" if $verbose > 0;

print "mode: $mode\n";
# ARGV[0] and 1 contains arguments not consumed by GetOptions
my $data_pipe_path = $ARGV[0] || undef;
my $metadata_pipe_path = $ARGV[1] || undef;
die("No data and metadata pipe specified") unless ( $metadata_pipe_path && $data_pipe_path);

print "data named pipe: $data_pipe_path\n" if $verbose > 0;
print "metadata named pipe: $metadata_pipe_path\n" if $verbose > 0;

# Open data pipe
sysopen(my $fh_data_pipe, $data_pipe_path, O_WRONLY | O_NONBLOCK)         or die $!;
sysopen(my $fh_metadata_pipe, $metadata_pipe_path, O_WRONLY | O_NONBLOCK)         or die $!;

# Set pipe size
my ($initial_size, $new_size, $verify_size) = set_pipe_size($fh_data_pipe, $new_pipe_size);
print "Initial data pipe size: $initial_size, new size: $new_size, verify size: $verify_size\n" if $verbose > 0;

# Set fd to non blocking
select((select($fh_data_pipe), $| = 1)[0]);

my $zmq_ctx = ZMQ::Context->new();

# Set up ZMQ socket to talk to snapshotter
my $zmq_snapshot = $zmq_ctx->socket(ZMQ_REQ) or error("Unable to create ZMQ request socket to talk to snapshotter");

if ( defined($zmq_snapshot) ) {
    $zmq_snapshot->connect($snap) >= 0 or error("Cannot connect to snapshotter at $snap");
    undef $snap;
}

my $loop = IO::Async::Loop->new;

my $timer_get_metadata = IO::Async::Timer::Periodic->new(
   interval => $get_metadata_interval,
   on_tick =>\&callback_get_metadata,
);

my $id = 0;
sub callback_get_metadata {
	my (@args) = @_;
	my $ztatus_rsp = send1("Ztatus", $zmq_snapshot);
	my $now_ns = $ztatus_rsp->{now_ns};
	my $now_s = $now_ns/(1e9);

        my $datestring = localtime(snapshot_time_to_utc($now_s));
        print "Before sleep 5: $datestring\n";

# Write to metadata pipe
	my $data = $ztatus_rsp;
	$data->{'id'} = $id;
#	my $data_out = freeze($data);
	syswrite($fh_metadata_pipe, $data_out);
#store_fd($data, $fh_metadata_pipe);
	print "Writes to metadata pipe id: $id\n";
	$fh_metadata_pipe->flush();

	$id++;
}

if($mode eq "snapshot"){
	my $SNAP = zmq_setup($zmq_snapshot);
	my $args = {};
	$args->{start}  = 0;
	$args->{length} = $snap_length;
	$args->{count} = $snap_count;
	$args->{stream} = $data_pipe_path;
	
	# Send command to snapshot process
	my $snap_name = $SNAP->snap( %{$args} );
	
	unless ($snap_name) {
	     print "snapshot X snap command failed: " . $SNAP->error() . "\n";
	     print $SNAP->error() . "\n";
	}
	# Get timeoffset between time repported by snapshot and actual UTC(to be...) time
	# Wait for snapshot to be ready
	sleep 1;
	$snap_time_offset = get_time_offset();
}

if($mode eq "dummy"){
	$zero_mem = "X" x $chunksize;	
	substr($zero_mem,-1,1,'E');
	$sleep_s = $chunksize/$bandwidth; # 1/($bandwidth/$chunksize)


	$timer_send = IO::Async::Timer::Periodic->new(
	   interval => $sleep_s,
	   on_tick =>\&callback_send_pkg,
	);


	print "sleeping period: ".$sleep_s."\n" if $verbose > 0;
	print "Writing $chunksize bytes of data at $bandwidth bytes/sec\n" if $verbose > 0;
	$timer_send->start;
	$loop->add( $timer_send );
}

#=========== MAIN LOOP ================#
$timer_get_metadata->start;
$loop->add( $timer_get_metadata );
$loop->run;

#========= SUB ROUTINES =============#
sub snapshot_time_to_utc {
	my ($tmp) = @_;
	return $snap_time_offset + $tmp;
}

sub get_time_offset {
	
	my $now_s_start = get_snapshot_time();

	my $now_offset = time();

	my $now_s_end = get_snapshot_time();
	
	print "Start: $now_s_start, End: $now_s_end\n";
	my $offset = $now_offset-($now_s_end + $now_s_start)/2;

	my $now_test = get_snapshot_time();
	my $datestring = localtime($offset + $now_test);
	print "Before sleep 5: $datestring\n";

	sleep 5;
	
	$now_test = get_snapshot_time();
	$datestring = localtime($offset + $now_test);
	print "After sleep 5: $datestring\n";

	# Returns offset
	return $offset;
}


sub get_snapshot_time {
	my $tmp = send1("Ztatus",$zmq_snapshot);
	my $now = $tmp->{now_ns}/1e9;
	return $now;
}
sub send1{
	my ($cmd, $zmq_snapshot) = @_;
	
	my $m = ZMQ::Message->new($cmd);
	my $ret = $zmq_snapshot->sendmsg($m, 0);
	if($ret == 0){
		print "Cannot write command to snapshot...\n";
	}
	$m = $zmq_snapshot->recvmsg(0);
	if(!$m){
		print "Read error: $!\n";
	}

	print "request sent\n" if $verbose > 1;
	my $string = $m->data();
	my ($general_status, $info) = split(/\n/, $string);

	if($general_status !~ /^((?:OK|NO\:))\s+(.*)$/){
		print "Reply format error...\n";
		return;
	}
	if($1 ne "OK"){
		print "Reply NOT ok: $1\n";
		return;
	}
	# info: READER ACTIVE hix: 0x0000003882b800 [spl] tix: 0x00000037965000 [spl] now: 0x0013a1fc51c7fc [ns]
print $info."\n";
	my ($hix, $tix, $now_ns) = ($info =~ /READER\s*ACTIVE\s*hix:\s*(.*?)\s*\[spl\]\s*tix:\s*(.*?)\s*\[spl\]\s*now:\s*(.*?)\s*\[ns\]/);
	#my $now_s = bighex($now_ns)/(1e9);
	#printf "%02d:%02d:%02d\n", $now_s/3600, $now_s/60%60, $now_s%60;
#	print "hix: $hix\n";
#	print "tix: $tix\n";
#	print "now: $now_ns - $now_s\n";
#	print "general_status: ".$general_status."\n";
#	print "info: '".$info."'\n";
	return {"hix"=> $hix, "tix" => $tix, "now_ns" => bighex($now_ns)};

}


sub zmq_setup {
	my ($zmq_snapshot) = @_;
	use MCLURS::Snap;
	
	my $SNAP = MCLURS::Snap->new( skt => $zmq_snapshot, timeout => 3000 );
	
	
	print "Probing the snapshotter\n";
	unless ( $SNAP->probe() ) {
	      print "Cannot talk to snapshotter: " . $SNAP->error()."\n"
	      unless ( $SNAP->busy() );
	}
	
	die($SNAP->error()) unless ( $SNAP->setup() );     # Initialise the snapshotter
	die($SNAP->error())  unless ( $SNAP->start() );  # Start capture
	
	return ($SNAP);
}


sub set_pipe_size {
	my ($pipe_fh, $size) = @_;

	my $initial_size = fcntl($pipe_fh,F_GETPIPE_SZ,0);
	my $new_size = fcntl($pipe_fh, F_SETPIPE_SZ, int($new_pipe_size));
	my $verify_size = fcntl($pipe_fh,F_GETPIPE_SZ,0);

	return ($initial_size, $new_size, $verify_size);
}

sub callback_send_pkg {
	my (@args) = @_;
	my $data = get_chunk();
	print "nr. $numb ".length($data)."\n" if $verbose > 1;
	print $fh_data_pipe $data;
};




sub get_chunk {
	$numb++;
	substr($zero_mem, 0,length($numb), $numb);
	return $zero_mem;
}

sub bighex {
	my $hex = shift;

	print "Param hex: $hex\n";
	my $part = qr/[0-9a-fA-F]{8}/;
	print "$hex is not a 64-bit hex number\n"
	  unless my ($high, $low) = $hex =~ /^0x($part)($part)$/;

	return hex("0x$low") + (hex("0x$high") << 32);
}
