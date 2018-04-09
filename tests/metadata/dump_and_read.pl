use strict;
use warnings;

use Carp::Assert;
use Data::Dumper;


my $x = {
	  a => 1,
	  b => 2,
};

open my $fh, '>', 'dumper.txt' or die $!;
print $fh Data::Dumper->Dump([$x], ['x']);
close $fh;

my $data = do 'dumper.txt';


print "Importet:", Dumper $data;
assert($data->{a} == $x->{a});
print "data test: ", $x->{a}."\n";
