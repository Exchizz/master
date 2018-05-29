use Data::Dumper;
use strict;
use warnings;
use v5.10;

use ZMQ::FFI;
use ZMQ::FFI::Constants qw(ZMQ_REQ);
use DateTime;

my $context = ZMQ::FFI->new();

sub getnow{
	my $epoch = shift;
	my $dt = DateTime->from_epoch( epoch => $epoch );
	return $dt;
}
# Socket to talk to server
my $requester = $context->socket(ZMQ_REQ);
my $port = 7777;
$requester->connect('tcp://batbox3:'.$port);

print "Calculating offset\n";
my $now_s_start = send1("Ztatus");
my $now_offset = time();
my $now_s_end = send1("Ztatus");
#print $now_s_start."\n";
#print $now_s_end."\n";

my $offset = $now_offset-($now_s_end + $now_s_start)/2;

print "Offset: $offset\n";
my $now_test = send1("Ztatus");
my $datestring = getnow($offset + $now_test);
my $nowy = getnow(time());
print "Datetime from Ztatus: $datestring realclock: ".$nowy."\n";

print "Sleeping 5 seconds\n";
sleep 5;

$now_test = send1("Ztatus");
my $datestring = getnow($offset + $now_test);
my $nowz = getnow(time());
print "Datetime from Ztatus: $datestring realclock: ".$nowz."\n";

print "localtime: ".localtime()."\n";

sub send1{
	my ($cmd) = @_;
	
	$requester->send($cmd);
#	say "request sent";
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
	my $now_s = bighex($now_ns)/(1e9);
#	print $info."\n";
	return $now_s;
#	printf "%02d:%02d:%02d\n", $now_s/3600, $now_s/60%60, $now_s%60;
#	print "hix: $hix\n";
#	print "tix: $tix\n";
#	print "now: $now_ns - $now_s\n";
#	print "general_status: ".$general_status."\n";
#	print "info: '".$info."'\n";
}


sub bighex {
       my $hex = shift;
       my $part = qr/[0-9a-fA-F]{8}/;
       print "$hex is not a 64-bit hex number\n"
        unless my ($high, $low) = $hex =~ /^0x($part)($part)$/;
       return hex("0x$low") + (hex("0x$high") << 32);
}
