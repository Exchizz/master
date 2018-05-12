#!/usr/bin/perl
use warnings;
use strict;
use Getopt::Long;
use Data::Dumper;
use Time::HiRes;
use IO::Async::Timer::Periodic;
use IO::Async::Loop;
use ZMQ::FFI;
use ZMQ::FFI::Constants qw(ZMQ_REQ);
use Fcntl qw(F_GETPIPE_SZ O_NONBLOCK  O_WRONLY F_SETPIPE_SZ);

# Flush stdout
$| = 1;

# Generate x kb/sek of chunksize
my $chunksize = undef; # bytes
my $bandwidth = undef; # bytes/sec
my $new_pipe_size = 4096;
my $get_metadata_interval = 1; # sec

my $verbose = 0;
GetOptions ("chunksize=i"   => \$chunksize,
            "bandwidth=i"   => \$bandwidth,
            "metadata_interval=f"   => \$get_metadata_interval,
            "pipesize=i"   => \$new_pipe_size,
            "verbose|v+"  => \$verbose)
or die("Error in command line arguments\n");

print "Verbose: $verbose\n" if $verbose > 0;




# ARGV[0] and 1 contains arguments not consumed by GetOptions
my $data_pipe_path = $ARGV[0] || undef;
my $metadata_pipe_path = $ARGV[1] || undef;
die("No data and metadata pipe specified") unless ( $metadata_pipe_path && $data_pipe_path);

print "data named pipe: $data_pipe_path\n" if $verbose > 0;
print "metadata named pipe: $metadata_pipe_path\n" if $verbose > 0;

sysopen(my $fh_data_pipe, $data_pipe_path, O_WRONLY | O_NONBLOCK)         or die $!;
#sysopen(my $fh_metadata_pipe, "> $metadata_pipe_path", O_NONBLOCK)         or die $!;

my $pipe_sz = fcntl($fh_data_pipe,F_GETPIPE_SZ,0);
print "data pipe size: $pipe_sz\n";

print "Setting pipe to $new_pipe_size\n";
my $new = fcntl($fh_data_pipe, F_SETPIPE_SZ, int($new_pipe_size));
print "New pipe size: $new\n";

my $zero_mem = "X" x $chunksize;
my $numb = 0;

sub get_chunk {
	substr($zero_mem, 0,length($numb), $numb);
	$numb++;
	return $zero_mem;
}

my $sleep_s = $chunksize/$bandwidth; # 1/($bandwidth/$chunksize)
print "sleeping period: ".$sleep_s."\n" if $verbose > 0;
print "Writing $chunksize bytes of data at $bandwidth bytes/sec\n" if $verbose > 0;

select((select($fh_data_pipe), $| = 1)[0]);


my $context = ZMQ::FFI->new();

# Socket to talk to server
my $requester = $context->socket(ZMQ_REQ);
$requester->connect('tcp://batbox3:7777');

print "Connected to snapshot\n" if $verbose > 0;

my $loop = IO::Async::Loop->new;

sub callback_send_pkg {
	my (@args) = @_;
	my $data = get_chunk();
	print "nr. $numb ".length($data)."\n";
	print $fh_data_pipe $data;
};

my $timer_send = IO::Async::Timer::Periodic->new(
   interval => $sleep_s,
   on_tick =>\&callback_send_pkg,
);

sub callback_get_metadata {
	my (@args) = @_;
	my $ztatus_rsp = send1("Ztatus");
	print Dumper \$ztatus_rsp;
}
my $timer_get_metadata = IO::Async::Timer::Periodic->new(
   interval => $get_metadata_interval,
   on_tick =>\&callback_get_metadata,
);
$timer_get_metadata->start;
$timer_send->start;
$loop->add( $timer_send );
$loop->add( $timer_get_metadata );
$loop->run;

#========= SUB ROUTINES =============#
sub send1{
	my ($cmd) = @_;
	
	$requester->send($cmd);
	print "request sent" if $verbose > 0;
	my $string = $requester->recv();
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
	my ($hix, $tix, $now_ns) = ($info =~ /READER\s*ACTIVE\s*hix:\s*(.*?)\s*\[spl\]\s*tix:\s*(.*?)\s*\[spl\]\s*now:\s*(.*?)\s*\[ns\]/);
	my $now_s = hex($now_ns)/(1e9);
	printf "%02d:%02d:%02d\n", $now_s/3600, $now_s/60%60, $now_s%60;
	print "hix: $hix\n";
	print "tix: $tix\n";
	print "now: $now_ns - $now_s\n";
	print "general_status: ".$general_status."\n";
	print "info: '".$info."'\n";
	return {"hix"=> $hix, "tix" => $tix, "now_ns" => hex($now_ns)};
}
