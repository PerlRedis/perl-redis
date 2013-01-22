#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis;
use lib 't/tlib';
use Test::SpawnFakeRedis;

my ($kill_server, $address) = redis();
END { 
    $kill_server->() if $kill_server; 
    exit 0; # don't let a bad status sometimes kill this test
}

ok(my $o = Redis->new(server => $address, timeout => 2),
  'We should be able to connect to our Redis server with a timeout value');
ok($o->ping, '... and ping it');
## Commands operating on string values

like( 
  exception { $o->set(foo => 'bar') },
  qr/^Read timeout executing 'set'/,
  '... and a read timeout should throw an exception'
);
done_testing;
