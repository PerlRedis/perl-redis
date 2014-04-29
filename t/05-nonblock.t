#!perl

use warnings;
use strict;
use Test::More;
use Redis;
use lib 't/tlib';
use Test::SpawnRedisServer;

my ($c, $srv) = redis();
END { $c->() if $c }

subtest 'non-block TCP' => sub {
  ok(my $r = Redis->new(server => $srv), 'connected to our test redis-server via TCP');

  ## Try to read from server (nothing sent, so nothing to read)
  ## But kill if we block
  local $SIG{ALRM} = sub { kill 9, $$ };
  alarm(2);
  ok(!$r->__try_read_sock($r->{sock}), "Nothing to read, didn't block");
  alarm(0);
};


subtest 'non-block UNIX' => sub {
  plan skip_all => 'Define ENV TEST_REDIS_SERVER_SOCK_PATH to test UNIX socket support'
    unless $ENV{TEST_REDIS_SERVER_SOCK_PATH};

  ok(my $r = Redis->new(sock => $ENV{TEST_REDIS_SERVER_SOCK_PATH}), 'connected to our test redis-server via UNIX');

  ## Try to read from server (nothing sent, so nothing to read)
  ## But kill if we block
  local $SIG{ALRM} = sub { kill 9, $$ };
  alarm(2);
  ok(!Redis::__try_read_sock($r->{sock}), "Nothing to read, didn't block");
  alarm(0);
};


done_testing();
