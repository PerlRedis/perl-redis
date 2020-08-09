#!perl

use warnings;
use strict;
use Test::More;
use Test::Fatal;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv, undef, undef, undef, undef, undef, $sock_temp_file) = redis();
END { $c->() if $c }

subtest 'REDIS_SERVER TCP' => sub {
  my $n = time();
  my $r = Redis->new(server => $srv);
  $r->set($$ => $n);

  local $ENV{REDIS_SERVER} = $srv;
  is(exception { $r = Redis->new }, undef, "Direct IP/Port address on REDIS_SERVER works ($srv)",);
  is($r->get($$), $n, '... connected to the expected server');

  $ENV{REDIS_SERVER} = "tcp:$srv";
  is(exception { $r = Redis->new }, undef, 'Direct IP/Port address (with tcp prefix) on REDIS_SERVER works',);
  is($r->get($$), $n, '... connected to the expected server');
};

subtest 'REDIS_SERVER TCP with undef sock' => sub {
  my $n = time();
  my $r = Redis->new(server => $srv, sock => undef);
  $r->set($$ => $n);

  local $ENV{REDIS_SERVER} = $srv;
  is(exception { $r = Redis->new }, undef, "Direct IP/Port address on REDIS_SERVER works ($srv)",);
  is($r->get($$), $n, '... connected to the expected server');

  $ENV{REDIS_SERVER} = "tcp:$srv";
  is(exception { $r = Redis->new }, undef, 'Direct IP/Port address (with tcp prefix) on REDIS_SERVER works',);
  is($r->get($$), $n, '... connected to the expected server');
};


subtest 'REDIS_SERVER UNIX' => sub {
  my $srv = $ENV{TEST_REDIS_SERVER_SOCK_PATH};
  plan skip_all => 'Define ENV TEST_REDIS_SERVER_SOCK_PATH to test UNIX socket support'
    unless $srv;

  my $n = time();
  my $r = Redis->new(sock => $srv);
  $r->set($$ => $n);

  local $ENV{REDIS_SERVER} = $srv;
  is(exception { $r = Redis->new }, undef, 'UNIX path on REDIS_SERVER works',);
  is($r->get($$), $n, '... connected to the expected server');

  $ENV{REDIS_SERVER} = "unix:$srv";
  is(exception { $r = Redis->new }, undef, 'UNIX path (with unix prefix) on REDIS_SERVER works',);
  is($r->get($$), $n, '... connected to the expected server');
};


done_testing();
