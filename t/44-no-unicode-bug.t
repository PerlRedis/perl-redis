#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis();
END { $c->() if $c }

ok(my $r = Redis->new(server => $srv), 'connected to our test redis-server');
my $s2 = my $s1 = "test\x{80}";
utf8::upgrade($s1); # no need to use 'use utf8' to call this
utf8::downgrade($s2); # no need to use 'use utf8' to call this
ok ($s1 eq $s2, 'assume test string are considered identical by perl');
$r->set($s1 => 42);
is $r->get($s2), 42, "same binary strings should point to same keys";

## All done
done_testing();
