#!/usr/bin/perl
use warnings;
use strict;
use Getopt::Long;
use Data::Dumper;
use Time::HiRes;

# Flush stdout
$| = 1;

# Generate x kb/sek of chunksize
my $chunksize = undef; # bytes
my $bandwidth = undef; # bytes/sec

my $verbose = 0;
GetOptions ("chunksize=i"   => \$chunksize,
            "bandwidth=i"   => \$bandwidth,
            "verbose|v+"  => \$verbose)
or die("Error in command line arguments\n");

# ARGV[0] and 1 contains arguments not consumed by GetOptions
my $data_pipe_path = $ARGV[0] || undef;
my $metadata_pipe_path = $ARGV[1] || undef;
die("No data and metadata pipe specified") unless ( $metadata_pipe_path && $data_pipe_path);

print "Verbose: $verbose\n" if $verbose > 0;
my $zero_mem = "X" x $chunksize;
my $numb = 0;

sub get_chunk {
	substr($zero_mem, 0,length($numb), $numb);
	$numb++;
	return $zero_mem;
}

my $sleep_s = $chunksize/$bandwidth; # 1/($bandwidth/$chunksize)
print "sleeping period: ".$sleep_s."\n" if $verbose > 0;
while(1){
	print get_chunk();
	Time::HiRes::sleep($sleep_s); #.1 seconds
}
