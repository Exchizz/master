use Data::Dumper;
use strict;
use warnings;
use v5.10;

use ZMQ::FFI;
use ZMQ::FFI::Constants qw(ZMQ_REQ);

my $context = ZMQ::FFI->new();

# Socket to talk to server
my $requester = $context->socket(ZMQ_REQ);
my $port = $ARGV[1];
print "port: $port\n";
$requester->connect('tcp://10.10.10.46:'.$port);
say "connected!";
#send1("Zstatus");
send1($ARGV[0]);

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
	print "hix: $hix\n";
	print "tix: $tix\n";
	print "now: $now_ns\n";
	print "general_status: ".$general_status."\n";
	print "info: '".$info."'\n";
}
