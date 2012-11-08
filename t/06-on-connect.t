#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis(timeout => 1);
END { $c->() if $c }

subtest 'on_connect' => sub {
  my $r;
  ok($r = Redis->new(server => $srv, on_connect => sub { shift->incr('on_connect') }),
    'connected to our test redis-server');
  is($r->get('on_connect'), 1, '... on_connect code was run');

  ok($r = Redis->new(server => $srv, on_connect => sub { shift->incr('on_connect') }),
    'new connection is up and running');
  is($r->get('on_connect'), 2, '... on_connect code was run again');

  ok($r = Redis->new(reconnect => 1, server => $srv, on_connect => sub { shift->incr('on_connect') }),
    'new connection with reconnect enabled');
  is($r->get('on_connect'), 3, '... on_connect code one again perfect');

  $r->quit;
  is($r->get('on_connect'), 4, '... on_connect code works after reconnect also');
};


done_testing();
