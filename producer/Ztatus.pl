use Data::Dumper;
use strict;
use warnings;
use v5.10;

use ZMQ::FFI;
use ZMQ::FFI::Constants qw(ZMQ_REQ);

my $context = ZMQ::FFI->new();

# Socket to talk to server
my $requester = $context->socket(ZMQ_REQ);
my $port = 7777;
$requester->connect('tcp://batbox3:'.$port);
say "connected!";
for(1..5){
	sleep 2;
	send1("Ztatus");
}

sub send1{
	my ($cmd) = @_;
	
	$requester->send($cmd);
	say "request sent";
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
}
