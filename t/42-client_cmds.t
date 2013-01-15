#!perl

use warnings;
use strict;
use Test::More;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis(requires_version => '2.6.9');
END { $c->() if $c }

subtest 'client_{set|get}name commands' => sub {
  ok(my $r = Redis->new(server => $srv), 'connected to our test redis-server');

  my @clients = $r->client_list;
  is(@clients, 1, 'one client listed');
  like($clients[0], qr/\s+name=\s+/, '... no name set yet');

  is($r->client_setname('my_preccccious'), 'OK',             "client_setname() is supported, no errors");
  is($r->client_getname,                   'my_preccccious', '... client_getname() returns new connection name');

  @clients = $r->client_list;
  like($clients[0], qr/\s+name=my_preccccious\s+/, '... no name set yet');
};


subtest 'client name via constructor' => sub {
  ok(my $r = Redis->new(server => $srv, name => 'buuu'), 'connected to our test redis-server, with a name');
  is($r->client_getname, 'buuu', '... name was properly set');
};


done_testing();
