#!perl

use warnings;
use strict;
use Test::More;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($guard, $srv) = redis();

ok(my $r = Redis->new(server => $srv), 'connected to our test redis-server');

## Try to read from server (nothing sent, so nothing to read)
## But kill if we block
local $SIG{ALRM} = sub { kill 9, $$ };
alarm(2);
ok(!Redis::__try_read_sock($r->{sock}), "Nothing to read, didn't block");
alarm(0);

done_testing();
