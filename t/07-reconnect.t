#!perl

use warnings;
use strict;
use Test::More;
use Test::Exception;
use Test::Deep;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis();
END { $c->() if $c }


ok(my $r = Redis->new(reconnect => 0, server => $srv), 'connected to our test redis-server');
ok($r->quit, 'close connection to the server');
dies_ok { $r->set( reconnect => 1 )} 'send ping without reconnect';

ok($r = Redis->new(reconnect => 1, server => $srv), 'connected to our test redis-server');
ok($r->quit, 'close connection to the server');
ok($r->set( reconnect => 1 ), 'send ping with reconnect');

done_testing();
